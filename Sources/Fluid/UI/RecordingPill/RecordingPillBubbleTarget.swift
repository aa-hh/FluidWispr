import AppKit

/// A small invisible panel over the pill's waiting bubble that takes the
/// pointer: hover lights the bubble and a click retries the paste or opens the
/// microphone fix. It never becomes key or activates the app, so the window
/// the transcript is meant for keeps focus.
@MainActor
final class RecordingPillBubbleTarget {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class TargetView: NSView {
        var onHover: (Bool) -> Void = { _ in }
        var onClick: () -> Void = {}

        override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in self.trackingAreas { self.removeTrackingArea(area) }
            self.addTrackingArea(NSTrackingArea(rect: self.bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with _: NSEvent) { self.onHover(true) }
        override func mouseExited(with _: NSEvent) { self.onHover(false) }
        override func mouseDown(with _: NSEvent) { self.onClick() }

        override func accessibilityPerformPress() -> Bool {
            self.onClick()
            return true
        }
    }

    private let panel: Panel
    private let view = TargetView()
    private var isShown = false

    init(onHover: @escaping (Bool) -> Void, onClick: @escaping () -> Void) {
        self.panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.panel.level = .floating
        self.panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.panel.isOpaque = false
        self.panel.backgroundColor = .clear
        self.panel.hasShadow = false
        // Set explicitly: a clear window otherwise lets clicks fall through its transparent pixels.
        self.panel.ignoresMouseEvents = false
        self.panel.hidesOnDeactivate = false
        self.panel.animationBehavior = .none
        self.panel.becomesKeyOnlyIfNeeded = true
        self.view.onHover = onHover
        self.view.onClick = onClick
        self.view.setAccessibilityElement(true)
        self.view.setAccessibilityRole(.button)
        self.panel.contentView = self.view
    }

    func show(centre: NSPoint, radius: CGFloat, label: String) {
        let frame = NSRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius).integral
        self.view.setAccessibilityLabel(label)
        if self.panel.frame != frame { self.panel.setFrame(frame, display: false) }
        guard !self.isShown else { return }
        self.isShown = true
        self.panel.orderFrontRegardless()
    }

    func hide() {
        guard self.isShown else { return }
        self.isShown = false
        self.view.onHover(false)
        self.panel.orderOut(nil)
    }
}
