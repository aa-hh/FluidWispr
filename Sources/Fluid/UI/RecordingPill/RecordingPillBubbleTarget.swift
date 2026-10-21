import AppKit

/// A small invisible panel that takes the pointer over part of the pill. Over
/// the waiting bubble, hover lights it and a click retries the paste or opens
/// the microphone fix. Over the pill, it drags the pill to another spot. It
/// never becomes key or activates the app, so the window the transcript is
/// meant for keeps focus.
@MainActor
final class RecordingPillBubbleTarget {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class TargetView: NSView {
        var onHover: (Bool) -> Void = { _ in }
        var onClick: () -> Void = {}
        /// Screen points of a press, a drag and a release, for the pill.
        var onDrag: ((NSEvent.EventType, NSPoint) -> Void)?

        override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in self.trackingAreas { self.removeTrackingArea(area) }
            self.addTrackingArea(NSTrackingArea(rect: self.bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with _: NSEvent) {
            self.onHover(true)
            if self.onDrag != nil { NSCursor.openHand.set() }
        }

        override func mouseExited(with _: NSEvent) {
            self.onHover(false)
            if self.onDrag != nil { NSCursor.arrow.set() }
        }

        override func mouseDown(with event: NSEvent) {
            guard let onDrag = self.onDrag else {
                self.onClick()
                return
            }
            NSCursor.closedHand.set()
            onDrag(.leftMouseDown, NSEvent.mouseLocation)
        }

        override func mouseDragged(with _: NSEvent) { self.onDrag?(.leftMouseDragged, NSEvent.mouseLocation) }

        override func mouseUp(with _: NSEvent) {
            guard let onDrag = self.onDrag else { return }
            NSCursor.openHand.set()
            onDrag(.leftMouseUp, NSEvent.mouseLocation)
        }

        override func accessibilityPerformPress() -> Bool {
            self.onClick()
            return true
        }
    }

    private let panel: Panel
    private let view = TargetView()
    private var isShown = false

    /// Takes a press, drags and a release on the pill, in screen points.
    convenience init(onDrag: @escaping (NSEvent.EventType, NSPoint) -> Void) {
        self.init(onHover: { _ in }, onClick: {})
        self.view.onDrag = onDrag
        self.view.setAccessibilityElement(false)
    }

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
        self.view.setAccessibilityLabel(label)
        self.show(frame: NSRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
    }

    func show(frame rect: NSRect) {
        let frame = rect.integral
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
