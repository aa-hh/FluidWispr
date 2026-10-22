import SwiftUI

/// The dimension tokens of "The record" (Figma variable collection Dimension), in points.
enum FWMetric {
    static let space1: CGFloat = 2
    static let space2: CGFloat = 4
    static let space3: CGFloat = 8
    static let space4: CGFloat = 12
    static let space5: CGFloat = 16
    static let space6: CGFloat = 20
    static let space7: CGFloat = 24
    static let space8: CGFloat = 32
    static let space9: CGFloat = 40
    static let space10: CGFloat = 56

    static let sizeControlS: CGFloat = 20
    static let sizeControlM: CGFloat = 28
    static let sizeControlL: CGFloat = 36
    static let sizeRowMin: CGFloat = 44
    static let sizeSidebar: CGFloat = 184
    static let sizeMargin: CGFloat = 168
    static let sizeRuleGap: CGFloat = 2
    static let sizeIconS: CGFloat = 13
    static let sizeIconM: CGFloat = 15
    static let sizeIconL: CGFloat = 17

    static let radiusCapsule: CGFloat = 999
    static let radiusContainer: CGFloat = 14
    static let radiusInner: CGFloat = 8
    static let radiusWindow: CGFloat = 16

    static let lineHairline: CGFloat = 1
    static let lineFocus: CGFloat = 2
    /// Points of spoken-length line per second spoken.
    static let lineSpokenScale: CGFloat = 5

    /// Elevation/Float: the one shadow, for things that float above the window.
    static let elevationFloat: (y: CGFloat, blur: CGFloat, opacity: Double) = (y: 8, blur: 24, opacity: 0.16)
}

extension View {
    /// Elevation/Float. A Figma blur of 24 is a SwiftUI shadow radius of 12.
    func recordFloat() -> some View {
        self.shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 8)
    }
}
