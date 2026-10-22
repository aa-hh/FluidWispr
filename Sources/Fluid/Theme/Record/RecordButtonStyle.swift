import SwiftUI

/// Record/Button: a capsule at the pill's heights. The app installs Secondary 28
/// as the default style, so unstyled buttons get it.
struct RecordButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case destructive
        case quiet
    }

    let kind: Kind
    /// 20, 28 or 36.
    let size: CGFloat

    init(kind: Kind = .secondary, size: CGFloat = 28) {
        self.kind = kind
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        RecordButtonBody(configuration: configuration, kind: self.kind, size: self.size)
    }

    static func sidePadding(for size: CGFloat) -> CGFloat {
        switch size {
        case FWMetric.sizeControlS: FWMetric.space3
        case FWMetric.sizeControlL: FWMetric.space5
        default: FWMetric.space4
        }
    }
}

private struct RecordButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: RecordButtonStyle.Kind
    let size: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        let highlighted = self.isEnabled && (self.isHovered || self.configuration.isPressed)
        self.configuration.label
            .recordText(self.size == FWMetric.sizeControlS ? FWType.detailStrong : FWType.label)
            .lineLimit(1)
            .foregroundStyle(self.labelColor)
            .padding(.horizontal, RecordButtonStyle.sidePadding(for: self.size))
            .frame(height: self.size)
            .background { self.fill(highlighted: highlighted) }
            .overlay {
                if let outline = self.outlineColor {
                    Capsule().strokeBorder(outline, lineWidth: FWMetric.lineHairline)
                }
            }
            .contentShape(Capsule())
            .recordFocusRing(self.isFocused && self.isEnabled, in: Capsule())
            .focusEffectDisabled()
            .onHover { self.isHovered = $0 }
            .animation(.easeInOut(duration: FWMotion.durationSnap), value: highlighted)
    }

    @ViewBuilder
    private func fill(highlighted: Bool) -> some View {
        switch self.kind {
        case .primary where self.isEnabled:
            Capsule().fill(FWColor.actionPrimary)
                .overlay { Capsule().fill(FWColor.actionOnPrimary.opacity(highlighted ? 0.08 : 0)) }
        case .secondary, .destructive, .primary:
            Capsule().fill(highlighted ? FWColor.surfaceSelected : FWColor.surfaceSunken)
        case .quiet:
            Capsule().fill(highlighted ? FWColor.surfaceHover : Color.clear)
        }
    }

    private var outlineColor: Color? {
        switch self.kind {
        case .quiet: nil
        case .primary: self.isEnabled ? nil : FWColor.lineRule
        case .secondary, .destructive: self.isEnabled ? FWColor.lineStrong : FWColor.lineRule
        }
    }

    private var labelColor: Color {
        guard self.isEnabled else { return FWColor.textTertiary }
        return switch self.kind {
        case .primary: FWColor.actionOnPrimary
        case .secondary: FWColor.textPrimary
        case .destructive: FWColor.stateDestructive
        case .quiet: FWColor.textSecondary
        }
    }
}

extension View {
    /// The ink focus ring: 2 pt, centred 3 pt outside the control, following its shape.
    func recordFocusRing(_ shown: Bool, in shape: some InsettableShape) -> some View {
        self.overlay {
            if shown {
                shape.inset(by: -3)
                    .stroke(FWColor.ink, lineWidth: FWMetric.lineFocus)
                    .allowsHitTesting(false)
            }
        }
    }
}
