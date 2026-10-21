@testable import FluidVoice_Debug
import Foundation
import XCTest

private struct FixtureFailure: Error {}

/// Settings in memory. The first prompt profile's name says which backup they came from.
@MainActor
private final class BackupSettingsFixture: BackupSettings {
    var payload: SettingsBackupPayload
    var dictationPromptProfiles: [SettingsStore.DictationPromptProfile]
    var appPromptBindings: [SettingsStore.AppPromptBinding] = []
    var privateAIIdleUnload: SettingsStore.PrivateAIIdleUnload = .thirtyMinutes
    var restores = 0

    init(payload: SettingsBackupPayload, owner: String) {
        self.payload = payload
        self.dictationPromptProfiles = [SettingsStore.DictationPromptProfile(name: owner, prompt: "")]
    }

    var owner: String? { self.dictationPromptProfiles.first?.name }

    func makeBackupPayload() throws -> SettingsBackupPayload {
        self.payload
    }

    func restore(
        from payload: SettingsBackupPayload,
        promptProfiles: [SettingsStore.DictationPromptProfile],
        appPromptBindings: [SettingsStore.AppPromptBinding]
    ) {
        self.restores += 1
        self.payload = payload
        self.dictationPromptProfiles = promptProfiles
        self.appPromptBindings = appPromptBindings
        // Like SettingsStore: an older backup without the field keeps the current value.
        if let idle = payload.privateAIIdleUnload { self.privateAIIdleUnload = idle }
    }
}

/// History in memory. It can park while loading so a test can act in the middle of an export.
@MainActor
private final class BackupHistoryFixture: BackupHistory {
    var entries: [TranscriptionHistoryEntry]
    var failsToLoad = false
    var holdLoad = false
    var held: CheckedContinuation<Void, Never>?
    var loads = 0
    var writes = 0

    init(owner: String) {
        self.entries = [BackupServiceConcurrencyTests.entry(owner)]
    }

    var owner: String? { self.entries.first?.rawText }

    func waitUntilLoaded() async throws {
        self.loads += 1
        if self.holdLoad {
            self.holdLoad = false
            await withCheckedContinuation { self.held = $0 }
        }
        if self.failsToLoad { throw FixtureFailure() }
    }

    func makeBackupPayload() -> [TranscriptionHistoryEntry] {
        self.entries
    }

    func restore(from payload: [TranscriptionHistoryEntry]) {
        self.writes += 1
        self.entries = payload
    }
}

/// Voice profiles in memory. Reads and writes can park, and writes can fail.
@MainActor
private final class ProfileStoreFixture {
    var profiles: [PronunciationDictionaryProfile]
    var holdRead = false
    var holdReplace = false
    var rejects = false
    var held: CheckedContinuation<Void, Never>?
    var reads = 0
    var replacements = 0

    init(owner: String) {
        self.profiles = [BackupServiceConcurrencyTests.profile(owner)]
    }

    var owner: String? { self.profiles.first?.label }

    func read() async -> [PronunciationDictionaryProfile] {
        self.reads += 1
        let snapshot = self.profiles
        if self.holdRead {
            self.holdRead = false
            await withCheckedContinuation { self.held = $0 }
        }
        return snapshot
    }

    func replace(_ profiles: [PronunciationDictionaryProfile]) async throws {
        self.replacements += 1
        if self.holdReplace {
            self.holdReplace = false
            await withCheckedContinuation { self.held = $0 }
        }
        if self.rejects { throw FixtureFailure() }
        self.profiles = profiles
    }
}

/// What the restore announced, and which backup each store held at that moment.
private struct Announcement: Equatable {
    var settings: String?
    var history: String?
    var activity: ASRExclusiveActivity?
}

@MainActor
private final class RestoreLog {
    var announcements: [Announcement] = []
    var idleChanges = 0
}

/// A BackupService over in-memory stores and a real ASRService.
@MainActor
private final class BackupFixture {
    let settings: BackupSettingsFixture
    let history: BackupHistoryFixture
    let profiles: ProfileStoreFixture
    let asr: ASRService
    let log: RestoreLog
    let service: BackupService

    init(payload: SettingsBackupPayload) {
        let settings = BackupSettingsFixture(payload: payload, owner: "original")
        let history = BackupHistoryFixture(owner: "original")
        let profiles = ProfileStoreFixture(owner: "original")
        let asr = ASRService()
        let log = RestoreLog()
        self.settings = settings
        self.history = history
        self.profiles = profiles
        self.asr = asr
        self.log = log
        self.service = BackupService(stores: BackupService.Stores(
            settings: settings,
            history: history,
            pronunciationProfiles: { await profiles.read() },
            replacePronunciationProfiles: { try await profiles.replace($0) },
            asr: { asr },
            announceRestore: { asr in
                log.announcements.append(Announcement(settings: settings.owner, history: history.owner, activity: asr.activeExclusiveActivity))
            },
            idleUnloadChanged: { log.idleChanges += 1 }
        ))
    }

