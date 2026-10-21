@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class LLMRequestConfigTests: XCTestCase {
    /// A SettingsStore on its own preferences suite, holding one saved provider.
    private func withSettings(_ body: (SettingsStore) throws -> Void) throws {
        let suiteName = "LLMRequestConfigTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName)) // isolation-ok: own suite, removed below
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.savedProviders = [
            SettingsStore.SavedProvider(id: "myserver", name: "My server", baseURL: "http://127.0.0.1:9/v1", models: ["fixture-chat"]),
        ]
        try body(settings)
    }

    // Turns red if Edit Mode stops finding reasoning settings saved under "custom:<id>", or its temperature or address changes.
    func testEditUsesSavedProviderAddressAndReasoningSettings() throws {
        try self.withSettings { settings in
            settings.setReasoningConfig(.init(parameterValue: "high"), forModel: "fixture-chat", provider: "custom:myserver")
            let route = DictationProviderRoute.resolveChat(settings: settings, providerID: "myserver", model: "fixture-chat")
            let config = route.config(for: .edit, messages: [], settings: settings)

            XCTAssertEqual(config.baseURL, "http://127.0.0.1:9/v1")
            XCTAssertEqual(config.model, "fixture-chat")
            XCTAssertEqual(config.extraParameters["reasoning_effort"] as? String, "high")
            XCTAssertEqual(config.temperature, 0.7)
            XCTAssertNil(config.maxTokens)
            XCTAssertFalse(config.streaming)
        }
    }

    // Turns red if Edit Mode's verification stops matching what AI settings saved, or a padded saved address is sent untrimmed.
    func testEditModeSeesAProviderVerifiedInSettings() throws {
        try self.withSettings { settings in
            settings.savedProviders = [
                SettingsStore.SavedProvider(id: "myserver", name: "My server", baseURL: " http://127.0.0.1:9/v1 ", models: ["fixture-chat"]),
            ]
            let fingerprint = try XCTUnwrap(DictationAIPostProcessingGate.providerFingerprint(baseURL: "http://127.0.0.1:9/v1", apiKey: ""))
            settings.verifiedProviderFingerprints = ["custom:myserver": fingerprint]
            let route = DictationProviderRoute.resolveChat(settings: settings, providerID: "myserver", model: "fixture-chat")

            XCTAssertTrue(DictationAIPostProcessingGate.isVerified(route: route, settings: settings))
            XCTAssertEqual(route.config(for: .edit, messages: [], settings: settings).baseURL, "http://127.0.0.1:9/v1")

            settings.savedProviders = [
                SettingsStore.SavedProvider(id: "myserver", name: "My server", baseURL: "http://127.0.0.1:10/v1", models: ["fixture-chat"]),
            ]
            let moved = DictationProviderRoute.resolveChat(settings: settings, providerID: "myserver", model: "fixture-chat")
            XCTAssertFalse(DictationAIPostProcessingGate.isVerified(route: moved, settings: settings))
        }
    }

    // Turns red if Edit Mode, Command Mode and dictation stop agreeing on verification, if a remote provider
    // verified without a key stops counting, or if a remote plain-http address starts counting.
    func testEveryModeAgreesOnVerificationForKeylessAndPlainHTTPProviders() throws {
        try self.withSettings { settings in
            settings.savedProviders = [
                SettingsStore.SavedProvider(id: "gateway", name: "Gateway", baseURL: "https://gateway.test/v1", models: ["fixture-chat"]),
                SettingsStore.SavedProvider(id: "plain", name: "Plain", baseURL: "http://plain.test/v1", models: ["fixture-chat"]),
                SettingsStore.SavedProvider(id: "lan", name: "LAN", baseURL: "http://192.168.1.20:1234/v1", models: ["fixture-chat"]),
            ]
            settings.verifiedProviderFingerprints = [
                "custom:gateway": try XCTUnwrap(ProviderVerification.fingerprint(baseURL: "https://gateway.test/v1", apiKey: "")),
                "custom:plain": try XCTUnwrap(ProviderVerification.fingerprint(baseURL: "http://plain.test/v1", apiKey: "")),
                "custom:lan": try XCTUnwrap(ProviderVerification.fingerprint(baseURL: "http://192.168.1.20:1234/v1", apiKey: "")),
            ]
            for (providerID, expected) in [("gateway", true), ("plain", false), ("lan", true)] {
                let route = DictationProviderRoute.resolveChat(settings: settings, providerID: providerID, model: "fixture-chat")
                XCTAssertEqual(DictationAIPostProcessingGate.isVerified(route: route, settings: settings), expected, providerID)
                XCTAssertEqual(settings.isCommandModeProviderVerified(providerID), expected, providerID)
            }
            // The Add Provider form refuses the same plain http address the modes refuse.
            for (baseURL, accepted) in [("http://plain.test/v1", false), ("http://localhost:1234/v1", true), ("https://gateway.test/v1", true)] {
                let draft = ProviderSetupDraft(name: "Custom", baseURL: baseURL)
                XCTAssertEqual(draft.isValid, accepted, baseURL)
                XCTAssertEqual(draft.needsHTTPS, !accepted, baseURL)
            }
        }
    }

    // Turns red if Command Mode loses its tools, its 0.1 temperature, or the token budget for reasoning models.
    func testCommandSendsToolsAndGivesReasoningModelsATokenBudget() throws {
        try self.withSettings { settings in
            let tool: [String: Any] = ["type": "function"]
            let chat = DictationProviderRoute.resolveChat(settings: settings, providerID: "myserver", model: "fixture-chat")
                .config(for: .command, messages: [], settings: settings, streaming: true, tools: [tool])
            XCTAssertEqual(chat.temperature, 0.1)
            XCTAssertNil(chat.maxTokens)
            XCTAssertEqual(chat.tools.count, 1)
            XCTAssertTrue(chat.streaming)

            let reasoning = DictationProviderRoute.resolveChat(settings: settings, providerID: "openai", model: "o3")
                .config(for: .command, messages: [], settings: settings)
            XCTAssertEqual(reasoning.baseURL, "https://api.openai.com/v1")
            XCTAssertNil(reasoning.temperature, "Reasoning models reject temperature")
            XCTAssertEqual(reasoning.maxTokens, 32_000)
            XCTAssertNotNil(reasoning.extraParameters["reasoning_effort"])
        }
    }

    // Turns red if a provider that is neither saved nor built in gets an address, or a raw-id reasoning setting is used.
    func testUnknownProviderGetsNoAddressAndRawIDSettingsAreIgnored() throws {
        try self.withSettings { settings in
            settings.setReasoningConfig(.init(parameterValue: "high"), forModel: "fixture-chat", provider: "other")
            let config = DictationProviderRoute.resolveChat(settings: settings, providerID: "other", model: "fixture-chat")
                .config(for: .edit, messages: [], settings: settings)
            XCTAssertEqual(config.baseURL, "")
            XCTAssertTrue(config.extraParameters.isEmpty)
        }
    }

    // Turns red if dictation cleanup starts sending a token budget or changes its 0.2 temperature.
    func testDictationCleanupKeepsItsTemperatureAndNoTokenBudget() throws {
        try self.withSettings { settings in
            let cleanup = DictationProviderRoute.resolveChat(settings: settings, providerID: "openai", model: "o3")
                .config(for: .dictationCleanup, messages: [], settings: settings, benchmarkID: "fixture")
            XCTAssertNil(cleanup.maxTokens)
            XCTAssertEqual(cleanup.benchmarkID, "fixture")

            let plain = DictationProviderRoute.resolveChat(settings: settings, providerID: "myserver", model: "fixture-chat")
                .config(for: .dictationCleanup, messages: [], settings: settings)
            XCTAssertEqual(plain.temperature, 0.2)
        }
    }

    // Turns red if meeting summaries stop sending enable_thinking as a Bool or lose the reasoning-model token budget.
    func testMeetingSummaryMapsThinkingSwitchToBool() {
        let config = DictationProviderRoute.config(
            for: .meetingSummary,
            messages: [],
            target: LLMRequestTarget(
                model: "fixture-chat",
                baseURL: "http://127.0.0.1:9/v1",
                apiKey: "",
                reasoning: .init(parameterName: "enable_thinking", parameterValue: "true"),
                supportsTemperature: true,
                isReasoningModel: true
            )
        )
        XCTAssertEqual(config.extraParameters["enable_thinking"] as? Bool, true)
        XCTAssertEqual(config.temperature, 0.2)
        XCTAssertEqual(config.maxTokens, 32_000)
    }
}
