@testable import FluidVoice_Debug
import XCTest

@MainActor
final class DictationSettingsPolicyTests: XCTestCase {
    private func resolve(
        _ selection: SettingsStore.DictationPromptSelection,
        _ global: String,
        _ provider: String = "",
        _ model: String = ""
    ) -> String {
        DictationDefaultProvider.providerID(
            selection: selection,
            configuration: .init(providerID: provider, modelName: model),
            selectedProviderID: global,
            privateProviderID: "fluid-1"
        )
    }

    // Turns red if the dictation provider stops following the selected prompt, the
    // per-prompt override, or the Private AI provider.
    func testDefaultProviderFollowsSelectionAndOverride() {
        XCTAssertEqual(self.resolve(.off, "openai", "openrouter", "model"), "")
        XCTAssertEqual(self.resolve(.privateAI, "openai"), "fluid-1")
        XCTAssertEqual(self.resolve(.default, "openai"), "openai")
        XCTAssertEqual(self.resolve(.default, "openai", " openrouter ", " model "), "openrouter")
        XCTAssertEqual(self.resolve(.profile("style"), "openai", "custom-provider", "model"), "custom-provider")
        XCTAssertEqual(self.resolve(.default, "fluid-1"), "fluid-1")
        XCTAssertEqual(self.resolve(.profile("style"), "fluid-1"), "")
        XCTAssertEqual(self.resolve(.default, "fluid-1", "openai", ""), "")
        XCTAssertEqual(self.resolve(.default, "openai", "openrouter", ""), "openai")
        XCTAssertEqual(self.resolve(.default, "openai", "", "model"), "openai")
    }

    // Turns red if a missing key, missing model or failed check stops being reported, or
    // the optional verification starts blocking a configured provider.
    func testProviderSetupIssue() {
        XCTAssertEqual(DictationDefaultProvider.setupIssue(requiresAPIKey: true, hasAPIKey: false, hasModel: true, isVerified: true, verificationFailed: false), "API key missing")
        XCTAssertNil(DictationDefaultProvider.setupIssue(requiresAPIKey: false, hasAPIKey: false, hasModel: true, isVerified: true, verificationFailed: false))
        XCTAssertEqual(DictationDefaultProvider.setupIssue(requiresAPIKey: true, hasAPIKey: true, hasModel: false, isVerified: false, verificationFailed: false), "Choose a model")
        XCTAssertNil(
            DictationDefaultProvider.setupIssue(requiresAPIKey: true, hasAPIKey: true, hasModel: true, isVerified: false, verificationFailed: false),
            "Optional verification must not block a configured provider"
        )
        XCTAssertEqual(DictationDefaultProvider.setupIssue(requiresAPIKey: true, hasAPIKey: true, hasModel: true, isVerified: false, verificationFailed: true), "Verification failed")
    }

    // Turns red if a saved default prompt is not recomposed onto the current base prompt
    // exactly once, or custom and edit prompts are rewritten.
    func testSavedDefaultPromptsMigrateToCurrentBase() {
        let legacy = SettingsStore.legacyBaseDictationPromptText()
        let current = SettingsStore.baseDictationPromptText()
        let body = "Keep my terminology."
        XCTAssertEqual(SettingsStore.stripBasePrompt(for: .dictate, from: legacy + "\n\n" + body), body, "Saved old default prefix is removed before recomposition")
        XCTAssertEqual(SettingsStore.stripBasePrompt(for: .dictate, from: current + "\n\n" + body), body, "Current default prefix is removed before recomposition")
        XCTAssertEqual(SettingsStore.stripBasePrompt(for: .dictate, from: legacy.uppercased() + "\n\n" + body), body, "Case-insensitive legacy recognition remains compatible")
        XCTAssertEqual(SettingsStore.stripBasePrompt(for: .dictate, from: body), body, "Unrecognized authored text is unchanged")
        XCTAssertEqual(SettingsStore.stripBasePrompt(for: .dictate, from: body + "\n" + legacy), body + "\n" + legacy, "Only a prefix is removed")
        XCTAssertEqual(SettingsStore.stripBasePrompt(for: .edit, from: legacy), legacy, "Dictation migration cannot strip an edit prompt")
        let recomposed = SettingsStore.combineBasePrompt(for: .dictate, with: SettingsStore.stripBasePrompt(for: .dictate, from: legacy + "\n\n" + body))
        XCTAssertEqual(recomposed, current + "\n\n" + body, "Saved default gets one current base and its original instructions")
        XCTAssertEqual(SettingsStore.combineBasePrompt(for: .dictate, with: current + "\n\n" + body), current + "\n\n" + body, "Current prefix is never duplicated")
        let custom = legacy + "\n\nTranslate to French.  "
        XCTAssertEqual(SettingsStore.customPromptBody(custom, mode: .dictate), custom, "Explicit custom prompts retain their exact old wording and whitespace")
        XCTAssertTrue(SettingsStore.customPromptBody("", mode: .dictate).isEmpty, "Explicit blank custom prompt stays blank")
    }

