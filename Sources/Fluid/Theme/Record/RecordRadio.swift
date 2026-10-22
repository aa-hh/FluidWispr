import SwiftUI

/// Record/Radio: a 16 pt dot and a Body label. Selected fills the dot with ink and
/// a 6 pt inner dot; focus draws a 22 pt ink ring around the dot.
struct RecordRadio: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Text(self.label)
        }
        .buttonStyle(RecordRadioStyle(isSelected: self.isSelected))
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }
}

private struct RecordRadioStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        RecordRadioBody(label: configuration.label, isSelected: self.isSelected)
    }
}

private struct RecordRadioBody<Label: View>: View {
    let label: Label
    let isSelected: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: FWMetric.space3) {
            ZStack {
                if self.isSelected {
                    Circle().fill(FWColor.actionPrimary)
                    Circle().fill(FWColor.actionOnPrimary).frame(width: 6, height: 6)
                } else {
                    Circle().fill(FWColor.surfaceRaised)
                    Circle().strokeBorder(FWColor.lineStrong, lineWidth: FWMetric.lineHairline)
                }
            }
            .frame(width: 16, height: 16)
            .recordFocusRing(self.isFocused && self.isEnabled, in: Circle())
            self.label
                .recordText(FWType.body)
                .foregroundStyle(FWColor.textPrimary)
        }
        .contentShape(Rectangle())
        .focusEffectDisabled()
    }
}
