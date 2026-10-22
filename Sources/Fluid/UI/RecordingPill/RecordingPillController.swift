import AppKit
import Metal
import MetalKit
import QuartzCore

/// The recording pill's window and its dictation states.
///
/// The panel is created once and stays ordered in; a hidden pill draws a
/// transparent frame and pauses its display link, so hiding costs no window
/// server round trip on the stop path and nothing while idle.
@MainActor
final class RecordingPillController {
    static let shared = RecordingPillController()

    static let settingsChanged = NSNotification.Name("RecordingPillSettingsChanged")
    /// Room around the pill for the halo, in points.
    static let margin: CGFloat = 6
    /// How long the bubble takes to dissolve after the microphone's fix is taken.
    static let fixedHold: Float = 0.5
    static let activeFps = 60

    /// The panel only resizes when the live words move above the pill or back,
    /// so a size change can glide and the bubble has room on either side: the
    /// largest pill, as wide as live words make it and swollen by the split,
    /// plus the bubble, its gap and its shake, and the bounce of a fling. With
    /// the words above, it is tall enough for their bubble on either side, so
    /// the pill stays at its centre wherever it is docked.
    static func panelSize(wordsAbove: Bool) -> CGSize {
        let p = RimParameters.approved
        let pill = RecordingPillSize.large.points
        let k = pill.height / CGFloat(RimSpring.islandHeight)
        let bubble = CGFloat(p.fluxGap + p.shake + 2.33) * k + 1.16 * CGFloat(p.fluxSize) * pill.height
        let bounce = CGFloat(RimDrag.bounceCap) * k
        let widest = max(pill.width, RimWords.widest(pillHeight: pill.height))
        let textScale = RimWords.widest(pillHeight: pill.height) / RimWords.maxWidth
        let above = wordsAbove ? RimWords.tallestAbove(pillHeight: pill.height) + CGFloat(RimWordsBubble.gap) * textScale + 4 : 0
        return CGSize(
            width: (1.11 * widest + 2 * (bubble + margin) + bounce).rounded(.up),
            height: (1.11 * pill.height + 2 * (margin + above) + bounce).rounded(.up)
        )
    }

    private var panel: NSPanel?
    private var view: MTKView?
    private var wordsView: RecordingPillWordsView?
    private var renderer: RecordingPillRenderer?
    private var bubbleTarget: RecordingPillBubbleTarget?
    private var pillTarget: RecordingPillBubbleTarget?
    private var drag = RimDrag()
    /// Pointer positions over the last tenth of a second of a drag, for the release speed.
    private var dragTrail: [(time: CFTimeInterval, point: NSPoint)] = []
    /// The screen whose spots the pill rests on.
    private var screen: NSScreen?
    private var didFailToPrepare = false
    /// A click on the bubble or the shortcut asked for a retry that has not answered yet.
    private var isRetrying = false
    private var outcomeTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?

    /// Takes the user to the fix for a lost microphone.
    var fixMicrophone: (@MainActor () -> Void)?

    /// True when a failed dictation paste should wait in the pill's bubble
    /// rather than on the failure card: the pill can draw, no edit or command
    /// overlay has taken its place, and history is saved, because the retry
    /// pastes the newest history entry.
    var takesFailedPastes: Bool {
        self.panel != nil && !self.isSuppressed && SettingsStore.shared.saveTranscriptionHistory
    }

    private var state: RimState = .idle
    private var stateStartedAt: CFTimeInterval = 0
    private var lastFrameAt: CFTimeInterval?
    private var simulation = RimSimulation(collapsesWhenDone: true)
    private var extractor = RimFeatureExtractor(attack: RimParameters.approved.attack, release: RimParameters.approved.release)
    private var visibility: RecordingPillVisibility = .whileDictating
    private var size: RecordingPillSize = .medium
    private var dock: RecordingPillDock = .bottom
    private var liveWords: RecordingPillLiveWords = .inPill
    private var words = RimWords(measure: { RecordingPillWordsView.width(of: $0, size: $1) })
    private var reduceMotion = false
    /// Another overlay (edit or command mode) is on screen, so the resting pill steps aside.
    private var isSuppressed = false
    /// Logs where the pill is and what it drew, once per dictation, so a pill that never shows can be traced.
    private var logsNextFrame = false

