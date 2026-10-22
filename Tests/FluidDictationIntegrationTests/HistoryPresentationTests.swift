@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class HistoryPresentationTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private let audio = DictationAudioMetadata(
        fileName: "saved.wav",
        durationMilliseconds: 10_300,
        byteCount: 331_000,
        sampleRate: 16_000,
        channels: 1,
        model: nil
    )

    private func enhancedEntry() -> TranscriptionHistoryEntry {
        TranscriptionHistoryEntry(
            rawText: " raw words ",
            processedText: " final words ",
            appName: "Notes",
            windowTitle: "",
            wasAIProcessed: true,
            processingModel: "historical-model",
            transcriptionDurationMilliseconds: 57,
            aiProcessingDurationMilliseconds: 104,
            aiTokensPerSecond: 746,
            audio: self.audio
        )
    }

    // Turns red if missing or deleted audio files show as playable, the check runs on the main
    // thread, or empty metadata still queries the disk.
    func testAudioAvailabilityScan() async throws {
        let directory = FileManager.default.temporaryDirectory // isolation-ok: unique folder removed below
            .appendingPathComponent("HistoryPresentationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedFile = directory.appendingPathComponent("saved.wav")
        try Data([0]).write(to: savedFile)
        let ranOnMain = LockedFlag()
        let exists: @Sendable (String) -> Bool = { name in
            if Thread.isMainThread { ranOnMain.set() }
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        let initial = await HistoryAudioAvailability.scan(fileNames: ["saved.wav", "missing.wav", "saved.wav"], exists: exists)
        XCTAssertEqual(initial, ["saved.wav"], "Missing restored files must not appear available")
        try FileManager.default.removeItem(at: savedFile)
        let deleted = await HistoryAudioAvailability.scan(fileNames: ["saved.wav"], exists: exists)
        XCTAssertTrue(deleted.isEmpty, "Refresh must drop files deleted outside the app")
        let queried = LockedFlag()
        let emptyAudio = await HistoryAudioAvailability.scan(fileNames: []) { _ in
            queried.set()
            return false
        }
        XCTAssertTrue(emptyAudio.isEmpty)
        XCTAssertFalse(queried.isSet, "No metadata must mean no file queries")
        let cancelled = Task {
            await HistoryAudioAvailability.scan(fileNames: ["saved.wav"], exists: exists)
        }
        cancelled.cancel()
        _ = await cancelled.value
        XCTAssertFalse(ranOnMain.isSet, "Availability checks must not run on the main thread")
    }

    // Turns red if an external selection hidden by a filter is not revealed, a visible, missing,
    // local or stale selection clears the filters, or the History view stops wiring the policy.
    func testSelectionRevealPolicyAndWiring() throws {
        let entry = self.enhancedEntry()
        XCTAssertTrue(HistorySelectionRevealPolicy.needsFilterReset(
            requestedID: entry.id, selectedID: entry.id, allEntries: [entry], visibleEntries: []
        ), "An empty search result must still reveal an existing external selection")
        XCTAssertFalse(HistorySelectionRevealPolicy.needsFilterReset(
            requestedID: entry.id, selectedID: entry.id, allEntries: [entry], visibleEntries: [entry]
        ), "Already visible selections must keep active filters")
        XCTAssertFalse(HistorySelectionRevealPolicy.needsFilterReset(
            requestedID: entry.id, selectedID: nil, allEntries: [entry], visibleEntries: []
        ), "An empty selection must keep filters")
        let missingID = UUID()
        XCTAssertFalse(HistorySelectionRevealPolicy.needsFilterReset(
            requestedID: missingID, selectedID: missingID, allEntries: [entry], visibleEntries: []
        ), "Missing or deleted selections must keep filters")
        XCTAssertFalse(HistorySelectionRevealPolicy.needsFilterReset(
            requestedID: nil, selectedID: entry.id, allEntries: [entry], visibleEntries: []
        ), "Local selection changes must not clear the search without a search request")
        XCTAssertFalse(HistorySelectionRevealPolicy.needsFilterReset(
            requestedID: missingID, selectedID: entry.id, allEntries: [entry], visibleEntries: []
        ), "An older search request cannot override a newer local selection")

        let viewSource = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/Fluid/UI/TranscriptionHistoryView.swift"),
            encoding: .utf8
        )
        let parent = viewSource.components(separatedBy: "private var entryListView:").first ?? ""
        XCTAssertTrue(parent.contains(".onChange(of: self.historyStore.searchSelectionRequest)"), "External selection must be observed outside the list")
        XCTAssertFalse(parent.contains(".onChange(of: self.historyStore.selectedEntryID)"), "Local selection must not become an external reveal")
        XCTAssertTrue(parent.contains("self.revealExternalSelection()"), "The parent view must use the tested policy")
        XCTAssertTrue(
            parent.contains("self.audioAvailabilityRevision = UUID()\n                self.revealExternalSelection()"),
            "First appearance must reveal the already-selected row"
        )
        XCTAssertFalse(parent.contains("filteredEntries.map(\\.id), initial: true"), "The first filter fallback must not erase an external selection")
        let contentSource = try String(contentsOf: Self.repoRoot.appendingPathComponent("Sources/Fluid/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(
            contentSource.contains("TranscriptionHistoryStore.shared.selectEntryFromSearch(id: id)"),
            "Sidebar navigation must send the explicit request before opening History"
        )
    }

    // Turns red if Copy picks the wrong text, reading it changes the entry, saved fields are lost
    // in a round trip, or the timing labels change format.
    func testCopyTextRoundTripAndLabels() throws {
        let enhanced = self.enhancedEntry()
        let before = enhanced
        XCTAssertEqual(enhanced.clipboardText, "final words")
        XCTAssertEqual(enhanced, before, "Reading copy text must not change an entry")
        let raw = TranscriptionHistoryEntry(rawText: " raw words ", processedText: "  ", appName: "Notes", windowTitle: "", wasAIProcessed: false)
        XCTAssertEqual(raw.clipboardText, "raw words")
        let empty = TranscriptionHistoryEntry(rawText: " ", processedText: " ", appName: "Notes", windowTitle: "", wasAIProcessed: false)
        XCTAssertNil(empty.clipboardText)
        let decoded = try JSONDecoder().decode(TranscriptionHistoryEntry.self, from: JSONEncoder().encode(enhanced))
        XCTAssertEqual(decoded, enhanced, "Presentation must keep saved fields")
        XCTAssertEqual(decoded.processingModel, "historical-model")
        XCTAssertEqual(TranscriptionHistoryEntry.formattedTokensPerSecond(746, compact: true), "746 tok/s")
        XCTAssertEqual(TranscriptionHistoryEntry.formattedDuration(milliseconds: 104), "104 ms")
    }

    // Turns red if the before and after view drops or invents text, marks the wrong words as
    // changed, or compares inputs past its size limit.
    func testTextDiff() throws {
        let cases = [
            ("Hello world", "Hello world"),
            ("Hello world", "Hello, world!"),
            ("red blue", "green blue"),
            ("", "new words"),
            ("old words", ""),
            ("one  two\nthree", "One two\n\nthree."),
            ("hello hello world", "hello world"),
            ("வணக்கம் 👋🏽 café", "வணக்கம் 👋🏽 Café!"),
        ]
        for (original, final) in cases {
            let diff = try XCTUnwrap(HistoryTextDiff.compare(original: original, final: final), "Expected a comparison for \(original)")
            XCTAssertEqual(diff.original.map(\.text).joined(), original)
            XCTAssertEqual(diff.final.map(\.text).joined(), final)
            XCTAssertEqual(diff.hasChanges, original != final)
        }
        let replacement = try XCTUnwrap(HistoryTextDiff.compare(original: "red blue", final: "green blue"))
        XCTAssertEqual(replacement.original.filter(\.changed).map(\.text).joined(), "red")
        XCTAssertEqual(replacement.final.filter(\.changed).map(\.text).joined(), "green")
        XCTAssertNil(HistoryTextDiff.compare(original: String(repeating: "a ", count: 2000), final: ""))
        XCTAssertNil(HistoryTextDiff.compare(original: String(repeating: "x", count: 24_001), final: ""))
    }

    // Turns red if a model with no registered display name is shown as anything but its trimmed ID.
    // The default build registers no private models, so only the fallback is checked.
    func testModelDisplayNameFallsBackToID() {
        XCTAssertEqual(ModelDisplayName.forID("external/model-v2"), "external/model-v2")
        XCTAssertEqual(ModelDisplayName.forID("  external/model-v2  "), "external/model-v2")
        XCTAssertEqual(ModelDisplayName.forID(""), "")
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        self.lock.lock()
        self.value = true
        self.lock.unlock()
    }

    var isSet: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }
}
