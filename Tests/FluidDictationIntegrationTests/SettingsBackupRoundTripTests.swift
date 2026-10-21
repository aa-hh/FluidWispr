import AppKit
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class SettingsBackupRoundTripTests: XCTestCase {
    func testModernBackupExportsAndRestoresMeetingIdleAndPromptConfiguration() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let profile = self.profile(id: "backup-dictation")
            let meeting = self.meetingDefaults()
            let configurations = self.configurations(profileID: profile.id)
            settings.dictationPromptProfiles = [profile]
            settings.meetingRecordingDefaults = meeting
            settings.privateAIIdleUnload = .oneHour
            settings.dictationPromptConfigurations = configurations
            let payload = settings.makeBackupPayload()
            let encoded = try JSONEncoder().encode(payload)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertNotNil(json["meetingRecordingDefaults"])
            XCTAssertEqual(json["privateAIIdleUnload"] as? Int, 60)
            XCTAssertNotNil(json["dictationPromptConfigurations"])

            settings.meetingRecordingDefaults = .unconfigured
            settings.privateAIIdleUnload = .never
            settings.dictationPromptConfigurations = [:]
            settings.dictationPromptProfiles = []
            try settings.restore(
                from: JSONDecoder().decode(SettingsBackupPayload.self, from: encoded),
                promptProfiles: [profile],
                appPromptBindings: []
            )
            XCTAssertEqual(settings.meetingRecordingDefaults, meeting)
            XCTAssertEqual(settings.privateAIIdleUnload, .oneHour)
            XCTAssertEqual(settings.dictationPromptConfigurations, configurations)
            XCTAssertEqual(settings.dictationPromptShortcutAssignments().count, 3)
            XCTAssertEqual(settings.selectedProviderID, payload.selectedProviderID)
            XCTAssertEqual(settings.primaryDictationShortcuts, payload.primaryDictationShortcuts)
        }
    }

    func testLegacyAbsentFieldsPreserveCurrentPreferences() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let profile = self.profile(id: "legacy-survivor")
            settings.dictationPromptProfiles = [profile]
            let payload = try self.payload(removing: [
                "meetingRecordingDefaults", "privateAIIdleUnload", "dictationPromptConfigurations",
            ])
            let meeting = self.meetingDefaults()
            let configurations = self.configurations(profileID: profile.id)
            settings.meetingRecordingDefaults = meeting
            settings.privateAIIdleUnload = .thirtyMinutes
            settings.dictationPromptConfigurations = configurations
            settings.restore(from: payload, promptProfiles: [profile], appPromptBindings: [])
            XCTAssertEqual(settings.meetingRecordingDefaults, meeting)
            XCTAssertEqual(settings.privateAIIdleUnload, .thirtyMinutes)
            XCTAssertEqual(settings.dictationPromptConfigurations, configurations)
        }
    }

    // Turns red if restore reads the old pronunciationMatchingEnabled field again, or stops restoring pronunciationLearningEnabled.
    func testPronunciationSwitchIgnoresOldFieldAndRestoresNewOne() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            settings.pronunciationMatchingEnabled = true
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings.makeBackupPayload())) as? [String: Any])
            XCTAssertEqual(json["pronunciationLearningEnabled"] as? Bool, true)

            json.removeValue(forKey: "pronunciationLearningEnabled")
            json["pronunciationMatchingEnabled"] = false
            let oldBackup = try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONSerialization.data(withJSONObject: json))
            settings.restore(from: oldBackup)
            XCTAssertTrue(settings.pronunciationMatchingEnabled)

            json["pronunciationLearningEnabled"] = false
            let newBackup = try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONSerialization.data(withJSONObject: json))
            settings.restore(from: newBackup)
            XCTAssertFalse(settings.pronunciationMatchingEnabled)
        }
    }

    // Turns red if TestPreferencesGuard stops being the bundle's principal class, so a run would keep its preference writes.
    func testPreferencesGuardSavedTheRealPreferencesBeforeTestsRan() {
        XCTAssertTrue(TestPreferencesGuard.isWatching)
        XCTAssertTrue(FileManager.default.fileExists(atPath: TestPreferencesGuard.snapshotURL.path))
    }

    func testExplicitEmptyPromptConfigurationsClearPreviousMappings() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            settings.dictationPromptConfigurations = [:]
            let payload = settings.makeBackupPayload()
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
            XCTAssertEqual((json["dictationPromptConfigurations"] as? [String: Any])?.count, 0)
            settings.dictationPromptConfigurations = self.configurations(profileID: "previous")
            settings.restore(from: payload, promptProfiles: [], appPromptBindings: [])
            XCTAssertTrue(settings.dictationPromptConfigurations.isEmpty)
            XCTAssertTrue(settings.dictationPromptShortcutAssignments().isEmpty)
        }
    }

    func testImportedPromptConfigurationsUseRestoredProfilesAndCannotActivateInvalidReferences() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let valid = self.profile(id: "imported")
            let edit = self.profile(id: "edit-only", mode: .edit)
            let shortcut = HotkeyShortcut(keyCode: 2, modifierFlags: [.control, .option])
            let imported: [String: SettingsStore.DictationPromptConfiguration] = [
                "profile:imported": .init(shortcut: shortcut, providerID: "openai", modelName: "imported-model"),
                "profile:missing": .init(shortcut: shortcut, providerID: "openai", modelName: "missing-model"),
                "profile:edit-only": .init(shortcut: shortcut, providerID: "openai", modelName: "edit-model"),
                "unknown": .init(shortcut: shortcut),
                "__default__": .init(shortcut: HotkeyShortcut(keyCode: 2, modifierFlags: []), providerID: "openai", modelName: "default-model"),
                "__privateAI__": .init(shortcut: shortcut, providerID: "apple-intelligence", modelName: "retired-model"),
            ]
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings.makeBackupPayload())) as? [String: Any])
            json["dictationPromptConfigurations"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(imported))
            let payload = try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONSerialization.data(withJSONObject: json))
            settings.dictationPromptProfiles = [self.profile(id: "previous")]
            settings.dictationPromptConfigurations = ["profile:previous": .init(shortcut: shortcut)]
            settings.restore(from: payload, promptProfiles: [valid, edit], appPromptBindings: [])

            XCTAssertEqual(settings.dictationPromptConfigurations["profile:imported"], imported["profile:imported"])
            XCTAssertNil(settings.dictationPromptConfigurations["profile:missing"])
            XCTAssertNil(settings.dictationPromptConfigurations["profile:edit-only"])
            XCTAssertNil(settings.dictationPromptConfigurations["profile:previous"])
            XCTAssertNil(settings.dictationPromptConfigurations["unknown"])
            XCTAssertNil(settings.dictationPromptConfiguration(for: .default).shortcut)
            XCTAssertEqual(settings.dictationPromptConfiguration(for: .default).modelName, "default-model")
            XCTAssertEqual(settings.dictationPromptConfigurations["__privateAI__"], .init(shortcut: shortcut))
            XCTAssertEqual(settings.dictationPromptShortcutAssignments().count, 2)
            XCTAssertEqual(settings.selectedProviderID, payload.selectedProviderID)
            XCTAssertEqual(settings.primaryDictationShortcuts, payload.primaryDictationShortcuts)
        }
    }

    private func payload(removing keys: [String]) throws -> SettingsBackupPayload {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SettingsStore.shared.makeBackupPayload())) as? [String: Any])
        for key in keys {
            json.removeValue(forKey: key)
        }
        return try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func profile(id: String, mode: SettingsStore.PromptMode = .dictate) -> SettingsStore.DictationPromptProfile {
        .init(id: id, name: "Backup fixture", prompt: "Keep these words", mode: mode)
    }

    private func configurations(profileID: String) -> [String: SettingsStore.DictationPromptConfiguration] {
        [
            "__default__": .init(shortcut: HotkeyShortcut(keyCode: 2, modifierFlags: .control), providerID: "openai", modelName: "default-model"),
            "__privateAI__": .init(shortcut: HotkeyShortcut(keyCode: 3, modifierFlags: .control), providerID: "fluid-fixture", modelName: "private-model"),
            "profile:\(profileID)": .init(shortcut: HotkeyShortcut(keyCode: 5, modifierFlags: .control), providerID: "custom:fixture", modelName: "profile-model"),
        ]
    }

    private func meetingDefaults() -> MeetingRecordingDefaults {
        .init(
            isConfigured: true,
            mode: .inRoom,
            applicationBundleIdentifier: "fixture.meeting",
            applicationDisplayName: "Fixture Meeting",
            microphoneCaptureDeviceID: "fixture-capture",
            microphoneCoreAudioUID: "fixture-core-audio",
            microphoneRole: .shared,
            languageCode: "fr"
        )
    }

    private func withSavedDefaults(_ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let original = defaults.persistentDomain(forName: domain)
        defer {
            if let original {
                defaults.setPersistentDomain(original, forName: domain)
            } else {
                defaults.removePersistentDomain(forName: domain)
            }
        }
        try body()
    }
}

