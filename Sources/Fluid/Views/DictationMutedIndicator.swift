import SwiftUI

/// The muted label: a near-black 28 pt capsule with the microphone-off glyph in
/// `state/attention`, and the sentence when there is room. `compact` shows the glyph only.
struct DictationMutedIndicator: View {
    var compact = false

    var body: some View {
        HStack(spacing: FWMetric.space2) {
            Image(systemName: "mic.slash")
                .font(.fluidSystem(size: 14, weight: .regular))
            if !self.compact {
                Text("Muted. Let go of Space to talk.")
                    .recordText(FWType.detailStrong)
            }
        }
        .foregroundStyle(FWColor.stateAttention)
        .padding(.leading, self.compact ? FWMetric.space3 : 10)
        .padding(.trailing, self.compact ? FWMetric.space3 : FWMetric.space4)
        .frame(height: FWMetric.sizeControlM)
        .recordNearBlack()
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .strokeBorder(FWColor.lineRule, lineWidth: FWMetric.lineHairline)
                .environment(\.colorScheme, .dark)
        }
        .recordFloat()
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dictation muted. Release Space to resume.")
        .help("Release Space to resume dictation")
    }
}
