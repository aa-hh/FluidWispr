import SwiftUI

/// The sheet header: the title lines up with the text column (168 + 24 pt in),
/// with an optional Detail subtitle and an optional trailing control, top-aligned.
struct RecordHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: FWMetric.space7) {
            Color.clear.frame(width: FWMetric.sizeMargin, height: 0)
            VStack(alignment: .leading, spacing: FWMetric.space2) {
                Text(self.title)
                    .recordText(FWType.title)
                    .foregroundStyle(FWColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle = self.subtitle {
                    Text(subtitle)
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            self.trailing
        }
        .padding(.trailing, FWMetric.space8)
        .padding(.bottom, FWMetric.space6)
    }
}
