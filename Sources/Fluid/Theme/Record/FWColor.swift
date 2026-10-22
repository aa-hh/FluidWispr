import AppKit
import SwiftUI

/// The colour tokens of "The record" (Figma variable collection Color). Each one
/// follows the view's appearance: the Light value in Aqua, the Dark value in Dark Aqua.
enum FWColor {
    static let surfaceWindow = Self.pair("#FCFCFB", "#0E0F13")
    static let surfaceSidebar = Self.pair("#F2F2F3", "#0A0B0E")
    static let surfaceSelected = Self.pair("#E4E4E8", "#24252C")
    static let surfaceHover = Self.pair("#F6F6F7", "#15161B")
    static let surfaceSunken = Self.pair("#F0F0F2", "#17181D")
    static let surfaceRaised = Self.pair("#FFFFFF", "#202127")
    static let lineRule = Self.pair("#E6E6EA", "#22232A")
    static let lineMargin = Self.pair("#D3D3D9", "#34353E")
    static let lineStrong = Self.pair("#C2C3CA", "#6A6B74")
    static let lineSpoken = Self.pair("#0E0F13", "#ECECEF", alpha: 0.35)
    static let textPrimary = Self.pair("#0E0F13", "#ECECEF")
    static let textSecondary = Self.pair("#5E5F68", "#9A9BA4")
    static let textTertiary = Self.pair("#6C6D76", "#8C8D96")
    static let ink = Self.pair("#0E0F13", "#ECECEF")
    static let actionPrimary = Self.pair("#0E0F13", "#ECECEF")
    static let actionOnPrimary = Self.pair("#F4F4F5", "#0E0F13")
    static let stateDone = Self.pair("#11804A", "#5BE39B")
    static let stateAttention = Self.pair("#975A00", "#FFC24D")
    static let stateRetry = Self.pair("#B4531B", "#FF9A5C")
    static let stateDestructive = Self.pair("#C8322F", "#FF6B66")
    static let liveIvory = Self.pair("#FFE4B8", "#FFE4B8")
    static let pillBody = Self.pair("#0E0F13", "#0E0F13")

    private static func pair(_ light: String, _ dark: String, alpha: CGFloat = 1) -> Color {
        let lightColor = Self.nsColor(hex: light, alpha: alpha)
        let darkColor = Self.nsColor(hex: dark, alpha: alpha)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        })
    }

    private static func nsColor(hex: String, alpha: CGFloat) -> NSColor {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: alpha
        )
    }
}

extension View {
    /// For floating surfaces beside the pill (paste-failed card, muted label,
    /// follow-up field, dictionary correction panel): near-black in both appearances.
    func recordNearBlack() -> some View {
        self
            .environment(\.colorScheme, .dark)
            .background(FWColor.pillBody)
    }
}
