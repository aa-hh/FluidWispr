import SwiftUI

/// Record/Icon button: a circle outlined in the strong line holding one glyph.
/// The glyph is the same size at S (20) and M (28).
struct RecordIconButton: View {
    enum Icon {
        case back
        case close
        case more
    }

    enum Size {
        case s
        case m
    }

    let icon: Icon
    var size: Size = .m
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Image(systemName: self.symbol)
                .font(.fluidSystem(size: 9, weight: .semibold))
        }
        .buttonStyle(RecordIconButtonStyle(diameter: self.size == .s ? FWMetric.sizeControlS : FWMetric.sizeControlM))
        .accessibilityLabel(self.accessibilityName)
    }

    private var symbol: String {
        switch self.icon {
        case .back: "chevron.left"
        case .close: "xmark"
        case .more: "ellipsis"
        }
    }

    private var accessibilityName: String {
        switch self.icon {
        case .back: "Back"
        case .close: "Close"
        case .more: "More"
        }
    }
}

private struct RecordIconButtonStyle: ButtonStyle {
    let diameter: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        RecordIconButtonBody(label: configuration.label, diameter: self.diameter)
    }
}

private struct RecordIconButtonBody<Label: View>: View {
    let label: Label
    let diameter: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        self.label
            .foregroundStyle(FWColor.textPrimary)
            .frame(width: self.diameter, height: self.diameter)
            .overlay { Circle().strokeBorder(FWColor.lineStrong, lineWidth: FWMetric.lineHairline) }
            .contentShape(Circle())
            .recordFocusRing(self.isFocused && self.isEnabled, in: Circle())
            .focusEffectDisabled()
            .opacity(self.isEnabled ? 1 : 0.4)
    }
}
