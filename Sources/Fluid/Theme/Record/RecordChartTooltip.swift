import SwiftUI

/// Record/Chart/Tooltip: the floating date and value shown over a Stats chart.
struct RecordChartTooltip: View {
    let date: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: FWMetric.space1) {
            Text(self.date)
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textSecondary)
            Text(self.value)
                .recordText(FWType.label)
                .foregroundStyle(FWColor.textPrimary)
        }
        .padding(.vertical, FWMetric.space3)
        .padding(.horizontal, FWMetric.space4)
        .background(RoundedRectangle(cornerRadius: FWMetric.radiusInner, style: .continuous).fill(FWColor.surfaceRaised))
        .overlay {
            RoundedRectangle(cornerRadius: FWMetric.radiusInner, style: .continuous)
                .strokeBorder(FWColor.lineStrong, lineWidth: FWMetric.lineHairline)
        }
        .recordFloat()
        .accessibilityElement(children: .combine)
    }
}