    // Turns red if the default prompt stops using minimal edits, or its wording and the
    // request disagree about where the transcript is.
    func testDefaultPromptMatchesRequestShape() {
        let current = SettingsStore.baseDictationPromptText()
        let template = current + "\n\nClean this: ${transcript}"
        let request = DictationPromptRequest(promptText: template, transcript: "At present.")
        XCTAssertTrue(request.systemPrompt.isEmpty)
        XCTAssertEqual(request.userContent, current + "\n\nClean this: At present.", "Default templates keep the single-user contract")
        XCTAssertFalse(current.contains("JSON field"), "Shared base must not claim an envelope that explicit templates do not have")
        let defaultPrompt = SettingsStore.combineBasePrompt(for: .dictate, with: SettingsStore.defaultDictationPromptBodyText())
        XCTAssertTrue(defaultPrompt.hasPrefix("Make the smallest edits needed"), "Default cleanup uses minimal edits")
        let defaultRequest = DictationPromptRequest(promptText: defaultPrompt, transcript: "um can you help me")
        XCTAssertEqual(defaultRequest.systemPrompt, defaultPrompt, "Default instructions stay in the system message")
        XCTAssertEqual(defaultRequest.userContent, "{\"transcript\":\"um can you help me\"}", "Default transcript matches the JSON envelope described in its body")
    }

    // Turns red if text goes to the wrong app after the user switches apps, fields or
    // overlays during dictation, or a missing target gets a made-up process ID.
    func testDictationTargetPolicy() {
        struct Case {
            let name: String
            let enabled: Bool
            let focused: Int32?
            let original: Int32?
            let stillFocused: Bool
            let expectedPID: Int32?
            let restores: Bool
        }
        let cases: [Case] = [
            .init(name: "off follows app B", enabled: false, focused: 200, original: 100, stillFocused: false, expectedPID: 200, restores: false),
            .init(name: "on restores app A", enabled: true, focused: 200, original: 100, stillFocused: false, expectedPID: 100, restores: true),
            .init(name: "off follows another field in A", enabled: false, focused: 100, original: 100, stillFocused: false, expectedPID: 100, restores: false),
            .init(name: "on restores original field in A", enabled: true, focused: 100, original: 100, stillFocused: false, expectedPID: 100, restores: true),
            .init(name: "already focused needs no restore", enabled: true, focused: 100, original: 100, stillFocused: true, expectedPID: 100, restores: false),
            .init(name: "off works without recording context", enabled: false, focused: 200, original: nil, stillFocused: false, expectedPID: 200, restores: false),
            .init(name: "overlay recovers saved target", enabled: false, focused: 999, original: 100, stillFocused: false, expectedPID: 100, restores: true),
            .init(name: "unknown focus recovers saved target", enabled: false, focused: nil, original: 100, stillFocused: false, expectedPID: 100, restores: true),
            .init(name: "invalid focus is not a destination", enabled: false, focused: 0, original: 100, stillFocused: false, expectedPID: 100, restores: true),
            .init(name: "missing target does not invent a PID", enabled: true, focused: nil, original: nil, stillFocused: false, expectedPID: nil, restores: true),
        ]
        for test in cases {
            let result = DictationTargetPolicy.resolve(
                returnToStartingField: test.enabled,
                focusedPID: test.focused,
                ownPID: 999,
                originalPID: test.original,
                originalFieldIsFocused: test.stillFocused
            )
            XCTAssertEqual(result.pid, test.expectedPID, test.name)
            XCTAssertEqual(result.shouldRestoreOriginalFocus, test.restores, test.name)
        }
    }