    /// Which backup the settings, History and voice profiles each came from.
    var owners: [String?] {
        [self.settings.owner, self.history.owner, self.profiles.owner]
    }

    var isUntouched: Bool {
        self.owners == ["original", "original", "original"] && self.settings.restores == 0 &&
            self.history.writes == 0 && self.profiles.replacements == 0 && self.log.announcements.isEmpty
    }
}

@MainActor
final class BackupServiceConcurrencyTests: XCTestCase {
    private var payload: SettingsBackupPayload?

    override func setUp() async throws {
        try await super.setUp()
        let suiteName = "BackupServiceConcurrencyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName)) // isolation-ok: own suite, removed below
        defer { defaults.removePersistentDomain(forName: suiteName) }
        self.payload = try SettingsStore(defaults: defaults).makeBackupPayload()
    }

    fileprivate static func entry(_ owner: String) -> TranscriptionHistoryEntry {
        TranscriptionHistoryEntry(rawText: owner, processedText: owner, appName: "Fixture", windowTitle: "", wasAIProcessed: false)
    }

    fileprivate static func profile(_ owner: String) -> PronunciationDictionaryProfile {
        PronunciationDictionaryProfile(dictionaryEntryID: UUID(), label: owner, modelKey: "fixture", hiddenSize: 1, enrollments: [])
    }

    private func makeFixture() throws -> BackupFixture {
        try BackupFixture(payload: XCTUnwrap(self.payload))
    }

    private func document(_ owner: String, idle: SettingsStore.PrivateAIIdleUnload? = nil) throws -> AppBackupDocument {
        var settings = try XCTUnwrap(self.payload)
        settings.privateAIIdleUnload = idle
        return AppBackupDocument(
            schemaVersion: .current,
            appVersion: "fixture",
            exportedAt: Date(),
            settings: settings,
            promptProfiles: [SettingsStore.DictationPromptProfile(name: owner, prompt: "")],
            appPromptBindings: [],
            transcriptionHistory: [Self.entry(owner)],
            pronunciationProfiles: [Self.profile(owner)]
        )
    }

    private func owners(of document: AppBackupDocument) -> [String?] {
        [document.promptProfiles.first?.name, document.transcriptionHistory.first?.rawText, document.pronunciationProfiles?.first?.label]
    }

    private func waitUntil(_ reached: () -> Bool) async {
        for _ in 0..<100_000 where !reached() {
            await Task.yield()
        }
        XCTAssertTrue(reached(), "The backup never reached the store")
    }

    private func assertBusy(_ label: String, _ work: () async throws -> Void) async {
        do {
            try await work()
            XCTFail("\(label) should be refused while another backup runs")
        } catch BackupServiceError.operationInProgress {
        } catch {
            XCTFail("\(label) failed with \(error)")
        }
    }

    // Turns red if an import or a second export can start while an export is reading, or the export
    // returns settings, History and voice profiles from different backups.
    func testExportRefusesOverlapAndStaysConsistent() async throws {
        let fixture = try self.makeFixture()
        fixture.profiles.holdRead = true
        let export = Task { try await fixture.service.makeBackupDocument() }
        await self.waitUntil { fixture.profiles.held != nil }

        await self.assertBusy("import") { try await fixture.service.restore(self.document("B")) }
        await self.assertBusy("export") { _ = try await fixture.service.makeBackupDocument() }
        XCTAssertTrue(fixture.isUntouched)
        XCTAssertEqual(fixture.profiles.reads, 1)

        fixture.profiles.held?.resume()
        let snapshot = try await export.value
        XCTAssertEqual(self.owners(of: snapshot), ["original", "original", "original"])

        try await fixture.service.restore(self.document("B"))
        let fresh = try await fixture.service.makeBackupDocument()
        XCTAssertEqual(self.owners(of: fresh), ["B", "B", "B"])
    }

    // Turns red if an import lets dictation or another backup start while it is replacing voice profiles,
    // or keeps the speech engine after it finishes.
    func testImportHoldsTheSpeechEngineUntilItFinishes() async throws {
        let fixture = try self.makeFixture()
        fixture.profiles.holdReplace = true
        let document = try self.document("A")
        let restore = Task { try await fixture.service.restore(document) }
        await self.waitUntil { fixture.profiles.held != nil }

        XCTAssertEqual(fixture.asr.activeExclusiveActivity, .settingsRestore)
        for activity: ASRExclusiveActivity in [.dictation, .fileTranscription, .localAPI, .meeting, .modelMaintenance] {
            XCTAssertThrowsError(try fixture.asr.acquireExclusiveActivity(activity)) { error in
                guard case let ASRActivityError.activityInProgress(owner) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(owner, .settingsRestore)
            }
        }
        await self.assertBusy("export") { _ = try await fixture.service.makeBackupDocument() }
        await self.assertBusy("import") { try await fixture.service.restore(self.document("B")) }
        XCTAssertEqual(fixture.profiles.replacements, 1)
        XCTAssertEqual(fixture.history.loads, 0)

        fixture.profiles.held?.resume()
        try await restore.value
        XCTAssertNil(fixture.asr.activeExclusiveActivity)
        let dictation = try fixture.asr.acquireExclusiveActivity(.dictation)
        fixture.asr.releaseExclusiveActivity(dictation)
        XCTAssertEqual(fixture.owners, ["A", "A", "A"])
    }

