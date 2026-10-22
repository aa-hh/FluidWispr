import SwiftUI

/// Record/Line: one ruled row of the sheet. The fixed 168 pt margin holds the
/// details, the double margin rule runs the row's full height, and the content
/// column holds the words or controls, with its hairline and fill on that column only.
struct RecordLine<Margin: View, Content: View>: View {
    enum Fill {
        case none
        case hover
        case selected
        case sunken
    }

    var fill: Fill = .none
    var showsRule = true
    let margin: Margin
    let content: Content

    init(fill: Fill = .none, showsRule: Bool = true, @ViewBuilder margin: () -> Margin, @ViewBuilder content: () -> Content) {
        self.fill = fill
        self.showsRule = showsRule
        self.margin = margin()
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: FWMetric.space1) {
                self.margin
            }
            .padding(EdgeInsets(top: 14, leading: FWMetric.space7, bottom: FWMetric.space4, trailing: FWMetric.space5))
            .frame(width: FWMetric.sizeMargin, alignment: .topLeading)

            RecordMarginRule()

            VStack(alignment: .leading, spacing: 6) {
                self.content
            }
            .padding(EdgeInsets(top: 14, leading: FWMetric.space6, bottom: 14, trailing: FWMetric.space8))
            .frame(maxWidth: .infinity, minHeight: FWMetric.sizeRowMin, maxHeight: .infinity, alignment: .topLeading)
            .background(self.fillColor)
            .overlay(alignment: .bottom) {
                if self.showsRule {
                    Rectangle().fill(FWColor.lineRule).frame(height: FWMetric.lineHairline)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var fillColor: Color {
        switch self.fill {
        case .none: .clear
        case .hover: FWColor.surfaceHover
        case .selected: FWColor.surfaceSelected
        case .sunken: FWColor.surfaceSunken
        }
    }
}