    var stateForTests: RimState { self.state }
    /// The scale the window server shows the rim's layer at, and the scale it should be.
    var layerScaleForTests: (layer: CGFloat, window: CGFloat)? {
        guard let panel = self.panel, let layer = self.view?.layer else { return nil }
        return (layer.contentsScale, panel.backingScaleFactor)
    }

    private init() {
        NotificationCenter.default.addObserver(forName: Self.settingsChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RecordingPillController.shared.applySettings() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RecordingPillController.shared.position(on: nil) }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("OverlayOffsetChanged"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RecordingPillController.shared.position(on: nil) }
        }
    }

    /// Builds the panel and compiles the shader once, after launch. Returns
    /// false when this Mac cannot draw the pill; dictation then uses the old overlay.
    @discardableResult
    func prepare() -> Bool {
        if self.panel != nil { return true }
        if self.didFailToPrepare { return false }
        guard let device = MTLCreateSystemDefaultDevice() else {
            DebugLogger.shared.error("Recording pill has no Metal device; dictation uses the old overlay", source: "RecordingPill")
            self.didFailToPrepare = true
            return false
        }
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.preferredFramesPerSecond = Self.activeFps
        guard let renderer = RecordingPillRenderer(device: device, pixelFormat: view.colorPixelFormat) else {
            self.didFailToPrepare = true
            return false
        }
        renderer.frame = { [weak self] in self?.nextFrame() ?? [Float](repeating: 0, count: RimUniform.count) }
        view.delegate = renderer

        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.setAccessibilityElement(false)
        // The words sit over the rim in their own view, so they are drawn as text, not by the shader.
        let container = NSView(frame: NSRect(origin: .zero, size: Self.panelSize(wordsAbove: false)))
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        let wordsView = RecordingPillWordsView(frame: container.bounds)
        wordsView.autoresizingMask = [.width, .height]
        container.addSubview(wordsView)
        panel.contentView = container
        self.wordsView = wordsView
        // An MTKView made at zero size outside a window can keep a contentsScale of 0 (seen on macOS 27),
        // and the window server then shows every frame it draws at zero size.
        view.layer?.contentsScale = panel.backingScaleFactor

        self.panel = panel
        self.view = view
        self.renderer = renderer
        self.permissionTask = Task { @MainActor in
            for await change in PermissionWatcher.shared.changes() {
                RecordingPillController.shared.handle(change)
            }
        }
        self.outcomeTask = Task { @MainActor in
            for await event in PasteOutcomeCenter.shared.outcomes() {
                RecordingPillController.shared.handle(event)
            }
        }
        self.bubbleTarget = RecordingPillBubbleTarget(
            onHover: { RecordingPillController.shared.setBubbleHover($0) },
            onClick: { RecordingPillController.shared.bubbleClicked() }
        )
        self.pillTarget = RecordingPillBubbleTarget(onDrag: { RecordingPillController.shared.pillDragged($0, at: $1) })
        self.applySettings()
        panel.orderFrontRegardless()
        return true
    }

    // MARK: - Dictation states

    /// Key down: the pill grows from a point and the rim listens. Returns false
    /// when the pill cannot be drawn, so the caller shows the old overlay.
    func beginListening() -> Bool {
        guard self.prepare() else { return false }
        // A new dictation supersedes anything waiting: the bubble merges back into the pill.
        self.isHoldingFailedPaste = false
        self.isRetrying = false
        self.isSuppressed = false
        if !self.isShowingBubble { self.position(on: OverlayScreenResolver.screenForCurrentPointer()) }
        self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        self.liveWords = SettingsStore.shared.recordingPillLiveWords
        // The words of a transcript still waiting in the bubble leave as the new dictation starts.
        if self.words.hasWords, self.state == .flux { self.words.dropAll() } else { self.words.clear() }
        self.extractor.reset()
        // Early, so an Electron app has its text fields readable by the time the paste checks them.
        ElectronAccessibility.enableForFrontmostApp()
        RimAudioAnalyzer.shared.setActive(true)
        self.enter(.listen)
        self.logPlacement("listen")
        self.logsNextFrame = true
        return true
    }

    private func logPlacement(_ moment: String) {
        guard let panel = self.panel, let view = self.view else { return }
        let screen = panel.screen.map { "\($0.frame)" } ?? "none"
        DebugLogger.shared.info(
            "Pill \(moment): frame=\(panel.frame) visible=\(panel.isVisible) onScreen=\(panel.occlusionState.contains(.visible)) "
                + "screen=\(screen) view=\(view.bounds.size) drawable=\(view.drawableSize) paused=\(view.isPaused) dock=\(self.dock.rawValue)",
            source: "RecordingPill"
        )
    }

    /// A new live preview of everything heard so far, shown in the pill or in the bubble above it.
    func hear(_ text: String) {
        guard self.state == .listen, self.liveWords != .off else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || self.words.hasWords else { return }
        self.words.hear(trimmed, reduced: self.reduceMotion)
        self.wake()
    }

    /// Key up: the rim's light travels inward to the centre line.
    func beginProcessing() {
        guard self.state == .listen else { return }
        RimAudioAnalyzer.shared.setActive(false)
        self.words.release()
        self.enter(.think)
    }

    /// Processing shown again after the pill already left, for example when a
    /// slow cleanup reports progress late. Grows straight into the centre line.
    func showProcessing() -> Bool {
        guard self.prepare() else { return false }
        self.isSuppressed = false
        self.position(on: OverlayScreenResolver.screenForCurrentPointer())
        RimAudioAnalyzer.shared.setActive(false)
        self.enter(.think)
        return true
    }

    /// The dictation finished. A paste turns the line green first; anything else
    /// (cancel, empty result, error) goes straight back to rest or away.
    func finish(pasted: Bool) {
        guard self.state == .listen || self.state == .think else { return }
        RimAudioAnalyzer.shared.setActive(false)
        if !pasted { self.words.dropAll() }
        self.enter(pasted ? .done : .idle)
    }

    /// A paste failed and its transcript waits in a bubble beside the pill for
    /// a click or the "Paste last transcript" shortcut. The pill stays on
    /// screen while it waits, whatever "Pill shows" says.
    private(set) var isHoldingFailedPaste = false

    func holdFailedPaste() {
        // MenuBarManager hands some failures over before the hide, and the outcome event follows.
        guard self.prepare(), !(self.isHoldingFailedPaste && self.state == .flux) else { return }
        self.isHoldingFailedPaste = true
        self.isRetrying = false
        RimAudioAnalyzer.shared.setActive(false)
        if self.state == .idle, self.simulation.isGone { self.position(on: OverlayScreenResolver.screenForCurrentPointer()) }
        self.enter(.flux)
    }

    /// The shortcut asked for the held transcript: the bubble bumps and flashes
    /// the glow and arrow a click would show.
    func retryPasteStarted() {
        guard self.isHoldingFailedPaste, self.state == .flux else { return }
        self.isRetrying = true
        self.simulation.pressBubble(showsFlash: true, reduced: self.reduceMotion)
        self.wake()
    }

    /// A retry of the held transcript landed: the pill and the bubble turn green and the bubble dissolves.
    func retryPasteSucceeded() {
        guard self.isHoldingFailedPaste, self.prepare() else { return }
        self.isHoldingFailedPaste = false
        self.isRetrying = false
        self.enter(.pasted)
    }

    /// A retry of the held transcript failed again: soft orange and one shake; the transcript keeps waiting.
    func retryPasteFailed() {
        guard self.isHoldingFailedPaste, self.state == .flux else { return }
        self.isRetrying = false
        self.simulation.failRetry(reduced: self.reduceMotion)
        self.wake()
    }

    /// The microphone stopped responding: the pill shows amber and the fix
    /// waits in a bubble with a crossed-out mic until it is clicked or a new
    /// dictation starts.
    func showMicrophoneLost() {
        self.showProblem(.microphone)
    }

    /// A permission this run had was turned off: the pill shows amber with a
    /// lock in its bubble until the permission is back. A click opens its
    /// System Settings pane. With both off, Accessibility comes first.
    private var lockedPermission: PermissionWatcher.Permission? {
        let revoked = PermissionWatcher.shared.revoked
        if revoked.contains(.accessibility) { return .accessibility }
        return revoked.contains(.microphone) ? .microphone : nil
    }

    private var showsLock: Bool { self.state == .problem && self.simulation.problem == .lock }

    func handle(_ change: PermissionWatcher.Change) {
        switch change.kind {
        case .revoked:
            self.showProblem(.lock)
        case .restored:
            guard self.showsLock, self.lockedPermission == nil else { return }
            self.enter(.fixed)
        }
    }

    private func showProblem(_ kind: RimBubble.Kind) {
        guard self.prepare() else { return }
        RimAudioAnalyzer.shared.setActive(false)
        self.isHoldingFailedPaste = false
        self.isRetrying = false
        if self.state == .idle, self.simulation.isGone { self.position(on: OverlayScreenResolver.screenForCurrentPointer()) }
        self.simulation.problem = kind
        self.enter(.problem)
    }

    private var isShowingBubble: Bool { self.state == .flux || self.state == .problem }

    private func setBubbleHover(_ on: Bool) {
        self.simulation.setBubbleHover(on)
        self.wake()
    }

    /// The bubble bumps under the click, and its action fires once the bump has started.
    private func bubbleClicked() {
        guard self.simulation.bubble.isWaiting, !self.isRetrying else { return }
        let waiting = self.state
        guard waiting == .flux || waiting == .problem else { return }
        self.simulation.pressBubble(showsFlash: false, reduced: self.reduceMotion)
        self.wake()
        if waiting == .flux { self.isRetrying = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(RimParameters.pressDelay * 1000)))
            guard self.state == waiting else { return }
            if waiting == .problem {
                // The lock waits until the permission is back; the click only opens its pane.
                if self.showsLock, let permission = self.lockedPermission {
                    PermissionWatcher.shared.openSettings(for: permission)
                    return
                }
                self.enter(.fixed)
                self.fixMicrophone?()
                return
            }
            // The retry's own outcome events turn the pill green or orange.
            if await PasteOutcomeCenter.shared.pasteLastTranscript() == nil { self.isRetrying = false }
        }
    }

    /// Follows every paste: a dictation paste that fails waits in the bubble,
    /// and a "paste last transcript" retry bumps it, then turns it green or orange.
    func handle(_ event: PasteOutcomeEvent) {
        if event.isRetry {
            guard self.isHoldingFailedPaste else { return }
            switch (event.phase, event.outcome) {
            case (.dispatched, _):
                // A click already bumped the bubble; the shortcut gets the same bump and a flash.
                if !self.isRetrying { self.retryPasteStarted() }
            case (.final, .cancelled):
                self.isRetrying = false
            case let (.final, outcome) where outcome.didPaste:
                self.retryPasteSucceeded()
            case (.final, _):
                self.retryPasteFailed()
            }
            return
        }
        // The cleaned text settles into the words in the pill as soon as the paste is sent; above it they stay a preview.
        if event.phase == .dispatched, self.liveWords == .inPill, self.words.hasWords, self.state == .think || self.state == .done {
            self.words.cleanUp(event.transcript, reduced: self.reduceMotion)
            self.wake()
        }
        // A late verdict on the previous paste must not interrupt the next dictation.
        guard event.phase == .final, self.takesFailedPastes, self.state != .listen, self.state != .think else { return }
        switch event.outcome {
        case .noFocusedTextField, .failed(.pasteNotLanded):
            self.holdFailedPaste()
        case .landed, .unconfirmed, .cancelled, .failed:
            break
        }
    }

    /// Edit and command modes still use the old overlay; the resting pill steps
    /// aside while it is up. A bubble that is waiting on the user stays.
    func setSuppressed(_ suppressed: Bool) {
        guard suppressed != self.isSuppressed else { return }
        self.isSuppressed = suppressed
        if suppressed, self.state == .listen || self.state == .think {
            RimAudioAnalyzer.shared.setActive(false)
            self.state = .idle
            self.words.clear()
        }
        self.wake()
    }

    private func enter(_ state: RimState) {
        // A revoked permission outlasts anything else the pill shows, so it comes back once the pill would rest.
        if state == .idle, self.lockedPermission != nil, !self.isSuppressed {
            self.showProblem(.lock)
            return
        }
        self.state = state
        self.stateStartedAt = CACurrentMediaTime()
        self.wake()
    }

    private func wake() {
        guard let view = self.view else { return }
        view.preferredFramesPerSecond = Self.activeFps
        if view.isPaused {
            self.lastFrameAt = nil
            view.isPaused = false
        }
    }

    // MARK: - Frames

    private var collapsesWhenIdle: Bool { self.visibility == .whileDictating || self.isSuppressed }

    /// Steps the voice features and the rim, then returns this frame's uniforms.
    private func nextFrame() -> [Float] {
        let now = CACurrentMediaTime()
        // Clamp so a long pause never jumps the animation.
        let dt = Float(min(max(now - (self.lastFrameAt ?? now - 1.0 / 60), 0), 0.1))
        self.lastFrameAt = now
        var elapsed = Float(now - self.stateStartedAt)

        let p = self.simulation.params
        switch self.state {
        case .done where elapsed > p.greenHold + (self.simulation.collapsesWhenDone ? p.collapseTime : p.snapTime) + 0.05,
             .pasted where elapsed > p.greenHold + (self.simulation.collapsesWhenDone ? p.collapseTime : 0) + 0.05,
             .fixed where elapsed > Self.fixedHold:
            self.enter(.idle)
            elapsed = 0
        default:
            break
        }

        let features = self.state == .listen
            ? self.extractor.step(dt: dt, raw: RimAudioAnalyzer.shared.latestBands())
            : RimFeatures()
        // Shown always, the pill lets the words go after the green hold and returns to its resting size.
        if self.state == .done, !self.collapsesWhenIdle, elapsed > p.greenHold, self.words.hasWords { self.words.dropAll() }
        self.words.setPill(height: self.size.points.height)
        self.words.setAbove(self.liveWords == .above)
        self.words.step(dt: dt, reduced: self.reduceMotion)
        self.simulation.collapsesWhenDone = self.collapsesWhenIdle
        self.simulation.liveWordsInPill = self.liveWords == .inPill
        self.simulation.wordsShown = self.liveWords == .inPill && self.words.hasWords
        self.simulation.wordsAbove = self.wordsAboveTarget
        self.simulation.wordsBelow = self.dock.isTop
        self.simulation.wordsGap = RimWordsBubble.gap * Float(self.words.scale)
        self.simulation.update(
            dt: dt, state: self.state, features: features, reduced: self.reduceMotion, pill: self.words.pillSize(base: self.size.points)
        )
        if self.simulation.isGone, !self.words.isEmpty { self.words.clear() }
        if let screen = self.screen {
            self.drag.step(dt: dt, rest: self.restingCentre(on: screen), reduced: self.reduceMotion)
            // Every frame: under Reduce Motion the pill jumps and is never "moving". This is a no-op when it has not moved.
            self.movePanel()
        }
        let uniforms = self.simulation.uniforms(
            state: self.state,
            stateTime: elapsed,
            displayScale: Float(self.panel?.backingScaleFactor ?? 2),
            reduced: self.reduceMotion,
            dimAtRest: true,
            side: self.dock.bubbleSide,
            stretch: self.drag.stretch(pill: self.simulation.size, reduced: self.reduceMotion)
        )
        self.placeBubbleTarget()
        self.placePillTarget()
        if self.logsNextFrame, self.state == .listen, elapsed > 0.3 {
            self.logsNextFrame = false
            self.logPlacement("drawing")
            DebugLogger.shared.info(
                "Pill frame: fade=\(uniforms[RimUniform.fade]) size=\(uniforms[RimUniform.pillW])x\(uniforms[RimUniform.pillH]) "
                    + "visibility=\(self.simulation.visibility) exposure=\(uniforms[RimUniform.exposure])",
                source: "RecordingPill"
            )
        }
        self.showWords()

        if self.state == .idle, !self.drag.isMoving, self.words.isEmpty, let view = self.view {
            if self.collapsesWhenIdle, self.simulation.isGone {
                // This frame is fully transparent; nothing to draw until the next key down.
                view.isPaused = true
            } else if !self.collapsesWhenIdle, elapsed > 1 {
                view.preferredFramesPerSecond = Int(p.idleFps)
            }
        }
        return uniforms
    }

    /// The size the words need above the pill. The bubble is for while you talk and while the AI
    /// works; a paste, or a failed one, takes it back in.
    private var wordsAboveTarget: CGSize? {
        let keeps = self.liveWords == .above && self.words.hasWords && (self.state == .listen || self.state == .think)
        return keeps ? self.words.aboveSize : nil
    }

    var wordsAboveForTests: CGSize? { self.wordsAboveTarget }
    var wordsTextForTests: String { self.words.text }

    private func showWords() {
        guard let wordsView = self.wordsView else { return }
        let scale = self.panel?.backingScaleFactor ?? 2
        let thinking = self.state == .think
        if self.words.isAbove {
            let bubble = self.simulation.wordsBubble
            let inner = Float(max(1, bubble.size.width - 2 * self.words.padding))
            wordsView.show(
                self.words.looks(thinking: thinking, inner: inner, reduced: self.reduceMotion),
                words: self.words,
                box: bubble.size,
                // The shader's y grows downward and the view's upward.
                offset: CGPoint(x: 0, y: CGFloat(-bubble.y)),
                look: (SIMD2(1, 1), bubble.textOpacity),
                scale: scale
            )
            return
        }
        let pill = self.simulation.size
        let inner = Float(max(1, pill.width - 2 * self.words.padding))
        let look = self.simulation.wordsLook(side: self.dock.bubbleSide)
        wordsView.show(
            self.words.looks(thinking: thinking, inner: inner, reduced: self.reduceMotion),
            words: self.words,
            box: pill,
            offset: CGPoint(x: CGFloat(look.offsetX), y: 0),
            look: (look.scale, look.opacity),
            scale: scale
        )
    }

    // MARK: - Settings and placement

    private func applySettings() {
        let settings = SettingsStore.shared
        let moved = settings.recordingPillSize != self.size || settings.recordingPillDock != self.dock
        self.visibility = settings.recordingPillVisibility
        self.size = settings.recordingPillSize
        self.dock = settings.recordingPillDock
        guard let panel = self.panel else { return }
        let panelSize = Self.panelSize(wordsAbove: settings.recordingPillLiveWords == .above)
        if panel.frame.size != panelSize {
            panel.setContentSize(panelSize)
            self.position(on: nil)
        } else if moved {
            self.position(on: nil)
        }
        self.wake()
    }

    /// The bubble takes clicks through its own small panel, so the pill's panel
    /// stays click-through and a click never lands on the pill's empty corners.
    private func placeBubbleTarget() {
        guard let target = self.bubbleTarget, let panel = self.panel else { return }
        guard self.simulation.bubble.isWaiting else {
            target.hide()
            return
        }
        let pill = self.simulation.size
        let k = pill.height / CGFloat(RimSpring.islandHeight)
        let p = self.simulation.params
        let radius = 0.5 * CGFloat(p.fluxSize) * pill.height
        let offset = pill.width / 2 + CGFloat(p.fluxGap) * k + radius
        let centre = NSPoint(x: panel.frame.midX + CGFloat(self.dock.bubbleSide) * offset, y: panel.frame.midY)
        target.show(centre: centre, radius: radius, label: self.bubbleLabel)
    }

    private var bubbleLabel: String {
        guard self.state == .problem else { return "Paste transcript" }
        switch self.showsLock ? self.lockedPermission : nil {
        case .accessibility: return "Open Accessibility settings"
        case .microphone: return "Open Microphone settings"
        case nil: return "Fix microphone"
        }
    }

    /// The pill takes the pointer only while it is on screen, so a hidden
    /// pill never catches a click meant for the app underneath.
    private func placePillTarget() {
        guard let target = self.pillTarget, let panel = self.panel else { return }
        guard self.drag.isDragging || (self.simulation.visibility > 0.5 && !self.isSuppressed) else {
            target.hide()
            return
        }
        let pill = self.simulation.size
        let frame = NSRect(x: panel.frame.midX - pill.width / 2, y: panel.frame.midY - pill.height / 2, width: pill.width, height: pill.height)
        target.show(frame: frame.insetBy(dx: -4, dy: -4))
    }

    /// A press, drag and release on the pill. On release it settles on the
    /// spot nearest to where a flick would carry it, and that spot is kept.
    private func pillDragged(_ phase: NSEvent.EventType, at point: NSPoint) {
        guard let screen = self.screen else { return }
        let spots = self.spots(on: screen)
        let now = CACurrentMediaTime()
        switch phase {
        case .leftMouseDown:
            self.drag.begin(pointer: point)
            self.dragTrail = [(time: now, point: point)]
        case .leftMouseDragged:
            self.trackDrag(point, at: now)
            self.drag.move(pointer: point, spots: spots)
        case .leftMouseUp:
            guard self.drag.isDragging else { return }
            self.trackDrag(point, at: now)
            let first = self.dragTrail.first ?? (time: now, point: point)
            let dt = max(0.016, now - first.time)
            let velocity = CGVector(dx: (point.x - first.point.x) / dt, dy: (point.y - first.point.y) / dt)
            self.dragTrail = []
            self.dock = self.drag.release(velocity: velocity, spots: spots, pillHeight: self.size.points.height, reduced: self.reduceMotion)
            SettingsStore.shared.recordingPillDock = self.dock
        default:
            return
        }
        self.wake()
    }

    private func trackDrag(_ point: NSPoint, at now: CFTimeInterval) {
        self.dragTrail.append((time: now, point: point))
        while self.dragTrail.count > 2, now - self.dragTrail[0].time > 0.1 {
            self.dragTrail.removeFirst()
        }
    }

    private func spots(on screen: NSScreen) -> [RecordingPillDock: CGPoint] {
        RimDrag.spots(
            visible: screen.visibleFrame,
            screenMidX: screen.frame.midX,
            pill: self.words.pillSize(base: self.size.points),
            bottomOffset: CGFloat(SettingsStore.shared.overlayBottomOffset)
        )
    }

    private func restingCentre(on screen: NSScreen) -> CGPoint {
        self.spots(on: screen)[self.dock] ?? CGPoint(x: screen.frame.midX, y: screen.visibleFrame.midY)
    }

    /// Puts the pill on its spot on `screen`, or on the screen it is on. A
    /// hidden pill, or one moving to another screen, jumps; one on screen
    /// glides there on the size spring.
    private func position(on screen: NSScreen?) {
        guard let panel = self.panel, !self.drag.isDragging,
              let screen = screen ?? panel.screen ?? OverlayScreenResolver.screenForCurrentPointer()
        else { return }
        let jumps = screen != self.screen || !self.drag.isPlaced || self.simulation.visibility < 0.01
        self.screen = screen
        if jumps {
            self.drag.place(at: self.restingCentre(on: screen))
            self.movePanel()
        } else {
            self.wake()
        }
    }

    private func movePanel() {
        guard let panel = self.panel else { return }
        let centre = self.drag.centre
        let size = panel.frame.size
        let scale = max(1, panel.backingScaleFactor)
        let origin = NSPoint(
            x: ((centre.x - size.width / 2) * scale).rounded() / scale,
            y: ((centre.y - size.height / 2) * scale).rounded() / scale
        )
        // On a screen with another scale the layer has to follow, or the pill draws at the wrong size.
        if let layer = self.view?.layer, layer.contentsScale != panel.backingScaleFactor {
            layer.contentsScale = panel.backingScaleFactor
        }
        // Moving a window waits on the window server; skip it when nothing changed.
        guard panel.frame.origin != origin else { return }
        panel.setFrameOrigin(origin)
    }
}
