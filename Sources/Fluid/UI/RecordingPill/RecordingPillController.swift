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

    /// The panel never resizes, so a size change can glide and the bubble has
    /// room on either side: the largest pill, swollen by the split, plus the
    /// bubble, its gap and its shake.
    static let panelSize: CGSize = {
        let p = RimParameters.approved
        let pill = RecordingPillSize.large.points
        let k = pill.height / CGFloat(RimSpring.islandHeight)
        let bubble = CGFloat(p.fluxGap + p.shake + 2.33) * k + 1.16 * CGFloat(p.fluxSize) * pill.height
        return CGSize(width: (1.11 * pill.width + 2 * (bubble + margin)).rounded(.up), height: (1.11 * pill.height + 2 * margin).rounded(.up))
    }()

    private var panel: NSPanel?
    private var view: MTKView?
    private var renderer: RecordingPillRenderer?
    private var bubbleTarget: RecordingPillBubbleTarget?
    private var didFailToPrepare = false
    /// A click on the bubble or the shortcut asked for a retry that has not answered yet.
    private var isRetrying = false
    private var outcomeTask: Task<Void, Never>?

    /// Takes the user to the fix for a lost microphone.
    var fixMicrophone: (@MainActor () -> Void)?

    /// True when a failed dictation paste should wait in the pill's bubble
    /// rather than on the failure card: the pill can draw, and no edit or
    /// command overlay has taken its place.
    var takesFailedPastes: Bool { self.panel != nil && !self.isSuppressed }

    private var state: RimState = .idle
    private var stateStartedAt: CFTimeInterval = 0
    private var lastFrameAt: CFTimeInterval?
    private var simulation = RimSimulation(collapsesWhenDone: true)
    private var extractor = RimFeatureExtractor(attack: RimParameters.approved.attack, release: RimParameters.approved.release)
    private var visibility: RecordingPillVisibility = .whileDictating
    private var size: RecordingPillSize = .medium
    private var reduceMotion = false
    /// Another overlay (edit or command mode) is on screen, so the resting pill steps aside.
    private var isSuppressed = false

    var stateForTests: RimState { self.state }

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
        panel.contentView = view

        self.panel = panel
        self.view = view
        self.renderer = renderer
        self.outcomeTask = Task { @MainActor in
            for await event in PasteOutcomeCenter.shared.outcomes() {
                RecordingPillController.shared.handle(event)
            }
        }
        self.bubbleTarget = RecordingPillBubbleTarget(
            onHover: { RecordingPillController.shared.setBubbleHover($0) },
            onClick: { RecordingPillController.shared.bubbleClicked() }
        )
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
        self.extractor.reset()
        RimAudioAnalyzer.shared.setActive(true)
        self.enter(.listen)
        return true
    }

    /// Key up: the rim's light travels inward to the centre line.
    func beginProcessing() {
        guard self.state == .listen else { return }
        RimAudioAnalyzer.shared.setActive(false)
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
        guard self.prepare() else { return }
        RimAudioAnalyzer.shared.setActive(false)
        self.isHoldingFailedPaste = false
        if self.state == .idle, self.simulation.isGone { self.position(on: OverlayScreenResolver.screenForCurrentPointer()) }
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
        guard event.phase == .final, self.takesFailedPastes else { return }
        switch event.outcome {
        case .noFocusedTextField, .failed(.pasteNotLanded):
            self.holdFailedPaste()
        case .landed, .unconfirmed, .cancelled, .failed:
            break
        }
    }

    /// Edit and command modes still use the old overlay; the resting pill steps
    /// aside while it is up so the two never overlap.
    func setSuppressed(_ suppressed: Bool) {
        guard suppressed != self.isSuppressed else { return }
        self.isSuppressed = suppressed
        if suppressed, self.state == .listen || self.state == .think {
            RimAudioAnalyzer.shared.setActive(false)
            self.state = .idle
        }
        self.wake()
    }

    private func enter(_ state: RimState) {
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
        self.simulation.collapsesWhenDone = self.collapsesWhenIdle
        self.simulation.update(dt: dt, state: self.state, features: features, reduced: self.reduceMotion, pill: self.size.points)
        let uniforms = self.simulation.uniforms(
            state: self.state,
            stateTime: elapsed,
            displayScale: Float(self.panel?.backingScaleFactor ?? 2),
            reduced: self.reduceMotion,
            dimAtRest: true
        )
        self.placeBubbleTarget()

        if self.state == .idle, let view = self.view {
            if self.collapsesWhenIdle, self.simulation.isGone {
                // This frame is fully transparent; nothing to draw until the next key down.
                view.isPaused = true
            } else if !self.collapsesWhenIdle, elapsed > 1 {
                view.preferredFramesPerSecond = Int(p.idleFps)
            }
        }
        return uniforms
    }

    // MARK: - Settings and placement

    private func applySettings() {
        let settings = SettingsStore.shared
        let sizeChanged = settings.recordingPillSize != self.size
        self.visibility = settings.recordingPillVisibility
        self.size = settings.recordingPillSize
        guard let panel = self.panel else { return }
        if panel.frame.size == .zero { panel.setContentSize(Self.panelSize) }
        if sizeChanged || panel.frame.size == Self.panelSize { self.position(on: nil) }
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
        let pill = self.size.points
        let k = pill.height / CGFloat(RimSpring.islandHeight)
        let p = self.simulation.params
        let radius = 0.5 * CGFloat(p.fluxSize) * pill.height
        let centre = NSPoint(x: panel.frame.midX + pill.width / 2 + CGFloat(p.fluxGap) * k + radius, y: panel.frame.midY)
        target.show(centre: centre, radius: radius, label: self.state == .problem ? "Fix microphone" : "Paste transcript")
    }

    private func position(on screen: NSScreen?) {
        guard let panel = self.panel,
              let screen = screen ?? panel.screen ?? OverlayScreenResolver.screenForCurrentPointer()
        else { return }
        let size = panel.frame.size
        let pill = self.size.points
        let visible = screen.visibleFrame
        let offset = CGFloat(SettingsStore.shared.overlayBottomOffset)
        // The pill's bottom sits above the dock and below the top of the visible frame, like the bottom overlay.
        let bottom = max(min(visible.minY + offset, visible.maxY - pill.height - 40), visible.minY + 10)
        let y = bottom + pill.height / 2 - size.height / 2
        let origin = NSPoint(x: (screen.frame.midX - size.width / 2).rounded(), y: y.rounded())
        // Moving a window waits on the window server; skip it when nothing changed.
        guard panel.frame.origin != origin else { return }
        panel.setFrameOrigin(origin)
    }
}
