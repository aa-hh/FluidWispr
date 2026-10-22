import SwiftUI

/// Record/Keycap: a shortcut shown as a capsule. Small sits in Settings rows;
/// Large is the dictation key in onboarding's Try it step.
struct RecordKeycap: View {
    enum Size {
        case small
        case large
    }

    enum State {
        case normal
        case recording
        case conflict
    }

    let key: String
    var size: Size = .small
    var state: State = .normal

    var body: some View {
        Text(self.key)
            .recordText(self.size == .small ? FWType.smallStrong : FWType.section)
            .lineLimit(1)
            .foregroundStyle(self.state == .recording ? FWColor.textSecondary : FWColor.textPrimary)
            .padding(.horizontal, self.size == .small ? FWMetric.space3 : FWMetric.space5)
            .frame(height: self.size == .small ? FWMetric.sizeControlS : FWMetric.sizeControlL)
            .background(Capsule().fill(self.state == .recording ? FWColor.surfaceRaised : FWColor.surfaceSunken))
            .overlay {
                Capsule().strokeBorder(self.state == .conflict ? FWColor.stateAttention : FWColor.lineStrong, lineWidth: FWMetric.lineHairline)
            }
            .recordFocusRing(self.state == .recording, in: Capsule())
    }
}
