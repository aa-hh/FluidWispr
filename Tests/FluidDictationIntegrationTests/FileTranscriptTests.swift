import AppKit
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class FileTranscriptTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in self.suites {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        self.suites = []
        super.tearDown()
    }

    // Turns red if renaming a file transcript changes anything but its title and search revision,
    // a blank or stale rename does work, or a saved transcript without a title stops decoding.
    func testRenameKeepsTranscriptAndSelection() throws {
        let suite = "FileTranscriptTests.\(UUID().uuidString)"
        self.suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)) // isolation-ok: throwaway suite
        let store = FileTranscriptionHistoryStore(defaults: defaults)
        store.addEntry(TranscriptionResult(
            text: "Keep the transcript",
            confidence: 0.9,
            duration: 12,
            processingTime: 1,
            fileName: "original.wav",
            speakerSegments: [SpeakerTranscriptSegment(speaker: "A", startSeconds: 0, endSeconds: 2, text: "Speaker text")],
            speakerLabelingNotice: "Notice",
            speakerLabelingGaps: [SpeakerTranscriptGap(startSeconds: 2, endSeconds: 3)]
        ))
        let original = try XCTUnwrap(store.selectedEntry, "Adding a transcript must select it")
        store.renameEntry(id: original.id, to: "  Weekly review  ")
        let renamed = try XCTUnwrap(store.selectedEntry, "Renaming must keep the selection")
        XCTAssertEqual(renamed.displayTitle, "Weekly review")
        XCTAssertEqual(renamed.fileName, original.fileName)
        XCTAssertEqual(renamed.text, original.text)
        XCTAssertEqual(renamed.speakerSegments, original.speakerSegments)
        XCTAssertEqual(renamed.speakerLabelingGaps, original.speakerLabelingGaps)
        XCTAssertEqual(renamed.timestamp, original.timestamp)
        XCTAssertEqual(renamed.id, original.id)
        XCTAssertEqual(renamed.searchRevision, 2)
        store.renameEntry(id: original.id, to: "  ")
        store.renameEntry(id: UUID(), to: "Stale")
        store.renameEntry(id: original.id, to: renamed.displayTitle)
        XCTAssertEqual(store.selectedEntry, renamed)
        XCTAssertEqual(FileTranscriptionHistoryStore(defaults: defaults).entries, [renamed])
        store.renameEntry(id: original.id, to: "Second title")
        XCTAssertEqual(store.selectedEntry?.searchRevision, 3)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(renamed)) as? [String: Any])
        legacy.removeValue(forKey: "customTitle")
        legacy.removeValue(forKey: "searchRevision")
        let decoded = try JSONDecoder().decode(FileTranscriptionEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.displayTitle, original.fileName)
        XCTAssertNil(decoded.searchRevision)
    }

    // Turns red if redisplaying the same transcript rewrites the text, moves the scroll position
    // or drops the selection, or switching transcripts shows stale text.
    func testScrollViewKeepsReadingPosition() throws {
        _ = NSApplication.shared
        let view = FileTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 450, height: 600))
        let textView = try XCTUnwrap(view.documentView as? NSTextView)
        let id = UUID()
        let text = String(repeating: "A long transcript with café, 日本語, and 👨‍👩‍👧‍👦.\n", count: 4000)
        view.display(entryID: id, text: text, font: .systemFont(ofSize: 14), color: .labelColor, inset: 16)
        XCTAssertEqual(textView.string, text, "The full transcript must be kept")
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertEqual(textView.layoutManager?.allowsNonContiguousLayout, true)
        textView.setSelectedRange(NSRange(location: 8, length: 30))
        textView.setFrameSize(NSSize(width: 450, height: 50000))
        view.contentView.scroll(to: NSPoint(x: 0, y: 400))
        let readingPosition = view.contentView.bounds.origin
        XCTAssertGreaterThan(readingPosition.y, 0, "The fixture must start scrolled away from the top")
        let storage = try XCTUnwrap(textView.textStorage)
        var edits = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { _ in
            edits += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for _ in 0..<100 {
            view.display(entryID: id, text: text, font: .systemFont(ofSize: 14), color: .labelColor, inset: 16)
        }
        XCTAssertEqual(edits, 0, "Unrelated updates must not replace or restyle the text")
        XCTAssertEqual(view.contentView.bounds.origin, readingPosition, "Unrelated updates must not move the reading position")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 8, length: 30), "Unrelated updates must keep the selection")
        view.display(entryID: id, text: text, font: .systemFont(ofSize: 16), color: .systemBlue, inset: 20)
        XCTAssertEqual(textView.string, text, "Font and colour changes must keep the content")
        XCTAssertEqual(textView.selectedRange().length, 30, "Font and colour changes must keep the selection")
        view.display(entryID: id, text: "Updated", font: .systemFont(ofSize: 14), color: .labelColor, inset: 16)
        XCTAssertEqual(textView.string, "Updated", "Edits to the same transcript must not show stale text")
        for index in 0..<100 {
            view.display(entryID: UUID(), text: "Transcript \(index)", font: .systemFont(ofSize: 14), color: .labelColor, inset: 16)
        }
        XCTAssertEqual(textView.string, "Transcript 99")
        XCTAssertEqual(textView.selectedRange().length, 0)
        view.display(entryID: UUID(), text: "", font: .systemFont(ofSize: 14), color: .labelColor, inset: 16)
        XCTAssertTrue(textView.string.isEmpty, "Empty input must clear the previous content")
    }
}
