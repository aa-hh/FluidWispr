import SwiftUI

/// Record/Button/Back: a 20 pt outlined capsule with a chevron and the name of
/// the screen it returns to.
struct RecordBackButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: FWMetric.space2) {
                Image(systemName: "chevron.left")
                    .font(.fluidSystem(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
                Text(self.label)
            }
        }
        .buttonStyle(RecordBackButtonStyle())
        .accessibilityLabel("Back to \(self.label)")
    }
}

private struct RecordBackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RecordBackButtonBody(label: configuration.label)
    }
}

private struct RecordBackButtonBody<Label: View>: View {
    let label: Label

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        self.label
            .recordText(FWType.detailStrong)
            .foregroundStyle(FWColor.textPrimary)
            .padding(.horizontal, FWMetric.space3)
            .frame(height: FWMetric.sizeControlS)
            .overlay { Capsule().strokeBorder(FWColor.lineStrong, lineWidth: FWMetric.lineHairline) }
            .contentShape(Capsule())
            .recordFocusRing(self.isFocused, in: Capsule())
            .focusEffectDisabled()
    }
}