    // Turns red if an import starts while dictation owns the speech engine, writes anything before it is
    // refused, takes dictation's lease, or stays refused once dictation ends.
    func testImportIsRefusedWhileDictationRuns() async throws {
        let fixture = try self.makeFixture()
        let dictation = try fixture.asr.acquireExclusiveActivity(.dictation)
        do {
            try await fixture.service.restore(self.document("busy"))
            XCTFail("The import should be refused while dictation runs")
        } catch ASRActivityError.settingsRestoreUnavailable {}
        XCTAssertTrue(fixture.isUntouched)
        XCTAssertEqual(fixture.asr.activeExclusiveActivity, .dictation)

        fixture.asr.releaseExclusiveActivity(dictation)
        try await fixture.service.restore(self.document("retry"))
        XCTAssertEqual(fixture.owners, ["retry", "retry", "retry"])
        XCTAssertNil(fixture.asr.activeExclusiveActivity)
    }

    // Turns red if the restore announcement can see settings and History from different backups,
    // or arrives after the restore has let go of the speech engine.
    func testAnnouncementSeesTheWholeRestoreOnce() async throws {
        let fixture = try self.makeFixture()
        try await fixture.service.restore(self.document("A"))
        XCTAssertEqual(fixture.log.announcements, [Announcement(settings: "A", history: "A", activity: .settingsRestore)])
    }

    // Turns red if cancelling an export while it reads still returns a document, writes anything,
    // or leaves later imports and exports refused.
    func testCancelledExportWritesNothing() async throws {
        let fixture = try self.makeFixture()
        fixture.profiles.holdRead = true
        let export = Task { try await fixture.service.makeBackupDocument() }
        await self.waitUntil { fixture.profiles.held != nil }
        export.cancel()
        fixture.profiles.held?.resume()
        do {
            _ = try await export.value
            XCTFail("The export should be cancelled")
        } catch is CancellationError {}
        XCTAssertTrue(fixture.isUntouched)

        _ = try await fixture.service.makeBackupDocument()
        try await fixture.service.restore(self.document("after"))
        XCTAssertEqual(fixture.owners, ["after", "after", "after"])
    }

    // Turns red if cancelling an import after its voice profile write leaves new profiles with old settings
    // or History, skips the announcement, or keeps the speech engine.
    func testCancellationAfterProfileWriteFinishesTheRestore() async throws {
        let fixture = try self.makeFixture()
        fixture.profiles.holdReplace = true
        let document = try self.document("cancelled")
        let restore = Task { try await fixture.service.restore(document) }
        await self.waitUntil { fixture.profiles.held != nil }
        restore.cancel()
        fixture.profiles.held?.resume()
        try await restore.value

        XCTAssertEqual(fixture.owners, ["cancelled", "cancelled", "cancelled"])
        XCTAssertEqual(fixture.log.announcements.count, 1)
        XCTAssertNil(fixture.asr.activeExclusiveActivity)
    }

