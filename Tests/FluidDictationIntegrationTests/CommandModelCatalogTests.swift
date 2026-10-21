@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Command Mode's model chooser: which providers and models it lists, how search filters them,
/// and that choosing one changes only Command Mode's own settings.
@MainActor
final class CommandModelCatalogTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var keys: [String: String] = [:]

    override func setUp() async throws {
        try self.makeFixture()
    }

    override func tearDown() async throws {
        self.removeSuite()
    }

    private func removeSuite() {
        guard !self.suiteName.isEmpty else { return }
        self.defaults?.removePersistentDomain(forName: self.suiteName)
        self.settings = nil
        self.defaults = nil
        self.suiteName = ""
    }

    /// A fresh SettingsStore on its own suite with four verified providers and one unverified one.
    private func makeFixture() throws {
        self.removeSuite()
        self.suiteName = "CommandModelCatalogTests.\(UUID().uuidString)"
        self.defaults = try XCTUnwrap(UserDefaults(suiteName: self.suiteName)) // isolation-ok: own suite, removed in tearDown
        self.settings = SettingsStore(defaults: self.defaults)
        self.keys = [:]
        self.settings.selectedProviderID = "openai"
        self.settings.selectedModel = "global-model"
        self.settings.selectedModelByProvider = ["openai": "global-model"]
        self.settings.rewriteModeSelectedProviderID = "anthropic"
        self.settings.rewriteModeSelectedModel = "rewrite-model"
        self.settings.savedProviders = [
            .init(id: "custom-a", name: "My Gateway", baseURL: "https://gateway.test/v1", models: ["saved-fallback"]),
            .init(id: "custom:custom-a", name: "Duplicate alias", baseURL: "https://gateway.test/v1", models: ["alias-fallback"]),
            .init(id: "custom-b", name: "Home Server", baseURL: "http://localhost:1235/v1", models: ["home-chat"]),
            .init(id: "unverified", name: "Not Verified", baseURL: "https://unverified.test/v1", models: ["hidden-model"]),
        ]
        self.settings.availableModelsByProvider = [
            "openai": ["shared-model", " shared-model ", "chat-beta", "", "text-embedding-3", "rerank-v2", "moderation-v1", "tts-one", "whisper-one", "dall-e-3", "davinci"],
            "custom:custom-a": ["shared-model", "custom-chat"],
            "custom-a": ["old-alias-model"],
        ]
        try self.verify("openai", baseURL: ModelRepository.shared.defaultBaseURL(for: "openai"), key: "openai-key")
        try self.verify("anthropic", baseURL: ModelRepository.shared.defaultBaseURL(for: "anthropic"), key: "anthropic-key")
        try self.verify("custom-a", baseURL: "https://gateway.test/v1", key: "gateway-key")
        try self.verify("custom-b", baseURL: "http://localhost:1235/v1", key: "")
    }

    private func verify(_ providerID: String, baseURL: String, key: String) throws {
        let providerKey = ModelRepository.shared.providerKey(for: providerID)
        self.keys[providerKey] = key
        self.settings.verifiedProviderFingerprints[providerKey] = try XCTUnwrap(ProviderVerification.fingerprint(baseURL: baseURL, apiKey: key))
    }

    private var catalog: [CommandModelOption] { self.settings.commandModeModelCatalog(apiKeys: self.keys) }

    private func select(_ option: CommandModelOption) -> Bool { self.settings.selectCommandModeModel(option, apiKeys: self.keys) }

    /// The keys of this suite whose stored values differ between two snapshots.
    private func changedKeys(since before: [String: Any]) -> Set<String> {
        let after = self.defaults.persistentDomain(forName: self.suiteName) ?? [:]
        return Set(before.keys).union(after.keys).filter { key in
            switch (before[key], after[key]) {
            case let (old?, new?): return !(old as AnyObject).isEqual(new)
            case (nil, nil): return false
            default: return true
            }
        }
    }

    private var stored: [String: Any] { self.defaults.persistentDomain(forName: self.suiteName) ?? [:] }

    // Turns red if the chooser lists an unverified provider, a non-chat or duplicate model, or a stale alias list.
    func testCatalogListsEveryVerifiedProviderAndOnlyChatModels() {
        let before = self.stored
        let options = self.catalog

        XCTAssertEqual(Set(options.map(\.providerID)), ["openai", "anthropic", "custom-a", "custom-b"])
        XCTAssertEqual(options.filter { $0.providerID == "openai" }.map(\.modelID), ["shared-model", "chat-beta"])
        XCTAssertEqual(options.filter { $0.providerID == "custom-a" }.map(\.modelID), ["shared-model", "custom-chat"])
        XCTAssertTrue(options.contains { $0.providerID == "custom-b" && $0.modelID == "home-chat" }, "A saved model list is used when nothing was fetched")
        XCTAssertTrue(options.contains { $0.providerID == "anthropic" && $0.modelID == "claude-sonnet-4-20250514" }, "Built-in fallback models come from ModelRepository")
        XCTAssertTrue(options.allSatisfy { $0.displayName == ModelDisplayName.forID($0.modelID) })
        let shared = options.filter { $0.modelID == "shared-model" }
        XCTAssertEqual(Set(shared.map(\.id)).count, 2, "The same model on two providers keeps two rows")
        XCTAssertEqual(Set(options.map(\.id)).count, options.count)
        XCTAssertTrue(self.changedKeys(since: before).isEmpty, "Building the catalog writes nothing")

        let trickyA = CommandModelOption(providerID: "a", providerName: "A", modelID: "bc:d", displayName: "x")
        let trickyB = CommandModelOption(providerID: "ab", providerName: "B", modelID: "c:d", displayName: "x")
        XCTAssertNotEqual(trickyA.id, trickyB.id)
    }

    // Turns red if search stops matching model IDs, display names or provider names, or falls back to unrelated rows.
    func testSearchMatchesModelAndProviderNames() {
        let options = self.catalog

        XCTAssertEqual(CommandModelCatalog.filtered(options, query: "  \n "), options)
        XCTAssertEqual(CommandModelCatalog.filtered(options, query: "CHAT-BETA").map(\.modelID), ["chat-beta"])
        XCTAssertTrue(CommandModelCatalog.filtered(options, query: "MY GATEWAY").allSatisfy { $0.providerID == "custom-a" })
        XCTAssertEqual(CommandModelCatalog.filtered(options, query: "gateway shared").map(\.providerID), ["custom-a"])
        XCTAssertEqual(CommandModelCatalog.filtered(options, query: "custom-b").map(\.modelID), ["home-chat"])
        XCTAssertTrue(CommandModelCatalog.filtered(options, query: "missing model").isEmpty)
    }

    // Turns red if choosing a model in the chooser changes dictation, Edit Mode, verification or model lists.
    func testChoosingAModelChangesOnlyCommandMode() throws {
        let option = try XCTUnwrap(self.catalog.first { $0.providerID == "custom-a" && $0.modelID == "custom-chat" })
        let fingerprints = self.settings.verifiedProviderFingerprints
        let modelLists = self.settings.availableModelsByProvider
        let saved = self.settings.savedProviders
        XCTAssertTrue(self.settings.commandModeLinkedToGlobal)
        let before = self.stored

        XCTAssertTrue(self.select(option))

        XCTAssertEqual(self.settings.commandModeSelectedProviderID, "custom-a")
        XCTAssertEqual(self.settings.commandModeSelectedModel, "custom-chat")
        XCTAssertFalse(self.settings.commandModeLinkedToGlobal)
        XCTAssertEqual(self.settings.selectedProviderID, "openai")
        XCTAssertEqual(self.settings.selectedModel, "global-model")
        XCTAssertEqual(self.settings.selectedModelByProvider, ["openai": "global-model"])
        XCTAssertEqual(self.settings.rewriteModeSelectedProviderID, "anthropic")
        XCTAssertEqual(self.settings.rewriteModeSelectedModel, "rewrite-model")
        XCTAssertEqual(self.settings.verifiedProviderFingerprints, fingerprints)
        XCTAssertEqual(self.settings.availableModelsByProvider, modelLists)
        XCTAssertEqual(self.settings.savedProviders, saved)
        XCTAssertFalse(self.changedKeys(since: before).isEmpty)
        let commandKeys = self.changedKeys(since: before).filter { !$0.lowercased().contains("commandmode") }
        XCTAssertTrue(commandKeys.isEmpty, "Only Command Mode settings change, not \(commandKeys)")
    }

    // Turns red if a row picked before its provider lost verification, its key, its address or its model can still be chosen.
    func testAStaleOrInventedRowCannotBeChosen() throws {
        let option = try XCTUnwrap(self.catalog.first { $0.providerID == "custom-a" })
        let changes: [(String, () -> Void)] = [
            ("unverified", { self.settings.verifiedProviderFingerprints.removeValue(forKey: "custom:custom-a") }),
            ("key changed", { self.keys["custom:custom-a"] = "replacement-key" }),
            ("URL changed", { self.settings.savedProviders = [.init(id: "custom-a", name: "Changed", baseURL: "https://changed.test/v1", models: [])] }),
            ("model removed", { self.settings.availableModelsByProvider["custom:custom-a"] = ["replacement-model"] }),
            ("provider removed", { self.settings.savedProviders = [] }),
        ]
        for (change, apply) in changes {
            try self.makeFixture()
            apply()
            let before = self.stored
            XCTAssertFalse(self.select(option), change)
            XCTAssertTrue(self.settings.commandModeSelectedProviderID.isEmpty, change)
            XCTAssertNil(self.settings.commandModeSelectedModel, change)
            XCTAssertTrue(self.settings.commandModeLinkedToGlobal, change)
            XCTAssertTrue(self.changedKeys(since: before).isEmpty, change)
        }

        let before = self.stored
        for model in ["text-embedding-3", "whisper-one", "missing", ""] {
            let invented = CommandModelOption(providerID: "openai", providerName: "OpenAI", modelID: model, displayName: model)
            XCTAssertFalse(self.select(invented), model)
        }
        XCTAssertTrue(self.changedKeys(since: before).isEmpty)
    }

    // Turns red if a "custom:" alias and the raw provider ID stop resolving to the same provider and models.
    func testCustomProviderAliasesResolveToTheSameProvider() {
        XCTAssertTrue(self.settings.isCommandModeProviderVerified("custom:custom-a", apiKeys: self.keys))
        XCTAssertEqual(self.settings.commandModeModels(for: "custom:custom-a"), self.settings.commandModeModels(for: "custom-a"))
        let alias = CommandModelOption(providerID: "custom:custom-a", providerName: "Old label", modelID: "custom-chat", displayName: "Old display")
        XCTAssertTrue(self.select(alias))
        XCTAssertEqual(self.settings.commandModeSelectedProviderID, "custom-a")

        self.settings.availableModelsByProvider.removeValue(forKey: "custom:custom-a")
        XCTAssertEqual(self.settings.commandModeModels(for: "custom-a"), ["old-alias-model"])
    }

    // Turns red if a verified keyless provider drops out, or verification reads a different key than requests send.
    func testKeylessProvidersAndKeyPrecedenceMatchRequests() throws {
        self.settings.savedProviders.append(.init(id: "keyless", name: "Verified keyless", baseURL: "https://keyless.test/v1", models: ["keyless-chat"]))
        try self.verify("keyless", baseURL: "https://keyless.test/v1", key: "")
        XCTAssertTrue(self.catalog.contains { $0.providerID == "keyless" })

        self.keys["custom-a"] = "raw-key-takes-precedence"
        XCTAssertFalse(self.catalog.contains { $0.providerID == "custom-a" }, "The registered ID's key wins, as in getAPIKey")

        self.settings.savedProviders.append(.init(id: "custom:raw-only", name: "Canonical registration", baseURL: "https://raw.test/v1", models: ["raw-chat"]))
        try self.verify("custom:raw-only", baseURL: "https://raw.test/v1", key: "raw-secret")
        self.keys["raw-only"] = self.keys.removeValue(forKey: "custom:raw-only")
        XCTAssertFalse(self.catalog.contains { $0.providerID == "custom:raw-only" }, "A raw alias key that requests would not send cannot verify")
        self.keys["custom:raw-only"] = "raw-secret"
        XCTAssertTrue(self.catalog.contains { $0.providerID == "custom:raw-only" })
    }
}
