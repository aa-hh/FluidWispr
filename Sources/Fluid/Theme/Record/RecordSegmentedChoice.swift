import SwiftUI

/// Segmented choice (Settings): a sunken capsule of capsule segments. The selected
/// segment is raised with a strong-line outline.
struct RecordSegmentedChoice<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: FWMetric.space1) {
            ForEach(self.options, id: \.value) { option in
                Button(option.label) { self.selection = option.value }
                    .buttonStyle(RecordSegmentStyle(isSelected: option.value == self.selection))
                    .accessibilityAddTraits(option.value == self.selection ? .isSelected : [])
            }
        }
        .padding(FWMetric.space1)
        .background(Capsule().fill(FWColor.surfaceSunken))
        .fixedSize()
    }
}

private struct RecordSegmentStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        RecordSegmentBody(label: configuration.label, isSelected: self.isSelected)
    }
}

private struct RecordSegmentBody<Label: View>: View {
    let label: Label
    let isSelected: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        self.label
            .recordText(FWType.detailStrong)
            .foregroundStyle(self.isSelected ? FWColor.textPrimary : FWColor.textSecondary)
            .padding(.horizontal, FWMetric.space4)
            .padding(.vertical, FWMetric.space2)
            .background {
                if self.isSelected {
                    Capsule().fill(FWColor.surfaceRaised)
                        .overlay { Capsule().strokeBorder(FWColor.lineStrong, lineWidth: FWMetric.lineHairline) }
                }
            }
            .contentShape(Capsule())
            .recordFocusRing(self.isFocused && self.isEnabled, in: Capsule())
            .focusEffectDisabled()
    }
}