    // Turns red if a per-app model choice leaks to another app, another slot, or survives
    // leaving and re-entering the app.
    func testForegroundAppOverride() {
        var state = ForegroundAppOverride<String>()
        XCTAssertTrue(state.activate("editor"))
        XCTAssertNil(state.choice(slot: "primary", appID: "editor"))
        state.select("smart-mini", slot: "primary", appID: "editor")
        XCTAssertFalse(state.activate("editor"))
        XCTAssertFalse(state.activate(nil))
        XCTAssertFalse(state.activate(""))
        XCTAssertEqual(state.choice(slot: "primary", appID: "editor"), "smart-mini")
        XCTAssertNil(state.choice(slot: "secondary", appID: "editor"))
        state.select("basic", slot: "secondary", appID: "editor")
        XCTAssertEqual(state.choice(slot: "primary", appID: "editor"), "smart-mini")
        state.select("wrong-app", slot: "primary", appID: "browser")
        XCTAssertEqual(state.choice(slot: "primary", appID: "editor"), "smart-mini")
        XCTAssertNil(state.choice(slot: "primary", appID: "browser"))
        XCTAssertTrue(state.activate("browser"))
        XCTAssertNil(state.choice(slot: "primary", appID: "editor"))
        XCTAssertTrue(state.activate("editor"))
        XCTAssertNil(state.choice(slot: "primary", appID: "editor"))
        XCTAssertNil(state.choice(slot: "secondary", appID: "editor"))
        for _ in 0..<1000 {
            state.select("basic", slot: "primary", appID: "editor")
            state.activate("browser")
            state.activate("editor")
            XCTAssertNil(state.choice(slot: "primary", appID: "editor"))
        }
    }

    // Turns red if a saved check leaks across model, key, endpoint or provider, or the history stops being bounded.
    func testProviderModelVerificationStore() throws {
        let suite = "fluidvoice.model-verification-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)) // isolation-ok: throwaway suite
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderModelVerificationStore(defaults: defaults)
        func identity(_ model: String, key: String = "secret", endpoint: String = "https://example.com/v1", provider: String = "openrouter") -> String {
            ProviderModelVerificationStore.identity(providerID: provider, baseURL: endpoint, apiKey: key, model: model)
        }
        let first = identity("model-a")
        let second = identity("model-b")
        XCTAssertFalse(store.contains(first))
        store.recordSuccess(first)
        XCTAssertTrue(store.contains(first))
        XCTAssertFalse(store.contains(second), "Changing models must not reuse another model's check")
        store.recordSuccess(second)
        XCTAssertTrue(store.contains(first) && store.contains(second))
        let reloaded = ProviderModelVerificationStore(defaults: defaults)
        XCTAssertTrue(reloaded.contains(first) && reloaded.contains(second), "Success must survive relaunch")
        XCTAssertFalse(store.contains(identity("model-a", key: "changed")))
        XCTAssertFalse(store.contains(identity("model-a", endpoint: "https://other.example/v1")))
        XCTAssertFalse(store.contains(identity("model-a", provider: "other-provider")))
        XCTAssertEqual(identity(" model-a "), first)
        store.remove(first)
        XCTAssertFalse(store.contains(first))
        XCTAssertTrue(store.contains(second), "A failed recheck affects only its own model")
        for index in 0..<300 {
            store.recordSuccess(identity("model-\(index)"), now: Date(timeIntervalSince1970: Double(index)))
        }
        let saved = try XCTUnwrap(defaults.dictionary(forKey: ProviderModelVerificationStore.defaultsKey))
        XCTAssertEqual(saved.count, ProviderModelVerificationStore.maximumEntries)
        XCTAssertTrue(saved.keys.allSatisfy { $0.count == 64 && !$0.contains("secret") })
        XCTAssertFalse(store.contains(identity("model-0")))
        XCTAssertTrue(store.contains(identity("model-299")))
        defaults.set(["bad": Double.nan], forKey: ProviderModelVerificationStore.defaultsKey)
        XCTAssertFalse(ProviderModelVerificationStore(defaults: defaults).contains(first))
    }

    // Turns red if Reset all settings leaves a changed setting in place, or wipes the dictionary
    // words or onboarding progress it promises to keep.
    func testResetAllSettingsKeepsDictionaryAndOnboarding() throws {
        let suite = "DictationSettingsPolicyTests.reset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)) // isolation-ok: throwaway suite
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let word = SettingsStore.CustomDictionaryEntry(triggers: ["fluid whisper"], replacement: "FluidWispr")
        settings.userTypingWPM = 95
        settings.customDictionaryEntries = [word]
        settings.onboardingCompleted = false

        settings.resetAllSettings()

        XCTAssertEqual(settings.userTypingWPM, 40)
        XCTAssertEqual(settings.customDictionaryEntries.map(\.id), [word.id])
        XCTAssertEqual(settings.customDictionaryEntries.first?.replacement, "FluidWispr")
        XCTAssertFalse(settings.onboardingCompleted)
    }

