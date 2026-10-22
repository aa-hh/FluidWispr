import AppKit
import SwiftUI

/// Keep long transcripts out of SwiftUI's unconstrained Text measurement path.
/// AppKit lays out the viewport and retains its text storage across parent updates.
struct FileTranscriptTextView: NSViewRepresentable {
    let entryID: UUID
    let text: String

    func makeNSView(context: Context) -> FileTranscriptScrollView {
        FileTranscriptScrollView(frame: .zero)
    }

    func updateNSView(_ view: FileTranscriptScrollView, context: Context) {
        view.display(
            entryID: self.entryID,
            text: self.text,
            font: .fluidSystemFont(ofSize: 15),
            color: NSColor(FWColor.textPrimary),
            inset: NSSize(width: FWMetric.space7, height: FWMetric.space5)
        )
    }
}
