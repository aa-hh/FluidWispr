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
    /// How long the amber mic-lost state stays before the pill rests or leaves.
    static let problemHold: Float = 1.6
    static let activeFps = 60

    private var panel: NSPanel?
    private var view: MTKView?
    private var renderer: RecordingPillRenderer?
    private var didFailToPrepare = false

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
        self.applySettings()
        panel.orderFrontRegardless()
        return true
    }

    // MARK: - Dictation states

    /// Key down: the pill grows from a point and the rim listens. Returns false
    /// when the pill cannot be drawn, so the caller shows the old overlay.
    func beginListening() -> Bool {
        guard self.prepare() else { return false }
        self.isHoldingFailedPaste = false
        self.isSuppressed = false
        self.position(on: OverlayScreenResolver.screenForCurrentPointer())
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

    /// A paste failed and its transcript is held for a retry from the failure
    /// card or the "Paste last transcript" shortcut. Its own look is still being
    /// designed (AA-198), so for now the pill simply rests or leaves.
    private(set) var isHoldingFailedPaste = false

    func holdFailedPaste() {
        self.isHoldingFailedPaste = true
        self.finish(pasted: false)
    }

    /// A retry of the held transcript landed: the line turns green as after any paste.
    func retryPasteSucceeded() {
        guard self.isHoldingFailedPaste, self.prepare() else { return }
        self.isHoldingFailedPaste = false
        self.enter(.done)
    }

    /// A retry of the held transcript failed again; the transcript stays held.
    func retryPasteFailed() {
        guard self.isHoldingFailedPaste, self.prepare() else { return }
        self.enter(.problem)
    }

    /// The microphone stopped responding: the pill shows amber, then leaves.
    func showMicrophoneLost() {
        guard self.prepare() else { return }
        RimAudioAnalyzer.shared.setActive(false)
        self.enter(.problem)
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
        case .done where elapsed > p.greenHold + (self.simulation.collapsesWhenDone ? p.collapseTime : p.snapTime) + 0.05:
            self.enter(.idle)
            elapsed = 0
        case .problem where elapsed > Self.problemHold:
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
            pill: self.size.points,
            displayScale: Float(self.panel?.backingScaleFactor ?? 2),
            reduced: self.reduceMotion,
            dimAtRest: true
        )

        if self.state == .idle, let view = self.view {
            if self.collapsesWhenIdle, self.simulation.visibility <= 0 {
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
        if sizeChanged || panel.frame.size == .zero {
            let pill = self.size.points
            panel.setContentSize(CGSize(width: pill.width + 2 * Self.margin, height: pill.height + 2 * Self.margin))
            self.position(on: nil)
        }
        self.wake()
    }

    private func position(on screen: NSScreen?) {
        guard let panel = self.panel,
              let screen = screen ?? panel.screen ?? OverlayScreenResolver.screenForCurrentPointer()
        else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let offset = CGFloat(SettingsStore.shared.overlayBottomOffset)
        // Above the dock and below the top of the visible frame, like the bottom overlay.
        let y = max(min(visible.minY + offset, visible.maxY - size.height - 40), visible.minY + 10)
        let origin = NSPoint(x: (screen.frame.midX - size.width / 2).rounded(), y: y.rounded())
        // Moving a window waits on the window server; skip it when nothing changed.
        guard panel.frame.origin != origin else { return }
        panel.setFrameOrigin(origin)
    }
}