    // Turns red if one of these keys drops out of SettingsStore.Keys.all, so Reset all settings leaves it in place.
    func testResetAllSettingsRemovesOverlayAndSharingKeys() throws {
        let suite = "DictationSettingsPolicyTests.reset-keys.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)) // isolation-ok: throwaway suite
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let keys = [
            "RecordingPillLiveWords", "OverlayTint", "OverlayHighlight", "OverlayEdgeLightEnabled",
            "OverlayClosingAnimationEnabled", "FluidServeOtherAgentsShared", "IntendedDockVisibility",
        ]
        for key in keys {
            defaults.set("changed", forKey: key)
        }

        settings.resetAllSettings()

        XCTAssertEqual(keys.filter { defaults.object(forKey: $0) != nil }, [])
    }

    // Turns red if migrateLegacyDictationShortcutsIfNeeded stops copying a Toggle or Automatic
    // shortcut list into press-to-talk, overwrites a saved press-to-talk list, or leaves the old keys behind.
    func testLegacyToggleShortcutsMoveToPressToTalk() throws {
        let suite = "DictationSettingsPolicyTests.legacy-toggle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)) // isolation-ok: throwaway suite
        defer { defaults.removePersistentDomain(forName: suite) }
        let f5 = HotkeyShortcut(keyCode: 96, modifierFlags: [])
        let f6 = HotkeyShortcut(keyCode: 97, modifierFlags: [])
        defaults.set(try JSONEncoder().encode([f5]), forKey: "PrimaryDictationShortcuts")
        defaults.set(try JSONEncoder().encode(f6), forKey: "HotkeyShortcutKey")
        defaults.set("automatic", forKey: "HotkeyMode")
        defaults.set(false, forKey: "PressAndHoldMode")

        let settings = SettingsStore(defaults: defaults)

        XCTAssertEqual(settings.primaryDictationShortcuts, [f5])
        XCTAssertEqual(settings.holdToTalkShortcuts, [])
        XCTAssertFalse(settings.holdToTalkEnabled)
        XCTAssertTrue(settings.pressToTalkEnabled)
        for key in ["PrimaryDictationShortcuts", "HotkeyShortcutKey", "HotkeyMode", "PressAndHoldMode"] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }

        settings.primaryDictationShortcuts = [f6]
        defaults.set(try JSONEncoder().encode([f5]), forKey: "PrimaryDictationShortcuts")
        XCTAssertEqual(SettingsStore(defaults: defaults).primaryDictationShortcuts, [f6])
    }

    // Turns red if migrateLegacyDictationShortcutsIfNeeded stops moving an old Hold-mode shortcut
    // into hold-to-talk with hold-to-talk turned on and press-to-talk turned off, or changes the default
    // press-to-talk shortcut.
    func testLegacyHoldModeShortcutMovesToHoldToTalk() throws {
        let suite = "DictationSettingsPolicyTests.legacy-hold.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)) // isolation-ok: throwaway suite
        defer { defaults.removePersistentDomain(forName: suite) }
        let f6 = HotkeyShortcut(keyCode: 97, modifierFlags: [])
        defaults.set(try JSONEncoder().encode(f6), forKey: "HotkeyShortcutKey")
        defaults.set(true, forKey: "PressAndHoldMode")

        let settings = SettingsStore(defaults: defaults)

        XCTAssertEqual(settings.holdToTalkShortcuts, [f6])
        XCTAssertTrue(settings.holdToTalkEnabled)
        XCTAssertFalse(settings.pressToTalkEnabled)
        XCTAssertEqual(settings.primaryDictationShortcuts, [HotkeyShortcut(keyCode: 61, modifierFlags: [])])
        XCTAssertNil(defaults.object(forKey: "HotkeyShortcutKey"))
        XCTAssertNil(defaults.object(forKey: "PressAndHoldMode"))
    }

    // Turns red if OllamaService.status() stops reading the model list from /api/tags or
    // reports the wrong state when the cleanup model is present or absent.
    func testOllamaStatusReadsModelListFromTags() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaTagsURLProtocol.self]
        let service = OllamaService(session: URLSession(configuration: config))

        OllamaTagsURLProtocol.body = #"{"models":[{"name":"llama3:8b"}]}"#
        let missing = await service.status()
        XCTAssertEqual(missing, .modelMissing)

        OllamaTagsURLProtocol.body = #"{"models":[{"name":"\#(OllamaService.modelName)"}]}"#
        let ready = await service.status()
        XCTAssertEqual(ready, .ready)
    }

    // Turns red if CerebrasKeyCheck.verify stops mapping a 401 from the provider to .rejected.
    func testCerebrasKeyCheckMapsAuthFailureToRejected() async {
        let result = await CerebrasKeyCheck.verify(key: "bad-key") { _, _, _ in
            throw ModelRepository.FetchError.httpError(statusCode: 401, details: "Unauthorized")
        }
        XCTAssertEqual(result, .rejected)
    }
}

private final class OllamaTagsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = ""

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
