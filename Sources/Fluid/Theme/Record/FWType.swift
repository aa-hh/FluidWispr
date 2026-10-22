import AppKit
import SwiftUI

/// One of the nine `Record/` text styles: SF Pro at a size, weight and line height.
struct RecordTextStyle {
    let size: CGFloat
    let weight: Font.Weight
    let lineHeight: CGFloat
    let font: Font
    /// The space SwiftUI adds between lines so wrapped text sits on `lineHeight`.
    let lineSpacing: CGFloat

    init(size: CGFloat, weight: Font.Weight, lineHeight: CGFloat) {
        self.size = size
        self.weight = weight
        self.lineHeight = lineHeight
        self.font = .fluidSystem(size: size, weight: weight)
        let nsWeight: NSFont.Weight = switch weight {
        case .medium: .medium
        case .semibold: .semibold
        default: .regular
        }
        let natural = NSLayoutManager().defaultLineHeight(for: NSFont.fluidSystemFont(ofSize: size, weight: nsWeight))
        self.lineSpacing = max(0, lineHeight - natural)
    }
}

/// The type tokens of "The record" (Figma text styles `Record/<name>`).
enum FWType {
    static let title = RecordTextStyle(size: 22, weight: .semibold, lineHeight: 28)
    static let section = RecordTextStyle(size: 15, weight: .semibold, lineHeight: 20)
    static let transcript = RecordTextStyle(size: 15, weight: .regular, lineHeight: 24)
    static let body = RecordTextStyle(size: 13, weight: .regular, lineHeight: 18)
    static let label = RecordTextStyle(size: 13, weight: .medium, lineHeight: 18)
    static let detail = RecordTextStyle(size: 12, weight: .regular, lineHeight: 16)
    static let detailStrong = RecordTextStyle(size: 12, weight: .medium, lineHeight: 16)
    static let small = RecordTextStyle(size: 11, weight: .regular, lineHeight: 14)
    static let smallStrong = RecordTextStyle(size: 11, weight: .medium, lineHeight: 14)

    static let all: [RecordTextStyle] = [
        Self.title, Self.section, Self.transcript, Self.body, Self.label,
        Self.detail, Self.detailStrong, Self.small, Self.smallStrong,
    ]
}

extension View {
    /// Sets a `Record/` text style, with tabular figures for times and counts.
    func recordText(_ style: RecordTextStyle) -> some View {
        self
            .font(style.font)
            .lineSpacing(style.lineSpacing)
            .monospacedDigit()
    }
}
