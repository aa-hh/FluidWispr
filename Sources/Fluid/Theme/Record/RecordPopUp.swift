import SwiftUI

/// Record/Pop-up: a native `Menu` showing its value in a raised capsule with a chevron.
/// The chrome is drawn by a button style outside the label, because macOS can
/// flatten styling placed inside a native menu's label (see Components/README.md).
struct RecordPopUp<Content: View>: View {
    let value: String
    @ViewBuilder let content: () -> Content

    init(_ value: String, @ViewBuilder content: @escaping () -> Content) {
        self.value = value
        self.content = content
    }

    var body: some View {
        Menu(content: self.content) { Text(self.value) }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(RecordPopUpStyle())
            .fixedSize()
            .accessibilityValue(self.value)
    }
}

private struct RecordPopUpStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RecordPopUpBody(label: configuration.label)
    }
}

private struct RecordPopUpBody<Label: View>: View {
    let label: Label

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: FWMetric.space3) {
            self.label
                .recordText(FWType.body)
                .foregroundStyle(FWColor.textPrimary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.fluidSystem(size: 9, weight: .semibold))
                .foregroundStyle(FWColor.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, FWMetric.space4)
        .frame(height: FWMetric.sizeControlM)
        .background(Capsule().fill(FWColor.surfaceRaised))
        .overlay { Capsule().strokeBorder(FWColor.lineStrong, lineWidth: FWMetric.lineHairline) }
        .contentShape(Capsule())
        .recordFocusRing(self.isFocused && self.isEnabled, in: Capsule())
        .focusEffectDisabled()
        .opacity(self.isEnabled ? 1 : 0.4)
    }
}
