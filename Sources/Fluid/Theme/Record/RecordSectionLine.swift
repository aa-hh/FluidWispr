import SwiftUI

/// The section line of the ruled sheet: an empty margin and the margin rule, then
/// a Section heading with an optional Detail beside it. No bottom hairline.
struct RecordSectionLine: View {
    let heading: String
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: FWMetric.sizeMargin)
            RecordMarginRule()
            HStack(alignment: .firstTextBaseline, spacing: FWMetric.space4) {
                Text(self.heading)
                    .recordText(FWType.section)
                    .foregroundStyle(FWColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let detail = self.detail {
                    Text(detail)
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textSecondary)
                }
            }
            .padding(EdgeInsets(top: FWMetric.space8, leading: FWMetric.space6, bottom: FWMetric.space3, trailing: FWMetric.space8))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
