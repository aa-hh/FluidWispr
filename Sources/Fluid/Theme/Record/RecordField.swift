import SwiftUI

/// Record/Field: a raised text field with a strong-line outline and 8 pt corners.
/// Single is one 28 pt line of Body text; Multi is Transcript text from the top
/// left, sized by the caller. Error turns the outline amber; the note under it is
/// the screen's job.
struct RecordField: View {
    enum Size {
        case single
        case multi
    }

    let placeholder: String
    @Binding var text: String
    var size: Size = .single
    var isError = false

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FWMetric.radiusInner, style: .continuous)
        self.input
            .foregroundStyle(FWColor.textPrimary)
            .padding(.leading, FWMetric.space3)
            .padding(.trailing, FWMetric.space4)
            .background(shape.fill(FWColor.surfaceRaised))
            .overlay { shape.strokeBorder(self.isError ? FWColor.stateAttention : FWColor.lineStrong, lineWidth: FWMetric.lineHairline) }
            .recordFocusRing(self.isFocused && self.isEnabled, in: shape)
            .opacity(self.isEnabled ? 1 : 0.4)
    }

    @ViewBuilder
    private var input: some View {
        switch self.size {
        case .single:
            TextField("", text: self.$text, prompt: Text(self.placeholder).foregroundStyle(FWColor.textTertiary))
                .textFieldStyle(.plain)
                .recordText(FWType.body)
                .focused(self.$isFocused)
                .focusEffectDisabled()
                .frame(height: FWMetric.sizeControlM)
        case .multi:
            TextEditor(text: self.$text)
                .recordText(FWType.transcript)
                .scrollContentBackground(.hidden)
                .focused(self.$isFocused)
                .focusEffectDisabled()
                .overlay(alignment: .topLeading) {
                    if self.text.isEmpty {
                        Text(self.placeholder)
                            .recordText(FWType.transcript)
                            .foregroundStyle(FWColor.textTertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.vertical, FWMetric.space3)
                .accessibilityLabel(self.placeholder)
        }
    }
}
