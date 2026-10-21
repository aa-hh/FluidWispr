@testable import FluidVoice_Debug
import Foundation
import XCTest

final class ProviderSetupDraftTests: XCTestCase {
    private let connectionEdits: [(String, (inout ProviderSetupDraft) -> Void)] = [
        ("provider", { $0.providerID = "ollama" }),
        ("address", { $0.baseURL = "http://localhost:4321/v1" }),
        ("key", { $0.apiKey = "replacement-key" }),
    ]

    // Turns red if changing the provider, address, or key keeps a model fetched from the old connection,
    // or a late model list from the old connection is accepted.
    func testConnectionEditDropsFetchedModelAndLateResults() {
        for (label, edit) in self.connectionEdits {
            var draft = ProviderSetupDraft(name: "Server", baseURL: "http://localhost:1234/v1")
            let oldIdentity = draft.connectionIdentity
            XCTAssertTrue(draft.applyFetchedModels(["second", "first", "first"], for: oldIdentity), label)
            XCTAssertEqual(draft.model, "first", label)
            draft.selectFetchedModel("second")
            edit(&draft)

            XCTAssertTrue(draft.model.isEmpty, label)
            XCTAssertTrue(draft.fetchedModels.isEmpty, label)
            XCTAssertTrue(draft.modelsToSave(defaults: []).isEmpty, label)
            XCTAssertFalse(draft.applyFetchedModels(["stale"], for: oldIdentity), label)
            XCTAssertTrue(draft.model.isEmpty, label)
        }
    }

    // Turns red if a connection edit or an empty model list erases a model ID the user typed.
    func testConnectionEditKeepsTypedModel() {
        for (label, edit) in self.connectionEdits {
            var draft = ProviderSetupDraft(name: "Server", baseURL: "http://localhost:1234/v1")
            draft.applyFetchedModels(["first"], for: draft.connectionIdentity)
            // Typing even the same ID makes it a manual choice.
            draft.model = "first"
            edit(&draft)

            XCTAssertEqual(draft.model, "first", label)
            XCTAssertTrue(draft.fetchedModels.isEmpty, label)
            XCTAssertEqual(draft.modelsToSave(defaults: []), ["first"], label)
            draft.applyFetchedModels([], for: draft.connectionIdentity)
            XCTAssertEqual(draft.model, "first", label)
        }
    }

    // Turns red if renaming or padding the address drops a fetched choice, or a reload keeps a model the server no longer lists.
    func testReloadKeepsOrReplacesFetchedChoice() {
        var draft = ProviderSetupDraft(name: "Server", baseURL: "http://localhost:1234/v1")
        draft.applyFetchedModels(["first", "second"], for: draft.connectionIdentity)
        draft.selectFetchedModel("second")
        draft.name = "Renamed server"
        draft.baseURL = " http://localhost:1234/v1 "
        XCTAssertEqual(draft.model, "second")
        draft.applyFetchedModels(["second", "third"], for: draft.connectionIdentity)
        XCTAssertEqual(draft.model, "second")
        draft.applyFetchedModels(["third"], for: draft.connectionIdentity)
        XCTAssertEqual(draft.model, "third")
        draft.applyFetchedModels([], for: draft.connectionIdentity)
        XCTAssertTrue(draft.model.isEmpty)
    }

    // Turns red if the saved model list stops putting the chosen model first, drops fetched models, or loses the defaults fallback.
    func testModelsToSaveOrder() {
        var draft = ProviderSetupDraft(name: "Local", baseURL: "http://localhost:1234/v1", model: "tiny")
        draft.fetchedModels = ["first", "second"]
        draft.model = "second"
        XCTAssertEqual(draft.modelsToSave(defaults: []), ["second", "first"])
        draft.model = "manual"
        XCTAssertEqual(draft.modelsToSave(defaults: []), ["manual", "first", "second"])
        draft.model = ""
        XCTAssertEqual(draft.modelsToSave(defaults: ["default"]), ["first", "second"])
        draft.fetchedModels = []
        XCTAssertEqual(draft.modelsToSave(defaults: ["default"]), ["default"])
    }

    // Turns red if choosing a model makes an in-flight model list look stale, or a key change does not.
    func testConnectionIdentityIgnoresModelButNotKey() {
        var draft = ProviderSetupDraft(name: "Local", baseURL: "http://localhost:1234/v1", model: "tiny")
        let original = draft.connectionIdentity
        draft.model = "another"
        XCTAssertEqual(draft.connectionIdentity, original)
        draft.apiKey = "changed"
        XCTAssertNotEqual(draft.connectionIdentity, original)
    }

    // Turns red if a non-HTTP address or one with a user name and password in it is accepted.
    func testAddressValidation() {
        var draft = ProviderSetupDraft(name: "Local", baseURL: "http://localhost:1234/v1", model: "tiny")
        XCTAssertTrue(draft.isValid)
        draft.baseURL = "file:///tmp/model"
        XCTAssertFalse(draft.isValid)
        draft.baseURL = "https://user:secret@example.com"
        XCTAssertFalse(draft.isValid)
    }
}
