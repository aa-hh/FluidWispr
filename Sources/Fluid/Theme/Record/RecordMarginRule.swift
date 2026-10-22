import SwiftUI

/// Record/Margin rule: two 1 pt hairlines 2 pt apart, stretched to the row's height.
/// Rows stacked without gaps read as one double rule down the sheet.
struct RecordMarginRule: View {
    var body: some View {
        HStack(spacing: FWMetric.sizeRuleGap) {
            Rectangle().fill(FWColor.lineMargin).frame(width: FWMetric.lineHairline)
            Rectangle().fill(FWColor.lineMargin).frame(width: FWMetric.lineHairline)
        }
        .frame(width: 4)
        .frame(maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}
