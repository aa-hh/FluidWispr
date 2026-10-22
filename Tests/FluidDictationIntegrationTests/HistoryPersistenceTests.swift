import Combine
@testable import FluidVoice_Debug
import Foundation
import SQLite3
import XCTest

// The real history store on a throwaway database, UserDefaults suite and audio folder,
// so the installed app's history and saved recordings are never touched.
@MainActor
final class HistoryPersistenceTests: XCTestCase {
    private static let legacyKey = "TranscriptionHistoryEntries"
    private var folders: [URL] = []
    private var suites: [String] = []

    private let audio = DictationAudioMetadata(
        fileName: "test.wav",
        durationMilliseconds: 1000,
        byteCount: 32_000,
        sampleRate: 16_000,
        channels: 1,
        model: "test"
    )

    override func tearDown() {
        for folder in self.folders {
            try? FileManager.default.removeItem(at: folder)
        }
        for suite in self.suites {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        self.folders = []
        self.suites = []
        super.tearDown()
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory // isolation-ok: unique folder removed in tearDown
            .appendingPathComponent("HistoryPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folders.append(folder)
        return folder
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "HistoryPersistenceTests.\(UUID().uuidString)"
        self.suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite)) // isolation-ok: throwaway suite
    }

    private func makeStore(
        writer: TranscriptionHistoryWriter,
        root: URL,
        summaryNow: @escaping () -> Date = Date.init,
        summaryCalendar: @escaping () -> Calendar = { Calendar.current }
    ) -> TranscriptionHistoryStore {
        TranscriptionHistoryStore(
            writer: writer,
            audioStore: DictationAudioHistoryStore(directory: root.appendingPathComponent("audio", isDirectory: true)),
            summaryNow: summaryNow,
            summaryCalendar: summaryCalendar
        )
    }

    private func legacyEntries() -> [TranscriptionHistoryEntry] {
        (0..<8400).map { index in
            TranscriptionHistoryEntry(
                timestamp: Date(timeIntervalSince1970: Double(index)),
                rawText: "Raw \(index)",
                processedText: String(repeating: "Test dictation \(index). ", count: 12),
                appName: "Test",
                windowTitle: "Test",
                wasAIProcessed: true,
                processingModel: "test",
                transcriptionDurationMilliseconds: 50,
                aiProcessingDurationMilliseconds: 100,
                aiTokensPerSecond: 500,
                audio: index == 0 ? self.audio : nil
            )
        }
    }

    private func entry(_ timestamp: Date, _ text: String) -> TranscriptionHistoryEntry {
        TranscriptionHistoryEntry(
            timestamp: timestamp,
            rawText: text,
            processedText: text,
            appName: "Test",
            windowTitle: "Test",
            wasAIProcessed: false
        )
    }

    private static func sql(_ url: URL, _ command: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let result = sqlite3_exec(handle, command, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw NSError(domain: "HistoryPersistenceTests.sql", code: Int(result))
        }
    }

    // Turns red if migrating old history loses edits made during startup, rewrites unrelated rows,
    // drops in-memory entries after a disk error, or lets cleared history come back.
    func testMigrationStartupEditsFailureAndClear() async throws {
        let root = try self.makeFolder()
        let defaults = try self.makeDefaults()
        let legacy = self.legacyEntries()
        // History written before stars existed, including legacy backups.
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [[String: Any]])
        for index in legacyJSON.indices {
            legacyJSON[index].removeValue(forKey: "isStarred")
        }
        defaults.set(try JSONSerialization.data(withJSONObject: legacyJSON), forKey: Self.legacyKey)
        let url = root.appendingPathComponent("history.sqlite3")
        let writer = TranscriptionHistoryWriter(defaults: defaults, url: url)
        let store = self.makeStore(writer: writer, root: root)
        // No actor suspension: these edits necessarily come before startup loading.
        let newID = UUID()
        store.addEntry(id: newID, rawText: "new", processedText: "New dictation", appName: "Test", windowTitle: "Test")
        store.attachAudio(self.audio, to: newID)
        store.deleteEntry(id: legacy[1].id)
        store.commitPendingDelete()
        try await store.waitUntilLoaded()
        await store.waitForTodaySummary()
        XCTAssertEqual(store.todaySummary, .init(words: 2, transcriptions: 1), "Startup stats must include merged pending edits")
        await store.finishPendingWrites()
        XCTAssertNil(defaults.data(forKey: Self.legacyKey), "Retire legacy only after a successful import")
        XCTAssertEqual(store.entries.count, 8400)
        XCTAssertEqual(store.entries.first(where: { $0.id == newID })?.audio, self.audio)
        XCTAssertEqual(store.entries.filter(\.isStarred).count, 0, "Legacy entries must default to unstarred")
        XCTAssertFalse(store.entries.contains(where: { $0.id == legacy[1].id }))
        let reloaded = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        XCTAssertEqual(reloaded, store.entries, "Migration, metadata and concurrent startup edits must round-trip")