    // Turns red if an import or export cancelled before it starts touches any store or leaves the next one refused.
    func testCancellationBeforeStartTouchesNothing() async throws {
        for isRestore in [false, true] {
            let fixture = try self.makeFixture()
            let document = try self.document("unstarted")
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                if isRestore {
                    try await fixture.service.restore(document)
                } else {
                    _ = try await fixture.service.makeBackupDocument()
                }
            }
            do {
                try await task.value
                XCTFail("restore: \(isRestore) should be cancelled")
            } catch is CancellationError {}
            XCTAssertTrue(fixture.isUntouched, "restore: \(isRestore)")
            XCTAssertEqual(fixture.history.loads, 0, "restore: \(isRestore)")
            XCTAssertEqual(fixture.profiles.reads, 0, "restore: \(isRestore)")
            XCTAssertNil(fixture.asr.activeExclusiveActivity, "restore: \(isRestore)")

            try await fixture.service.restore(self.document("retry"))
            XCTAssertEqual(fixture.owners, ["retry", "retry", "retry"], "restore: \(isRestore)")
        }
    }

    // Turns red if a failed voice profile write still restores settings or History, announces, keeps the
    // speech engine, or leaves the next import refused.
    func testProfileWriteFailureChangesNothingElse() async throws {
        let fixture = try self.makeFixture()
        fixture.profiles.rejects = true
        do {
            try await fixture.service.restore(self.document("failed"))
            XCTFail("The import should fail")
        } catch is FixtureFailure {}
        XCTAssertEqual(fixture.owners, ["original", "original", "original"])
        XCTAssertEqual(fixture.settings.restores, 0)
        XCTAssertEqual(fixture.history.writes, 0)
        XCTAssertTrue(fixture.log.announcements.isEmpty)
        XCTAssertNil(fixture.asr.activeExclusiveActivity)

        fixture.profiles.rejects = false
        try await fixture.service.restore(self.document("retry"))
        XCTAssertEqual(fixture.owners, ["retry", "retry", "retry"])
    }

    // Turns red if a backup from an unsupported format reaches the voice profile store, or a History load
    // failure lets an export read voice profiles; either way the next operation must be allowed.
    func testRejectedBackupsAndFailedLoadsTouchNothing() async throws {
        let fixture = try self.makeFixture()
        let current = try self.document("invalid")
        let invalid = AppBackupDocument(
            schemaVersion: BackupFileVersion(major: 99, minor: 0),
            appVersion: current.appVersion,
            exportedAt: current.exportedAt,
            settings: current.settings,
            promptProfiles: current.promptProfiles,
            appPromptBindings: current.appPromptBindings,
            transcriptionHistory: current.transcriptionHistory,
            pronunciationProfiles: current.pronunciationProfiles
        )
        do {
            try await fixture.service.restore(invalid)
            XCTFail("The import should be rejected")
        } catch BackupServiceError.unsupportedSchemaVersion {}
        XCTAssertTrue(fixture.isUntouched)
        XCTAssertNil(fixture.asr.activeExclusiveActivity)

        fixture.history.failsToLoad = true
        do {
            _ = try await fixture.service.makeBackupDocument()
            XCTFail("The export should fail")
        } catch is FixtureFailure {}
        XCTAssertEqual(fixture.profiles.reads, 0)

        fixture.history.failsToLoad = false
        try await fixture.service.restore(self.document("retry"))
        XCTAssertEqual(fixture.owners, ["retry", "retry", "retry"])
    }

    // Turns red if an export waiting for History to load lets another backup start, or reads voice profiles
    // after it was cancelled during the load.
    func testExportHoldsAdmissionWhileHistoryLoads() async throws {
        let fixture = try self.makeFixture()
        fixture.history.holdLoad = true
        let export = Task { try await fixture.service.makeBackupDocument() }
        await self.waitUntil { fixture.history.held != nil }
        await self.assertBusy("import") { try await fixture.service.restore(self.document("blocked")) }
        await self.assertBusy("export") { _ = try await fixture.service.makeBackupDocument() }
        export.cancel()
        fixture.history.held?.resume()
        do {
            _ = try await export.value
            XCTFail("The export should be cancelled")
        } catch is CancellationError {}
        XCTAssertEqual(fixture.profiles.reads, 0)
        _ = try await fixture.service.makeBackupDocument()
    }

    // Turns red if the model unload timer is rescheduled when the backup has no idle setting or the same one,
    // or is not rescheduled when the backup changes it.
    func testIdleUnloadIsRescheduledOnlyWhenTheBackupChangesIt() async throws {
        let cases: [(SettingsStore.PrivateAIIdleUnload?, Int)] = [(nil, 0), (.thirtyMinutes, 0), (.oneHour, 1), (.never, 1)]
        for (idle, expected) in cases {
            let fixture = try self.makeFixture()
            try await fixture.service.restore(self.document("idle", idle: idle))
            XCTAssertEqual(fixture.log.idleChanges, expected, "idle: \(String(describing: idle))")
            XCTAssertEqual(fixture.settings.privateAIIdleUnload, idle ?? .thirtyMinutes, "idle: \(String(describing: idle))")
        }
    }

    // Turns red if a backup made before voice profiles existed leaves newer voice profiles in place.
    func testBackupWithoutVoiceProfilesClearsThem() async throws {
        let fixture = try self.makeFixture()
        let current = try self.document("legacy")
        let legacy = AppBackupDocument(
            schemaVersion: current.schemaVersion,
            appVersion: current.appVersion,
            exportedAt: current.exportedAt,
            settings: current.settings,
            promptProfiles: current.promptProfiles,
            appPromptBindings: current.appPromptBindings,
            transcriptionHistory: current.transcriptionHistory,
            pronunciationProfiles: nil
        )
        try await fixture.service.restore(legacy)
        XCTAssertTrue(fixture.profiles.profiles.isEmpty)
        XCTAssertEqual(fixture.settings.owner, "legacy")
    }
}