/// The test bundle's principal class (INFOPLIST_KEY_NSPrincipalClass). Tests run inside the app and write
/// to its real preferences, so this saves them to a file before the first test and puts them back after the last.
/// A run that crashes leaves the file behind, and the next run restores from it before saving again.
final class TestPreferencesGuard: NSObject, XCTestObservation {
    private(set) static var isWatching = false

    static var snapshotURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("\(domain)-preferences-before-tests.plist")
    }

    private static var domain: String {
        Bundle.main.bundleIdentifier ?? "com.FluidApp.app.debug"
    }

    override init() {
        super.init()
        Self.restoreLeftoverSnapshot()
        let current = UserDefaults.standard.persistentDomain(forName: Self.domain) ?? [:] // isolation-ok
        guard Self.write(current) else { return }
        XCTestObservationCenter.shared.addTestObserver(self)
        Self.isWatching = true
    }

    // Observer callback, not a test. XCTest calls it after the last test, so the restore fails if this is removed.
    func testBundleDidFinish(_ testBundle: Bundle) {
        Self.restoreLeftoverSnapshot()
    }

    private static func restoreLeftoverSnapshot() {
        guard let data = try? Data(contentsOf: snapshotURL),
              let saved = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return }
        UserDefaults.standard.setPersistentDomain(saved, forName: domain) // isolation-ok
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    private static func write(_ preferences: [String: Any]) -> Bool {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0) else {
            return false
        }
        return (try? data.write(to: snapshotURL, options: .atomic)) != nil
    }
}
