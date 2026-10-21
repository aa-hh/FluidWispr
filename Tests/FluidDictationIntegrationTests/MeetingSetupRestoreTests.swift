@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class MeetingSetupRestoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults?
    private var settings: SettingsStore?

    override func setUp() async throws {
        try await super.setUp()
        self.suiteName = "MeetingSetupRestoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: self.suiteName)) // isolation-ok: own suite, removed in tearDown
        self.defaults = defaults
        self.settings = SettingsStore(defaults: defaults)
        try self.restoreDefaults(language: "en", mode: .onlineCall)
    }

    override func tearDown() async throws {
        self.defaults?.removePersistentDomain(forName: self.suiteName)
        self.defaults = nil
        self.settings = nil
        try await super.tearDown()
    }

    /// Writes what a backup import would leave in settings.
    private func restoreDefaults(language: String?, mode: MeetingCaptureMode) throws {
        var defaults = MeetingRecordingDefaults.unconfigured
        defaults.languageCode = language
        defaults.mode = mode
        let settings = try XCTUnwrap(self.settings)
        settings.meetingRecordingDefaults = defaults
    }

    private func draft() throws -> MeetingTranscriptionSetupDraft {
        try MeetingTranscriptionSetupDraft(settings: XCTUnwrap(self.settings))
    }

    private func take(
        _ restore: inout MeetingSetupRestore,
        current: MeetingTranscriptionSetupDraft,
        activity: MeetingSetupActivity = MeetingSetupActivity()
    ) throws -> MeetingTranscriptionSetupDraft? {
        try restore.take(current: current, activity: activity, settings: XCTUnwrap(self.settings))
    }

    // Turns red if the meeting setup stops picking up a restored backup's language and mode once the page is idle,
    // or applies the same restore twice.
    func testIdleRestoreUsesTheNewSettingsOnce() throws {
        let current = try self.draft()
        try self.restoreDefaults(language: "fr", mode: .inRoom)
        XCTAssertEqual(current.languageCode, "en", "The draft is a copy, so only the restore can update it")

        var restore = MeetingSetupRestore()
        restore.request()
        let restored = try XCTUnwrap(self.take(&restore, current: current))
        XCTAssertEqual(restored.languageCode, "fr")
        XCTAssertEqual(restored.mode, .inRoom)
        XCTAssertEqual(restored.title, "In-room meeting")
        XCTAssertFalse(restore.isPending)
        XCTAssertNil(try self.take(&restore, current: restored))
    }

    // Turns red if a restore reaches the setup while a meeting runs, starts, stops, retries, loads sources,
    // or has its settings sheet open, or is lost instead of waiting for that to end.
    func testBusyPageWaitsThenTakesTheNewestRestore() throws {
        let busy: [(String, MeetingSetupActivity)] = [
            ("capturing", MeetingSetupActivity(captureIsQuiescent: false)),
            ("starting", MeetingSetupActivity(isStarting: true)),
            ("stopping", MeetingSetupActivity(isStopping: true)),
            ("retrying", MeetingSetupActivity(isRetrying: true)),
            ("loading sources", MeetingSetupActivity(isRefreshingSources: true)),
            ("settings open", MeetingSetupActivity(isShowingSettings: true)),
        ]
        for (label, activity) in busy {
            try self.restoreDefaults(language: "en", mode: .onlineCall)
            let current = try self.draft()
            var restore = MeetingSetupRestore()
            try self.restoreDefaults(language: "fr", mode: .inRoom)
            restore.request()
            XCTAssertNil(try self.take(&restore, current: current, activity: activity), label)
            XCTAssertTrue(restore.isPending, label)

            try self.restoreDefaults(language: "de", mode: .onlineCall)
            restore.request()
            let restored = try XCTUnwrap(self.take(&restore, current: current), label)
            XCTAssertEqual(restored.languageCode, "de", label)
            XCTAssertEqual(restored.mode, .onlineCall, label)
            XCTAssertFalse(restore.isPending, label)
        }
    }

    // Turns red if a restore replaces a meeting title the user typed, or keeps an automatic title from the old mode.
    func testRestoreKeepsOnlyATypedTitle() throws {
        var typed = try self.draft()
        typed.title = "Weekly planning"
        typed.titleWasEdited = true
        let automatic = try self.draft()
        try self.restoreDefaults(language: "en", mode: .inRoom)

        var restore = MeetingSetupRestore()
        restore.request()
        let keptTitle = try XCTUnwrap(self.take(&restore, current: typed))
        XCTAssertEqual(keptTitle.title, "Weekly planning")
        XCTAssertTrue(keptTitle.titleWasEdited)

        restore.request()
        let newTitle = try XCTUnwrap(self.take(&restore, current: automatic))
        XCTAssertEqual(newTitle.title, "In-room meeting")
        XCTAssertFalse(newTitle.titleWasEdited)
    }

    // Turns red if a backup from before meeting languages existed leaves the setup with no language instead of English.
    func testBackupWithoutLanguageFallsBackToEnglish() throws {
        try self.restoreDefaults(language: nil, mode: .onlineCall)
        var restore = MeetingSetupRestore()
        restore.request()
        let restored = try XCTUnwrap(self.take(&restore, current: self.draft()))
        XCTAssertEqual(restored.languageCode, "en")
    }
}
