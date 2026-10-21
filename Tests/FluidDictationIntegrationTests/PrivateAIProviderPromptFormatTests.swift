@testable import FluidVoice_Debug
import XCTest

@MainActor
final class PrivateAIProviderPromptFormatTests: XCTestCase {
    func testProviderTaskDefaultKeepsDictationAndHidesOtherModes() {
        let provider = TaskDefaultPrivateAIProvider()

        XCTAssertEqual(provider.modelIDs(for: .dictation), ["dictation-model"])
        XCTAssertEqual(provider.modelIDs(for: .edit), [])
        XCTAssertEqual(provider.modelIDs(for: .command), [])
    }

    func testTaskFilteringDoesNotChangeRemoteProviderDefaults() {
        let repository = ModelRepository.shared

        XCTAssertEqual(
            repository.defaultModels(for: "openai", task: .edit),
            repository.defaultModels(for: "openai")
        )
        XCTAssertEqual(
            repository.defaultModels(for: "anthropic", task: .command),
            repository.defaultModels(for: "anthropic")
        )
    }

    func testEligibleTaskModelPreservesAValidNonFirstSelection() {
        let models = ["edit-model-a", "edit-model-b"]

        XCTAssertEqual(
            ModelRepository.eligibleModel(preferred: "edit-model-b", from: models),
            "edit-model-b"
        )
        XCTAssertEqual(
            ModelRepository.eligibleModel(preferred: "dictation-only", from: models),
            "edit-model-a"
        )
    }

    func testModelScopedVerificationIsIndependentFromProviderSelection() {
        self.withRestoredFingerprints { settings in
            settings.verifiedProviderFingerprints = ["private": "model-a-fingerprint"]
            settings.verifiedPrivateAIModelFingerprints = [:]

            XCTAssertFalse(
                PrivateAIProviderPromptFormat.hasStoredVerification(
                    for: "model-b",
                    providerKey: "private",
                    expectedFingerprint: "model-b-fingerprint",
                    settings: settings
                )
            )

            settings.verifiedPrivateAIModelFingerprints = ["model-b": "model-b-fingerprint"]

            XCTAssertTrue(
                PrivateAIProviderPromptFormat.hasStoredVerification(
                    for: "model-b",
                    providerKey: "private",
                    expectedFingerprint: "model-b-fingerprint",
                    settings: settings
                )
            )
            XCTAssertFalse(
                PrivateAIProviderPromptFormat.hasStoredVerification(
                    for: "model-b",
                    providerKey: "private",
                    expectedFingerprint: "stale-fingerprint",
                    settings: settings
                )
            )
        }
    }

    func testLegacyProviderFingerprintRemainsValid() {
        self.withRestoredFingerprints { settings in
            settings.verifiedPrivateAIModelFingerprints = [:]
            settings.verifiedProviderFingerprints = ["private": "legacy-fingerprint"]

            XCTAssertTrue(
                PrivateAIProviderPromptFormat.hasStoredVerification(
                    for: "model-a",
                    providerKey: "private",
                    expectedFingerprint: "legacy-fingerprint",
                    settings: settings
                )
            )
        }
    }

    private func withRestoredFingerprints(_ body: (SettingsStore) -> Void) {
        let settings = SettingsStore.shared
        let providerFingerprints = settings.verifiedProviderFingerprints
        let modelFingerprints = settings.verifiedPrivateAIModelFingerprints
        defer {
            settings.verifiedProviderFingerprints = providerFingerprints
            settings.verifiedPrivateAIModelFingerprints = modelFingerprints
        }
        body(settings)
    }
}

private struct TaskDefaultPrivateAIProvider: PrivateAIProviderFeatureProviding {
    let isAvailable = true
    let providerID = "private-test"
    let providerName = "Private Test"
    let promptSelectionID = "private-test"
    let defaultModelID = "dictation-model"
    let selectedModelDefaultsKey = "private-test-model"
    let localModelPathDefaultsKey = "private-test-path"
    let prefixCacheDefaultsKey = "private-test-cache"
    let boostDefaultsKey = "private-test-boost"
    let modelDirectoryName = "PrivateTest"

    func modelIDs() -> [String] { ["dictation-model"] }
    func model(id _: String) -> PrivateAIRegisteredModel? { nil }
    func canonicalModelID(for _: String) -> String? { nil }
    func isKnownModelID(_: String) -> Bool { false }
}

@MainActor
final class ProviderEndpointRuleTests: XCTestCase {
    // Turns red if the shared local-endpoint check stops treating the IPv6
    // loopback as local, so an Ollama server at http://[::1] asks for an API key again.
    func testIPv6LoopbackIsLocal() {
        XCTAssertTrue(ModelRepository.isLocalEndpoint("http://[::1]:11434/v1"))
        XCTAssertTrue(ModelRepository.shared.isLocalEndpoint("http://[::1]/v1"))
        XCTAssertTrue(DictationAIPostProcessingGate.isLocalEndpoint("http://[::1]:1234"))
    }

    // Turns red if the local-endpoint rule loses one of its private ranges or
    // starts treating a public host as local.
    func testLocalEndpointRanges() {
        for url in ["http://localhost:11434", "http://127.0.0.1:1234", "http://10.0.0.5", "http://192.168.1.20", "http://172.16.0.1", "http://172.31.255.1"] {
            XCTAssertTrue(ModelRepository.isLocalEndpoint(url), url)
        }
        for url in ["https://api.cerebras.ai/v1", "http://172.32.0.1", "http://172.15.0.1", "http://[2001:db8::1]", "not a url"] {
            XCTAssertFalse(ModelRepository.isLocalEndpoint(url), url)
        }
    }

    // Turns red if a caller's provider key rule drifts from ModelRepository's,
    // for example by returning the raw id for a custom provider or a non-empty key for blank input.
    func testProviderKeyRuleIsShared() {
        let repository = ModelRepository.shared
        XCTAssertEqual(repository.providerKey(for: "cerebras"), "cerebras")
        XCTAssertEqual(repository.providerKey(for: "my-server"), "custom:my-server")
        XCTAssertEqual(repository.providerKey(for: " custom:my-server "), "custom:my-server")
        XCTAssertEqual(repository.providerKey(for: "   "), "")
        for id in ["cerebras", "my-server", "custom:my-server", "", "   "] {
            XCTAssertEqual(DictationAIPostProcessingGate.providerKey(for: id), repository.providerKey(for: id), id)
        }
    }
}
