import AppKit
import MetalKit
import SwiftUI

/// The approved recording pill, drawn at real size inside a window: the pill size
/// choice in Settings and the live microphone rim. It runs its own renderer and
/// rim simulation, stepped the way `RecordingPillController.nextFrame()` steps
/// them, without the drag, the bubble or the floating panel.
///
/// `.listen` shows the voice from `RimAudioAnalyzer`; the caller keeps the
/// microphone preview running while it shows `.listen`.
struct RecordingPillPreview: NSViewRepresentable {
    /// `.idle` or `.listen`.
    var state: RimState
    var size: RecordingPillSize

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        guard let device = MTLCreateSystemDefaultDevice() else { return NSView() }
        let view = PreviewMTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.preferredFramesPerSecond = RecordingPillController.activeFps
        guard let renderer = RecordingPillRenderer(device: device, pixelFormat: view.colorPixelFormat) else { return view }
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.renderer = renderer
        renderer.frame = { [weak coordinator] in
            coordinator?.nextFrame() ?? [Float](repeating: 0, count: RimUniform.count)
        }
        view.delegate = renderer
        coordinator.apply(state: self.state, size: self.size)
        return view
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.apply(state: self.state, size: self.size)
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func sizeThatFits(_: ProposedViewSize, nsView _: NSView, context _: Context) -> CGSize? {
        let pill = self.size.points
        let margin = RecordingPillController.margin
        return CGSize(width: pill.width + 2 * margin, height: pill.height + 2 * margin)
    }

    @MainActor
    final class Coordinator {
        fileprivate var view: MTKView?
        fileprivate var renderer: RecordingPillRenderer?
        private var simulation = RimSimulation(collapsesWhenDone: false)
        private var extractor = RimFeatureExtractor(attack: RimParameters.approved.attack, release: RimParameters.approved.release)
        private var state: RimState = .idle
        private var size: RecordingPillSize = .medium
        private var reduceMotion = false
        private var stateStartedAt = CACurrentMediaTime()
        private var lastFrameAt: CFTimeInterval?
        private var isAnalyzing = false

        fileprivate func apply(state: RimState, size: RecordingPillSize) {
            let state: RimState = state == .listen ? .listen : .idle
            self.size = size
            if state != self.state {
                self.state = state
                self.stateStartedAt = CACurrentMediaTime()
                if state == .listen { self.extractor.reset() }
            }
            self.setAnalyzing(state == .listen)
            self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            self.wake()
        }

        fileprivate func stop() {
            self.setAnalyzing(false)
            self.view?.isPaused = true
            self.view?.delegate = nil
        }

        private func setAnalyzing(_ on: Bool) {
            guard on != self.isAnalyzing else { return }
            self.isAnalyzing = on
            RimAudioAnalyzer.shared.setActive(on)
        }

        private func wake() {
            guard let view = self.view else { return }
            view.preferredFramesPerSecond = RecordingPillController.activeFps
            if view.isPaused {
                self.lastFrameAt = nil
                view.isPaused = false
            }
        }

        fileprivate func nextFrame() -> [Float] {
            let now = CACurrentMediaTime()
            // Clamp so a long pause never jumps the animation.
            let dt = Float(min(max(now - (self.lastFrameAt ?? now - 1.0 / 60), 0), 0.1))
            self.lastFrameAt = now
            let elapsed = Float(now - self.stateStartedAt)

            let features = self.state == .listen
                ? self.extractor.step(dt: dt, raw: RimAudioAnalyzer.shared.latestBands())
                : RimFeatures()
            self.simulation.update(dt: dt, state: self.state, features: features, reduced: self.reduceMotion, pill: self.size.points)
            let uniforms = self.simulation.uniforms(
                state: self.state,
                stateTime: elapsed,
                displayScale: Float(self.view?.window?.backingScaleFactor ?? 2),
                reduced: self.reduceMotion,
                dimAtRest: false,
                side: 1
            )
            if self.state == .idle, elapsed > 1, let view = self.view {
                view.preferredFramesPerSecond = Int(self.simulation.params.idleFps)
            }
            return uniforms
        }
    }
}

/// Keeps the layer's scale in step with the window: an `MTKView` made at zero size
/// outside a window can keep a contentsScale of 0 (see `RecordingPillController.prepare()`).
private final class PreviewMTKView: MTKView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window { self.layer?.contentsScale = window.backingScaleFactor }
    }
}
