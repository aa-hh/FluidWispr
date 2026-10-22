import SwiftUI

/// The What's new sheet: a header, one ruled line per note, and a footer with Done.
struct ReleaseHighlightsView: View {
    let canExplore: Bool
    let version: String
    let content: ReleaseHighlightsContent
    let onClose: (ReleaseHighlightsContent.Destination?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordHeader(self.content.title, subtitle: self.content.subtitle)
            ForEach(self.content.features) { feature in
                self.line(feature)
            }
            HStack(alignment: .center, spacing: FWMetric.space4) {
                Text("Past notes are in Changelog, in the menu bar menu.")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Done") { self.onClose(nil) }
                    .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlM))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(EdgeInsets(top: FWMetric.space6, leading: FWMetric.sizeMargin + FWMetric.space7, bottom: 0, trailing: FWMetric.space8))
        }
        .padding(.top, FWMetric.space8)
        .padding(.bottom, FWMetric.space6)
        .frame(width: 800)
        .background(FWColor.surfaceWindow)
        .onExitCommand { self.onClose(nil) }
    }

    private func line(_ feature: ReleaseHighlightsContent.Feature) -> some View {
        RecordLine {
            Text(feature.marginName)
                .recordText(FWType.label)
                .foregroundStyle(FWColor.textPrimary)
            Text(feature.marginDetail)
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textSecondary)
        } content: {
            Text(feature.title)
                .recordText(FWType.section)
                .foregroundStyle(FWColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(feature.body)
                .recordText(FWType.body)
                .foregroundStyle(FWColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            switch feature.extra {
            case .pillIllustration:
                RecordingPillPreview(state: .idle, size: .medium)
                    .accessibilityHidden(true)
            case .openSettingsButton:
                Button("Open settings") { self.onClose(.settings) }
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
                    .disabled(!self.canExplore)
                    .padding(.top, FWMetric.space2)
            case nil:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
    }
}
