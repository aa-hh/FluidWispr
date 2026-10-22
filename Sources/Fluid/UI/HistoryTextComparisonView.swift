import SwiftUI

/// "Show changes" for one History entry: the cleaned line underlines the words cleanup added,
/// and this second line holds the words as heard with the removed ones struck through.
struct HistoryTextComparisonView<Actions: View>: View {
    static var tooLongMessage: String {
        "This entry is too long for inline comparison. Both texts remain available below."
    }

    let entry: TranscriptionHistoryEntry
    let comparison: HistoryTextDiff?
    /// The cleanup line ("Cleaned by …"), when cleanup ran.
    let cleanupDetail: String?
    let actions: Actions

    init(
        entry: TranscriptionHistoryEntry,
        comparison: HistoryTextDiff?,
        cleanupDetail: String?,
        @ViewBuilder actions: () -> Actions
    ) {
        self.entry = entry
        self.comparison = comparison
        self.cleanupDetail = cleanupDetail
        self.actions = actions()
    }

    var body: some View {
        RecordLine(fill: .selected) {
            Text("You said")
                .recordText(FWType.detailStrong)
                .foregroundStyle(FWColor.textSecondary)
            Text("Heard on this Mac")
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textTertiary)
        } content: {
            VStack(alignment: .leading, spacing: FWMetric.space3) {
                Text(Self.originalText(self.entry, comparison: self.comparison))
                    .recordText(FWType.transcript)
                    .foregroundStyle(FWColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 600, alignment: .leading)
                if let cleanupDetail {
                    Text(cleanupDetail)
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textTertiary)
                }
                self.actions
            }
        }
    }

    /// The cleaned text with the words cleanup added underlined; no colour.
    static func finalText(_ entry: TranscriptionHistoryEntry, comparison: HistoryTextDiff?) -> AttributedString {
        guard let comparison else { return AttributedString(entry.clipboardText ?? "") }
        return self.marked(comparison.final) { $0.underlineStyle = .single }
    }

    /// The words as heard with the words cleanup removed struck through.
    static func originalText(_ entry: TranscriptionHistoryEntry, comparison: HistoryTextDiff?) -> AttributedString {
        guard let comparison else { return AttributedString(entry.rawText) }
        return self.marked(comparison.original) { $0.strikethroughStyle = .single }
    }

    /// Compares off the main thread; nil when the texts are past the comparison's size limit.
    static func compare(_ entry: TranscriptionHistoryEntry) async -> HistoryTextDiff? {
        let original = entry.rawText
        let final = entry.clipboardText ?? ""
        return await Task.detached(priority: .utility) {
            HistoryTextDiff.compare(original: original, final: final)
        }.value
    }

    private static func marked(_ runs: [HistoryTextDiff.Run], _ mark: (inout AttributedString) -> Void) -> AttributedString {
        var text = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            if run.changed { mark(&part) }
            text.append(part)
        }
        return text
    }
}
