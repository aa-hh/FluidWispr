import SwiftUI

/// Record/Alert: a raised confirmation panel. The caller places it in a `ZStack`
/// over the sheet, with no dimming. Return triggers the cancel button and Esc
/// cancels; the other action needs a click, or Tab then Space.
struct RecordAlert: View {
    enum Layout {
        /// The action above the cancel button.
        case stacked
        /// The cancel button, then the action, in one row.
        case sideBySide
    }

    struct Action {
        let label: String
        let kind: RecordButtonStyle.Kind
        let run: () -> Void
    }

    let title: String
    let message: String
    var layout: Layout = .stacked
    var width: CGFloat = 260
    let cancel: Action
    /// Nil shows only the cancel button, for a notice such as one Primary "OK".
    var action: Action? = nil

    var body: some View {
        VStack(spacing: FWMetric.space4) {
            VStack(spacing: FWMetric.space2) {
                Text(self.title)
                    .recordText(FWType.label)
                    .foregroundStyle(FWColor.textPrimary)
                Text(self.message)
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Group {
                switch self.layout {
                case .stacked:
                    VStack(spacing: FWMetric.space3) {
                        if let action = self.action { self.button(action) }
                        self.button(self.cancel).keyboardShortcut(.defaultAction)
                    }
                case .sideBySide:
                    HStack(spacing: FWMetric.space3) {
                        self.button(self.cancel).keyboardShortcut(.defaultAction)
                        if let action = self.action { self.button(action) }
                    }
                }
            }
            .padding(.top, FWMetric.space2)
        }
        .padding(FWMetric.space6)
        .frame(width: self.width)
        .background(RoundedRectangle(cornerRadius: FWMetric.radiusContainer, style: .continuous).fill(FWColor.surfaceRaised))
        .overlay {
            RoundedRectangle(cornerRadius: FWMetric.radiusContainer, style: .continuous)
                .strokeBorder(FWColor.lineRule, lineWidth: FWMetric.lineHairline)
        }
        .recordFloat()
        .onExitCommand(perform: self.cancel.run)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func button(_ action: Action) -> some View {
        Button(action: action.run) {
            Text(action.label).frame(maxWidth: .infinity)
        }
        .buttonStyle(RecordButtonStyle(kind: action.kind, size: FWMetric.sizeControlM))
    }
}
