@testable import FluidVoice_Debug
import XCTest

@MainActor
final class PromptResolverTests: XCTestCase {
    private struct FakeSettings: PromptResolverSettings {
        var dictationPromptProfiles: [SettingsStore.DictationPromptProfile] = []
        var isEditPromptOff = false
        var selection: SettingsStore.DictationPromptSelection = .default
        var selectedIDs: [SettingsStore.PromptMode: String] = [:]
        var routingScope: SettingsStore.PromptRoutingScope = .allApps
        var bindings: [SettingsStore.AppPromptBinding] = []
        var overrides: [SettingsStore.PromptMode: String] = [:]

        func dictationPromptSelection(for slot: SettingsStore.DictationShortcutSlot) -> SettingsStore.DictationPromptSelection {
            self.selection
        }

        func selectedPromptID(for mode: SettingsStore.PromptMode) -> String? {
            self.selectedIDs[mode.normalized]
        }

        func promptRoutingScope(for mode: SettingsStore.PromptMode) -> SettingsStore.PromptRoutingScope {
            self.routingScope
        }

        func appPromptBinding(for mode: SettingsStore.PromptMode, appBundleID: String?) -> SettingsStore.AppPromptBinding? {
            self.bindings.first { $0.mode == mode.normalized && $0.appBundleID == appBundleID }
        }

        func defaultPromptOverride(for mode: SettingsStore.PromptMode) -> String? {
            self.overrides[mode.normalized]
        }
    }

    private func resolver(
        _ settings: FakeSettings,
        manual: SettingsStore.DictationPromptSelection? = nil
    ) -> PromptResolver {
        PromptResolver(settings: settings, manualChoice: { _, _ in manual })
    }

    private let mailProfile = SettingsStore.DictationPromptProfile(id: "mail", name: "Mail", prompt: "Write it as an email.")
    private let notesProfile = SettingsStore.DictationPromptProfile(id: "notes", name: "Notes", prompt: "Keep it short.")

    // Turns red if an app's bound prompt stops replacing the default selection for that app, or leaks into other apps.
    func testAppBindingReplacesTheDefaultOnlyInItsApp() {
        var settings = FakeSettings()
        settings.dictationPromptProfiles = [self.mailProfile]
        settings.bindings = [SettingsStore.AppPromptBinding(mode: .dictate, appBundleID: "com.apple.mail", appName: "Mail", promptID: "mail")]
        let resolver = self.resolver(settings)

        XCTAssertEqual(resolver.resolvedDictationPromptSelection(for: .primary, appBundleID: "com.apple.mail"), .profile("mail"))
        XCTAssertEqual(resolver.effectiveDictationSystemPrompt(for: .primary, appBundleID: "com.apple.mail"), "Write it as an email.")
        XCTAssertEqual(resolver.dictationPromptDisplayName(for: .primary, appBundleID: "com.apple.mail"), "Mail")
        XCTAssertEqual(resolver.resolvedDictationPromptSelection(for: .primary, appBundleID: "com.apple.notes"), .default)
        XCTAssertEqual(
            resolver.effectiveDictationSystemPrompt(for: .primary, appBundleID: "com.apple.notes"),
            SettingsStore.defaultSystemPromptText(for: .dictate)
        )
    }

    // Turns red if a prompt picked from the overlay for an app stops winning over the stored choice, or Off stops clearing the body.
    func testSessionChoiceWinsAndOffClearsTheBody() {
        var settings = FakeSettings()
        settings.dictationPromptProfiles = [self.mailProfile, self.notesProfile]
        settings.selection = .profile("mail")

        let picked = self.resolver(settings, manual: .profile("notes"))
        XCTAssertEqual(picked.effectiveDictationPromptBody(for: .primary, appBundleID: "com.apple.mail"), "Keep it short.")

        let off = self.resolver(settings, manual: .off)
        XCTAssertEqual(off.effectiveDictationPromptBody(for: .primary, appBundleID: nil), "")
        XCTAssertEqual(off.effectiveDictationSystemPrompt(for: .primary, appBundleID: nil), "")

        settings.selection = .off
        let storedOff = self.resolver(settings)
        XCTAssertEqual(storedOff.effectiveDictationPromptBody(for: .primary, appBundleID: nil), "")
        XCTAssertEqual(storedOff.dictationPromptDisplayName(for: .primary, appBundleID: nil), "Basic")
    }

    // Turns red if Edit with its prompt switched off picks up the user's default override instead of the built-in prompt.
    func testEditPromptOffIgnoresTheDefaultOverride() {
        var settings = FakeSettings()
        settings.overrides = [.edit: "Make it formal."]
        XCTAssertEqual(self.resolver(settings).promptResolution(for: .edit).source, .defaultOverride)

        settings.isEditPromptOff = true
        let resolution = self.resolver(settings).promptResolution(for: .edit)
        XCTAssertEqual(resolution.source, .builtInDefault)
        XCTAssertEqual(resolution.systemPrompt, SettingsStore.defaultSystemPromptText(for: .edit))
    }
}