        // Reject a write touching any old entry. A new dictation and its audio must only update their row.
        try Self.sql(url, "CREATE TRIGGER reject_old BEFORE INSERT ON history WHEN NEW.id != '\(newID.uuidString)' BEGIN SELECT RAISE(FAIL, 'unrelated row rewritten'); END")
        store.attachAudio(self.audio, to: newID)
        store.attachAudio(self.audio, to: newID)
        await store.finishPendingWrites()
        await Task.yield()
        XCTAssertNil(store.persistenceError, "Updating one row must not rewrite unrelated history")
        let afterAudio = try await writer.load()
        XCTAssertEqual(afterAudio, store.entries, "Repeated audio updates must persist in order")
        try Self.sql(url, "DROP TRIGGER reject_old")

        try Self.sql(url, "CREATE TRIGGER reject_all BEFORE INSERT ON history BEGIN SELECT RAISE(FAIL, 'test disk failure'); END")
        let failedID = UUID()
        store.addEntry(id: failedID, rawText: "pending", processedText: "Unsaved", appName: "Test", windowTitle: "Test")
        await store.finishPendingWrites()
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertNotNil(store.persistenceError)
        XCTAssertTrue(store.entries.contains(where: { $0.id == failedID }))
        await store.waitForTodaySummary()
        XCTAssertEqual(store.todaySummary, .init(words: 3, transcriptions: 2), "A disk error must not drop in-memory stats")
        let afterFailure = try await writer.load()
        XCTAssertFalse(afterFailure.contains(where: { $0.id == failedID }))
        store.retryPersistence()
        await store.finishPendingWrites()
        let afterFailedReplacement = try await writer.load()
        XCTAssertEqual(afterFailedReplacement, afterFailure, "A failed replacement must roll back its initial DELETE")
        try Self.sql(url, "DROP TRIGGER reject_all")
        store.retryPersistence()
        await store.finishPendingWrites()
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertNil(store.persistenceError)
        let afterRetry = try await writer.load()
        XCTAssertTrue(afterRetry.contains(where: { $0.id == failedID }))

