import AppKit

/// Record/Menu bar icon: the drawn pill outline, 18 × 18 pt, as a template image
/// so macOS tints it. Geometry is in 18 pt coordinates with the origin top-left.
enum MenuBarGlyph {
    enum State {
        case ready
        case dictating
        case microphoneProblem
        case updateWaiting

        var accessibilityLabel: String {
            switch self {
            case .ready: "FluidWispr"
            case .dictating: "FluidWispr, dictating"
            case .microphoneProblem: "FluidWispr, no microphone available"
            case .updateWaiting: "FluidWispr, update ready"
            }
        }
    }

    static func image(for state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            switch state {
            case .ready:
                let outline = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 5.25, width: 14.5, height: 7.5), xRadius: 3.75, yRadius: 3.75)
                outline.lineWidth = 1.5
                outline.stroke()
            case .dictating:
                NSBezierPath(roundedRect: NSRect(x: 1, y: 4.5, width: 16, height: 9), xRadius: 4.5, yRadius: 4.5).fill()
            case .microphoneProblem:
                NSGraphicsContext.saveGraphicsState()
                let clip = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 18, height: 18))
                clip.move(to: NSPoint(x: 1.03, y: 15.23))
                clip.line(to: NSPoint(x: 15.23, y: 1.03))
                clip.line(to: NSPoint(x: 17.77, y: 3.57))
                clip.line(to: NSPoint(x: 3.57, y: 17.77))
                clip.close()
                clip.windingRule = .evenOdd
                clip.addClip()
                self.ring().fill()
                NSGraphicsContext.restoreGraphicsState()
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 2.3, y: 16.5))
                slash.line(to: NSPoint(x: 16.5, y: 2.3))
                slash.lineWidth = 1.5
                slash.stroke()
            case .updateWaiting:
                let centre = NSPoint(x: 14, y: 13.5)
                NSGraphicsContext.saveGraphicsState()
                let clip = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 18, height: 18))
                clip.appendOval(in: NSRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10))
                clip.windingRule = .evenOdd
                clip.addClip()
                self.ring().fill()
                NSGraphicsContext.restoreGraphicsState()
                NSBezierPath(ovalIn: NSRect(x: centre.x - 3.25, y: centre.y - 3.25, width: 6.5, height: 6.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = state.accessibilityLabel
        return image
    }

    /// The Ready outline as a filled ring: outer 1…17 × 4.5…13.5, radius 4.5, 1.5 thick.
    private static func ring() -> NSBezierPath {
        let ring = NSBezierPath(roundedRect: NSRect(x: 1, y: 4.5, width: 16, height: 9), xRadius: 4.5, yRadius: 4.5)
        ring.append(NSBezierPath(roundedRect: NSRect(x: 2.5, y: 6, width: 13, height: 6), xRadius: 3, yRadius: 3))
        ring.windingRule = .evenOdd
        return ring
    }
}
