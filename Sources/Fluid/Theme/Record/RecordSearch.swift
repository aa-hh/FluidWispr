import SwiftUI

/// Record/Search: a 28 pt capsule search field with no magnifier. Sunken while
/// unfocused, raised with the ink ring while focused, with a clear button once it
/// holds text. Esc clears it; other keys reach `onCommand` like `SidebarSearchField`.
struct RecordSearch: View {
    let placeholder: String
    @Binding var text: String
    /// Return and the arrow keys arrive as `#selector(NSResponder.insertNewline(_:))`
    /// and friends; return true when handled. Esc with an empty field also arrives
    /// here as `cancelOperation(_:)`.
    var onCommand: (Selector) -> Bool = { _ in false }

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: FWMetric.space2) {
            TextField("", text: self.$text, prompt: Text(self.placeholder).foregroundStyle(FWColor.textTertiary))
                .textFieldStyle(.plain)
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textPrimary)
                .focused(self.$isFocused)
                .focusEffectDisabled()
                .onSubmit { _ = self.onCommand(#selector(NSResponder.insertNewline(_:))) }
                .onKeyPress(.upArrow) { self.onCommand(#selector(NSResponder.moveUp(_:))) ? .handled : .ignored }
                .onKeyPress(.downArrow) { self.onCommand(#selector(NSResponder.moveDown(_:))) ? .handled : .ignored }
                .onExitCommand {
                    if self.text.isEmpty {
                        _ = self.onCommand(#selector(NSResponder.cancelOperation(_:)))
                    } else {
                        self.text = ""
                    }
                }
            if !self.text.isEmpty {
                Button {
                    self.text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.fluidSystem(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(FWColor.textPrimary, FWColor.lineStrong)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, FWMetric.space4)
        .padding(.trailing, self.text.isEmpty ? FWMetric.space4 : FWMetric.space2)
        .frame(height: FWMetric.sizeControlM)
        .background(Capsule().fill(self.isFocused ? FWColor.surfaceRaised : FWColor.surfaceSunken))
        .overlay {
            if self.isFocused {
                Capsule().strokeBorder(FWColor.lineStrong, lineWidth: FWMetric.lineHairline)
            }
        }
        .recordFocusRing(self.isFocused, in: Capsule())
    }
}
