import SwiftUI

/// Record/Toast: a raised 304 pt note with a Done mark, a Label title and a Detail line.
struct RecordToast: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: FWMetric.space4) {
            RecordMark(state: .done)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: FWMetric.space1) {
                Text(self.title)
                    .recordText(FWType.label)
                    .foregroundStyle(FWColor.textPrimary)
                Text(self.detail)
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: FWMetric.space4, leading: FWMetric.space5, bottom: FWMetric.space4, trailing: FWMetric.space6))
        .frame(width: 304)
        .background(RoundedRectangle(cornerRadius: FWMetric.radiusContainer, style: .continuous).fill(FWColor.surfaceRaised))
        .overlay {
            RoundedRectangle(cornerRadius: FWMetric.radiusContainer, style: .continuous)
                .strokeBorder(FWColor.lineRule, lineWidth: FWMetric.lineHairline)
        }
        .recordFloat()
        .accessibilityElement(children: .combine)
    }
}