        store.clearAllHistory()
        store.attachAudio(self.audio, to: newID)
        await store.finishPendingWrites()
        let afterClear = try await writer.load()
        XCTAssertTrue(afterClear.isEmpty, "Late audio must not bring deleted entries back")
        defaults.set(try JSONEncoder().encode(legacy), forKey: Self.legacyKey)
        let afterRestart = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        XCTAssertTrue(afterRestart.isEmpty, "The migration marker must stop old history coming back")
    }

    // Turns red if unreadable legacy history is deleted, leaves the store loading forever, or
    // cannot be retried once fixed.
    func testCorruptLegacyMigrationKeepsSourceAndRetries() async throws {
        let root = try self.makeFolder()
        let defaults = try self.makeDefaults()
        let badData = Data("invalid JSON".utf8)
        defaults.set(badData, forKey: Self.legacyKey)
        let store = self.makeStore(writer: TranscriptionHistoryWriter(defaults: defaults, url: root.appendingPathComponent("bad.sqlite3")), root: root)
        do {
            try await store.waitUntilLoaded()
            XCTFail("Corrupt legacy history must fail visibly")
        } catch {}
        XCTAssertFalse(store.isLoading)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(defaults.data(forKey: Self.legacyKey), badData)
        let legacy = self.legacyEntries()[0]
        defaults.set(try JSONEncoder().encode([legacy]), forKey: Self.legacyKey)
        store.retryPersistence()
        try await store.waitUntilLoaded()
        var numbered = legacy
        numbered.number = 1
        XCTAssertEqual(store.entries, [numbered])
    }

    // Turns red if restoring a backup during loading keeps the old search revision, or a repeated
    // restore of an older backup fails to move past the currently indexed revision.
    func testRestoreDuringLoadingReplacesMemoryAndDisk() async throws {
        let root = try self.makeFolder()
        let defaults = try self.makeDefaults()
        let url = root.appendingPathComponent("restore.sqlite3")
        let original = self.legacyEntries()[3]
        let store = self.makeStore(writer: TranscriptionHistoryWriter(defaults: defaults, url: url), root: root)
        store.restore(from: [original])
        try await store.waitUntilLoaded()
        await store.finishPendingWrites()
        let revision = try XCTUnwrap(store.entries.first?.searchRevision, "Restore must set a search revision")
        XCTAssertGreaterThan(revision, original.searchRevision ?? 1, "Restore must invalidate the previous search record")
        var expected = original
        expected.searchRevision = revision
        expected.number = 1 // Loading numbers the restored entry, which predates record numbers.
        XCTAssertEqual(store.entries, [expected], "Restore must keep every field except the search revision")
        let afterRestore = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        XCTAssertEqual(afterRestore, [expected], "The new search revision and original content must round-trip")
        store.restore(from: [original])
        await store.finishPendingWrites()
        let nextRevision = try XCTUnwrap(store.entries.first?.searchRevision)
        XCTAssertGreaterThan(nextRevision, revision, "Restoring an older backup must move past the indexed revision")
        expected.searchRevision = nextRevision
        expected.number = 0 // Only loading numbers entries; this restore happened after it.
        let afterRepeatedRestore = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        XCTAssertEqual(afterRepeatedRestore, [expected], "A repeated restore changes only the saved search revision")
    }

    // Turns red if search changes history order or misses a field, a backup loses a stored star,
    // repeated sidebar reveals share one request, or deleting the selected row and committing the
    // delete leaves it on disk.
    func testStarsSearchBackupAndDeletion() async throws {
        let root = try self.makeFolder()
        let defaults = try self.makeDefaults()
        let url = root.appendingPathComponent("stars.sqlite3")
        let writer = TranscriptionHistoryWriter(defaults: defaults, url: url)
        let store = self.makeStore(writer: writer, root: root)
        try await store.waitUntilLoaded()
        let older = TranscriptionHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1),
            rawText: "Original phrasing",
            processedText: "Reusable prompt",
            appName: "Editor",
            windowTitle: "Reference",
            wasAIProcessed: true,
            audio: self.audio,
            isStarred: true
        )
        let newer = self.entry(Date(timeIntervalSince1970: 2), "Another prompt")
        store.restore(from: [older, newer])
        XCTAssertEqual(store.search(query: "").map(\.id), [newer.id, older.id], "Search keeps newest-first order")
        XCTAssertEqual(store.search(query: "prompt").map(\.id), [newer.id, older.id])
        for query in ["PROMPT", "Original", "Editor", "Reference"] {
            XCTAssertEqual(store.search(query: query).map(\.id).last, older.id, "Search must look in every field: \(query)")
        }
        XCTAssertEqual(store.search(query: "Another").map(\.id), [newer.id])
        XCTAssertTrue(older.replacingAudio(nil).isStarred, "Audio removal must keep the stored star")
        let backup = try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: JSONEncoder().encode(store.makeBackupPayload()))
        store.restore(from: backup)
        await store.finishPendingWrites()
        let restored = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        let normalizedRestore = restored.map { entry in
            var entry = entry
            entry.searchRevision = backup.first(where: { $0.id == entry.id })?.searchRevision
            return entry
        }
        XCTAssertEqual(normalizedRestore, backup, "Backup restore must keep stars and metadata while refreshing search revisions")

        store.selectEntryFromSearch(id: older.id)
        let firstRequest = try XCTUnwrap(store.searchSelectionRequest)
        store.selectEntryFromSearch(id: older.id)
        let repeatedRequest = try XCTUnwrap(store.searchSelectionRequest)
        XCTAssertNotEqual(firstRequest, repeatedRequest, "Repeated clicks on the same result need a fresh request")
        store.consumeSearchSelectionRequest(firstRequest)
        XCTAssertEqual(store.searchSelectionRequest, repeatedRequest, "A stale consumer must not clear the latest request")
        store.consumeSearchSelectionRequest(repeatedRequest)
        XCTAssertNil(store.searchSelectionRequest)
        store.selectedEntryID = older.id
        store.deleteEntry(id: older.id)
        XCTAssertEqual(store.selectedEntryID, newer.id, "Deleting the selected row falls back to the first entry")
        XCTAssertNil(store.searchSelectionRequest, "The delete fallback must not reset History search")
        store.commitPendingDelete()
        await store.finishPendingWrites()
        let afterDelete = try await writer.load()
        XCTAssertEqual(afterDelete, restored.filter { $0.id == newer.id }, "A committed delete must reach disk")
    }

    // Turns red if deleting removes the audio file or saves the delete before the Undo note
    // goes away, or if Undo puts the entry back in another place or with another number, or if
    // undoDelete stops saving the entry so a retryPersistence rewrite during the wait loses it.
    func testDeleteThenUndoKeepsNumberPlaceAndAudio() async throws {
        let root = try self.makeFolder()
        let defaults = try self.makeDefaults()
        let url = root.appendingPathComponent("undo.sqlite3")
        let audioFolder = root.appendingPathComponent("audio", isDirectory: true)
        let store = self.makeStore(writer: TranscriptionHistoryWriter(defaults: defaults, url: url), root: root)
        try await store.waitUntilLoaded()
        var first = self.entry(Date(timeIntervalSince1970: 3), "newest")
        first.number = 3
        var middle = TranscriptionHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 2),
            rawText: "middle",
            processedText: "middle",
            appName: "Test",
            windowTitle: "Test",
            wasAIProcessed: false,
            audio: self.audio
        )
        middle.number = 2
        var last = self.entry(Date(timeIntervalSince1970: 1), "oldest")
        last.number = 1
        store.restore(from: [first, middle, last])
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        let audioFile = audioFolder.appendingPathComponent(self.audio.fileName)
        try Data([0]).write(to: audioFile)
        await store.finishPendingWrites()

        store.deleteEntry(id: middle.id)
        XCTAssertEqual(store.entries.map(\.id), [first.id, last.id])
        XCTAssertEqual(store.pendingUndo?.entry.id, middle.id)
        await store.finishPendingWrites()
        let beforeUndo = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        XCTAssertTrue(beforeUndo.contains { $0.id == middle.id }, "The delete must wait for the Undo note")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioFile.path), "The recording must survive until the delete is committed")
        store.retryPersistence()
        await store.finishPendingWrites()

        store.undoDelete()
        XCTAssertNil(store.pendingUndo)
        XCTAssertEqual(store.entries.map(\.id), [first.id, middle.id, last.id], "Undo puts the entry back in its place")
        XCTAssertEqual(store.entries[1].number, 2, "Undo keeps the record number")
        XCTAssertEqual(store.entries[1].audio, self.audio, "Undo keeps the recording")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioFile.path))
        await store.finishPendingWrites()
        let afterUndo = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        XCTAssertTrue(afterUndo.contains { $0.id == middle.id }, "Undo must save the entry again after a full rewrite dropped it")
    }

    // Turns red if committing a pending delete keeps the recording or the saved row, or if a new
    // dictation leaves an earlier delete waiting for Undo.
    func testCommitPendingDeleteRemovesRecordAndAudio() async throws {
        let root = try self.makeFolder()
        let defaults = try self.makeDefaults()
        let url = root.appendingPathComponent("commit.sqlite3")
        let audioFolder = root.appendingPathComponent("audio", isDirectory: true)
        let store = self.makeStore(writer: TranscriptionHistoryWriter(defaults: defaults, url: url), root: root)
        try await store.waitUntilLoaded()
        let kept = self.entry(Date(timeIntervalSince1970: 1), "kept")
        let deleted = TranscriptionHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 2),
            rawText: "gone",
            processedText: "gone",
            appName: "Test",
            windowTitle: "Test",
            wasAIProcessed: false,
            audio: self.audio
        )
        store.restore(from: [deleted, kept])
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        let audioFile = audioFolder.appendingPathComponent(self.audio.fileName)
        try Data([0]).write(to: audioFile)
        await store.finishPendingWrites()

        store.deleteEntry(id: deleted.id)
        store.addEntry(rawText: "next", processedText: "Next dictation", appName: "Test", windowTitle: "Test")
        XCTAssertNil(store.pendingUndo, "A new dictation commits the waiting delete")
        await store.finishPendingWrites()
        let saved = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        XCTAssertFalse(saved.contains { $0.id == deleted.id }, "The committed delete must reach disk")
        XCTAssertTrue(saved.contains { $0.id == kept.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioFile.path), "The committed delete must remove the recording")
        store.undoDelete()
        XCTAssertFalse(store.entries.contains { $0.id == deleted.id }, "Undo after a commit must do nothing")
    }

    // Turns red if loading stops numbering entries saved before record numbers existed, numbers
    // them out of the order they were spoken, reuses a number already in use, or loses the
    // numbers on the next reload.
    func testRecordNumbersBackFillInTimestampOrderAndSurviveReload() async throws {
        let root = try self.makeFolder()
        let defaults = try self.makeDefaults()
        let url = root.appendingPathComponent("numbers.sqlite3")
        var numberedAlready = self.entry(Date(timeIntervalSince1970: 20), "already numbered")
        numberedAlready.number = 7
        let oldest = self.entry(Date(timeIntervalSince1970: 10), "oldest")
        let newest = self.entry(Date(timeIntervalSince1970: 30), "newest")
        defaults.set(try JSONEncoder().encode([newest, numberedAlready, oldest]), forKey: Self.legacyKey)

        let store = self.makeStore(writer: TranscriptionHistoryWriter(defaults: defaults, url: url), root: root)
        try await store.waitUntilLoaded()
        await store.finishPendingWrites()
        let numbers = Dictionary(uniqueKeysWithValues: store.entries.map { ($0.id, $0.number) })
        XCTAssertEqual(numbers[numberedAlready.id], 7)
        XCTAssertEqual(numbers[oldest.id], 8)
        XCTAssertEqual(numbers[newest.id], 9)
        XCTAssertGreaterThanOrEqual(SettingsStore.shared.historyNextRecordNumber, 10)

        let reloaded = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: reloaded.map { ($0.id, $0.number) }), numbers)
    }

    // Turns red if restore stops moving the saved record counter past the restored numbers, so the
    // next dictation reuses a number already shown in History.
    func testRestoreMovesRecordCounterPastRestoredNumbers() async throws {
        let root = try self.makeFolder()
        let defaults = try self.makeDefaults()
        let url = root.appendingPathComponent("restore-numbers.sqlite3")
        let store = self.makeStore(writer: TranscriptionHistoryWriter(defaults: defaults, url: url), root: root)
        try await store.waitUntilLoaded()
        let settings = SettingsStore.shared // isolation-ok: the record counter only lives here; reset by defer
        let savedCounter = settings.historyNextRecordNumber
        defer { settings.historyNextRecordNumber = savedCounter }
        settings.historyNextRecordNumber = 0

        let backup = (1...3).map { number in
            var entry = self.entry(Date(timeIntervalSince1970: Double(number)), "restored \(number)")
            entry.number = number
            return entry
        }
        store.restore(from: backup)
        let newID = UUID()
        store.addEntry(id: newID, rawText: "new", processedText: "New dictation", appName: "Test", windowTitle: "Test")
        await store.finishPendingWrites()

        XCTAssertEqual(store.entries.first { $0.id == newID }?.number, 4)
    }

    // Turns red if today's word count reads the clock on every render, counts the wrong local day
    // across DST or a time zone change, or publishes a stale result after rapid edits.
    func testTodaySummary() async throws {
        let root = try self.makeFolder()
        let defaults = try self.makeDefaults()
        var now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-08T18:00:00Z"))
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let plusFourteen = try XCTUnwrap(TimeZone(secondsFromGMT: 14 * 3600))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = losAngeles
        var clockReads = 0
        let store = self.makeStore(
            writer: TranscriptionHistoryWriter(defaults: defaults, url: root.appendingPathComponent("summary.sqlite3")),
            root: root,
            summaryNow: {
                clockReads += 1
                return now
            },
            summaryCalendar: { calendar }
        )
        try await store.waitUntilLoaded()
        await store.waitForTodaySummary()
        let day = try XCTUnwrap(calendar.dateInterval(of: .day, for: now))
        XCTAssertEqual(day.duration, 23 * 3600, "The fixture must cover a DST-shortened day")
        let yesterday = self.entry(day.start.addingTimeInterval(-1), "not today")
        let first = self.entry(day.start, "  one\t two\nthree  ")
        let last = self.entry(day.end.addingTimeInterval(-1), "four")
        let tomorrow = self.entry(day.end, "next day")
        store.restore(from: [yesterday, first, last, tomorrow])
        await store.waitForTodaySummary()
        XCTAssertEqual(store.todaySummary, .init(words: 4, transcriptions: 2), "Keep word splitting and half-open local-day bounds")
        let reads = clockReads
        let unchangedEntries = store.entries
        var summedWords = 0
        for _ in 0..<10_000 {
            summedWords += store.todaySummary.words
        }
        XCTAssertEqual(summedWords, 40_000, "Reading the summary must not change it")
        XCTAssertEqual(clockReads, reads, "Rendering must not read the clock or schedule a recount")
        store.attachAudio(self.audio, to: first.id)
        await store.waitForTodaySummary()
        XCTAssertEqual(clockReads, reads, "Audio-only changes must not recount text stats")
        XCTAssertEqual(store.entries.map(\.processedText), unchangedEntries.map(\.processedText))
        XCTAssertEqual(store.selectedEntryID, unchangedEntries.first?.id, "Summary work must not change selection")
        store.deleteEntry(id: UUID())
        store.deleteEntries(ids: [])
        await store.waitForTodaySummary()
        XCTAssertEqual(clockReads, reads, "Deleting nothing must not schedule work")

        store.addEntry(id: UUID(), timestamp: now, rawText: "new text", processedText: "new text", appName: "Test", windowTitle: "Test")
        store.deleteEntry(id: first.id)
        store.deleteEntries(ids: [last.id])
        await store.waitForTodaySummary()
        XCTAssertEqual(store.todaySummary, .init(words: 2, transcriptions: 1))
        store.addEntry(timestamp: now, rawText: "", processedText: " \n ", appName: "Test", windowTitle: "Test")
        await store.waitForTodaySummary()
        XCTAssertEqual(store.todaySummary, .init(words: 2, transcriptions: 1))

        // A bulk replacement followed by rapid changes must only publish the latest history.
        store.restore(from: Array(repeating: first, count: 10_000))
        await Task.yield()
        store.restore(from: [yesterday, first, last, tomorrow])
        store.deleteEntries(ids: [first.id, last.id])
        await store.waitForTodaySummary()
        XCTAssertEqual(store.todaySummary, .init(words: 0, transcriptions: 0), "Never apply a stale bulk result")
        var replacedFromSubscriber = false
        let subscription = store.$todaySummary.sink { summary in
            guard summary.words == 3, !replacedFromSubscriber else { return }
            replacedFromSubscriber = true
            store.restore(from: [yesterday, tomorrow])
        }
        store.restore(from: [first])
        await store.waitForTodaySummary()
        XCTAssertTrue(replacedFromSubscriber)
        XCTAssertEqual(store.todaySummary, .init(words: 0, transcriptions: 0), "Changes made while publishing must not be lost")
        subscription.cancel()

        now = day.end.addingTimeInterval(1)
        store.refreshTodaySummaryForCalendarChange()
        await store.waitForTodaySummary()
        XCTAssertEqual(store.todaySummary, .init(words: 2, transcriptions: 1), "Midnight must refresh without a dictation")
        now = day.end.addingTimeInterval(12 * 3600)
        calendar.timeZone = plusFourteen
        store.refreshTodaySummaryForCalendarChange()
        await store.waitForTodaySummary()
        XCTAssertEqual(store.todaySummary, .init(words: 0, transcriptions: 0), "Time zone changes must redefine today")
        now = yesterday.timestamp
        calendar.timeZone = losAngeles
        store.refreshTodaySummaryForCalendarChange()
        await store.waitForTodaySummary()
        XCTAssertEqual(store.todaySummary, .init(words: 2, transcriptions: 1), "The clock moving backward must refresh")
        let settledReads = clockReads
        store.refreshTodaySummaryForCalendarChange()
        await store.waitForTodaySummary()
        XCTAssertEqual(clockReads, settledReads + 1, "Activation within the same day must not rebuild")
        store.clearAllHistory()
        await store.waitForTodaySummary()
        XCTAssertEqual(store.todaySummary, .init(words: 0, transcriptions: 0))
        await store.finishPendingWrites()
    }
}
