import SwiftUI

/// Record/Drop well: a dashed sunken well for File Transcription with a heading,
/// help text and a Primary "Choose file…" button. The caller handles the drop and
/// passes `isTargeted` while a file is dragged over it.
struct RecordDropWell: View {
    let heading: String
    let help: String
    var isTargeted = false
    let onChoose: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FWMetric.radiusInner, style: .continuous)
        HStack(spacing: FWMetric.space5) {
            VStack(alignment: .leading, spacing: FWMetric.space1) {
                Text(self.isTargeted ? "Drop to choose this file" : self.heading)
                    .recordText(FWType.label)
                    .foregroundStyle(FWColor.textPrimary)
                Text(self.isTargeted ? "Release to add it. Nothing starts until you press Transcribe." : self.help)
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Choose file…", action: self.onChoose)
                .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlM))
                .opacity(self.isTargeted ? 0 : 1)
        }
        .padding(FWMetric.space6)
        .background(shape.fill(self.isTargeted ? FWColor.surfaceSelected : FWColor.surfaceSunken))
        .overlay {
            shape.strokeBorder(
                self.isTargeted ? FWColor.textPrimary : FWColor.lineStrong,
                style: StrokeStyle(lineWidth: self.isTargeted ? 1.5 : 1, dash: [6, 5])
            )
        }
    }
}
