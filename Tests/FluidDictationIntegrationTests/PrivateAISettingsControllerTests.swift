@testable import FluidVoice_Debug
import Foundation
import XCTest

private final class CountingDefaults: UserDefaults {
    var writtenKeys: [String] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        self.writtenKeys.append(defaultName)
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        self.writtenKeys.append(defaultName)
        super.removeObject(forKey: defaultName)
    }
}

private enum FakeFailure: Error { case expected }

/// Stands in for the model catalog, downloads and loaded runtime. Reads and loads can be held open
/// so a test decides when they finish.
@MainActor
private final class FakePrivateAIRuntime: PrivateAISettingsRuntime {
    let providerID = "fi"
    let defaults: UserDefaults
    let initialModelID: String
    /// Follows the selection the controller writes, as the real service does.
    var configuredModelID: String {
        self.defaults.string(forKey: PrivateAIIntegrationService.selectedModelDefaultsKey) ?? self.initialModelID
    }

    let models: [PrivateAIRegisteredModel]
    let modelDirectoryURL = URL(fileURLWithPath: "/nonexistent/fluid-private-ai-tests")
    var defaultModel: PrivateAIRegisteredModel { self.models[0] }

    var installed = false
    var failDownload = false
    var downloads = 0
    var loads = 0
    var commits = 0
    var rollbacks = 0
    var removals = 0
    var lastProgress: PrivateAIModelDownloadProgressHandler?
    var holdRead = false
    var heldRead: CheckedContinuation<PrivateAIIntegrationService.LoadedModelState?, Never>?
    var holdLoad = false
    var heldLoad: CheckedContinuation<PrivateAIStatus, Never>?

    init(configuredModelID: String, models: [PrivateAIRegisteredModel], defaults: UserDefaults) {
        self.initialModelID = configuredModelID
        self.defaults = defaults
        self.models = models
    }

    func model(id: String) -> PrivateAIRegisteredModel? { self.models.first { $0.id == id } }
    func modelIDs() -> [String] { self.models.map(\.id) }
    func canonicalModelID(for id: String) -> String? { self.model(id: id)?.id }
    func isModelInstalled(_ model: PrivateAIRegisteredModel) -> Bool { self.installed }
    func canRemoveInstalledModel(_ model: PrivateAIRegisteredModel) -> Bool { self.installed }

    func modelUpdateStatus(_ model: PrivateAIRegisteredModel) async -> PrivateAIModelUpdateStatus {
        PrivateAIModelUpdateStatus(state: .current, installedVersion: nil, availableVersion: nil)
    }

    func prepareModel(
        _ model: PrivateAIRegisteredModel,
        progressHandler: PrivateAIModelDownloadProgressHandler?
    ) async throws -> URL {
        self.downloads += 1
        self.lastProgress = progressHandler
        if self.failDownload { throw FakeFailure.expected }
        await progressHandler?(PrivateAIModelDownloadProgress(initialExpectedBytes: 10))
        return self.modelDirectoryURL
    }

    func updateModel(
        _ model: PrivateAIRegisteredModel,
        progressHandler: PrivateAIModelDownloadProgressHandler?
    ) async throws -> PrivateAIModelUpdateToken {
        _ = try await self.prepareModel(model, progressHandler: progressHandler)
        return PrivateAIModelUpdateToken(id: UUID())
    }

    func commitModelUpdate(_ token: PrivateAIModelUpdateToken) async { self.commits += 1 }
    func rollbackModelUpdate(_ token: PrivateAIModelUpdateToken) async { self.rollbacks += 1 }

    func loadedModelState() async -> PrivateAIIntegrationService.LoadedModelState? {
        guard self.holdRead else { return nil }
        return await withCheckedContinuation { self.heldRead = $0 }
    }

    func loadModel(_ model: PrivateAIRegisteredModel) async throws -> PrivateAIStatus {
        self.loads += 1
        guard self.holdLoad else { return PrivateAIStatus(state: .ready, message: nil) }
        return await withCheckedContinuation { self.heldLoad = $0 }
    }

    func unloadCachedRuntime(reason: String) async {}

    func unloadAndRemoveInstalledModel(_ model: PrivateAIRegisteredModel, reason: String) async throws {
        self.removals += 1
    }
}

/// Stands in for the provider settings page: an external provider stays selected while the
/// Private AI card is edited, and verification answers whatever `verified` says.
@MainActor
private final class FakeProviderBridge: PrivateAISettingsProviderBridge {
    let settings: SettingsStore
    let selectedProviderID = "external"
    var availableModelsByProvider = ["external": ["external-model"]]
    var selectedModelByProvider = ["external": "external-model"]
    var availableModels = ["external-model"]
    var selectedModel = "external-model"
    let isTestingConnection = false

    var verified = true
    var verificationMessage = "test failure"
    var verificationCount = 0
    var resetCount = 0
    var smartSelectionCount = 0
    var smartSelected = false
    var routesDictationThroughPrivateAI: Bool { self.smartSelected }

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func providerKey(for providerID: String) -> String { providerID }
    func refreshProviderItems() {}
    func connectionErrorMessage(for providerID: String) -> String { self.verificationMessage }
    func resetVerification(for providerID: String) { self.resetCount += 1 }
    func updateConnectionStatus(_ status: AIConnectionStatus, for providerID: String) {}

    func verifyPrivateAIProvider(model: PrivateAIRegisteredModel) async -> Bool {
        self.verificationCount += 1
        return self.verified
    }

    func selectPrivateAIPromptIfAvailable() {
        guard self.verified else { return }
        self.smartSelectionCount += 1
        self.smartSelected = true
    }

    func turnOffPrivateAIDictationSlots() { self.smartSelected = false }
}

/// The Private AI settings card's controller run against fakes: browsing stays read-only, one
/// operation runs at a time, late results cannot overwrite newer state, and failures stay visible.
@MainActor
final class PrivateAISettingsControllerTests: XCTestCase {
    private var suiteNames: [String] = []
    private var defaults: CountingDefaults!
    private var runtime: FakePrivateAIRuntime!
    private var bridge: FakeProviderBridge!
    private var controller: PrivateAISettingsController!

    private var mini: PrivateAIRegisteredModel { Self.model("mini") }
    private var pico: PrivateAIRegisteredModel { Self.model("pico") }

    override func tearDown() async throws {
        self.controller = nil
        for name in self.suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) // isolation-ok: this test's own suites
        }
        self.suiteNames = []
        try await super.tearDown()
    }

    private nonisolated static func model(_ id: String, downloadable: Bool = true) -> PrivateAIRegisteredModel {
        PrivateAIRegisteredModel(
            displayName: id,
            detail: "",
            isEnabled: true,
            parameterCount: "",
            recommendedMemoryGB: nil,
            artifact: PrivateAIModelArtifact(
                identifier: id,
                filename: "\(id).bin",
                downloadURL: downloadable ? URL(string: "https://example.invalid/\(id).bin") : nil,
                sha256: downloadable ? "abc" : nil,
                byteCount: 10,
                version: "1"
            )
        )
    }

    private func makeController(configuredModelID: String) throws {
        let controllerSuite = "PrivateAISettingsControllerTests.\(UUID().uuidString)"
        let settingsSuite = "PrivateAISettingsControllerTests.settings.\(UUID().uuidString)"
        self.suiteNames += [controllerSuite, settingsSuite]
        self.defaults = try XCTUnwrap(CountingDefaults(suiteName: controllerSuite)) // isolation-ok: own suite, removed in tearDown
        let settingsDefaults = try XCTUnwrap(UserDefaults(suiteName: settingsSuite)) // isolation-ok: own suite, removed in tearDown
        self.runtime = FakePrivateAIRuntime(configuredModelID: configuredModelID, models: [self.mini, self.pico], defaults: self.defaults)
        self.bridge = FakeProviderBridge(settings: SettingsStore(defaults: settingsDefaults))
        self.controller = PrivateAISettingsController(
            viewModel: self.bridge,
            runtime: self.runtime,
            defaults: self.defaults,
            notificationCenter: NotificationCenter()
        )
    }

    /// Lets the controller's own tasks run until `condition` holds. Yields only, no clock.
    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("The controller's task never reached the expected state", file: file, line: line)
    }

    private func yieldBriefly() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    private func assertExternalProviderUntouched(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.bridge.selectedProviderID, "external", file: file, line: line)
        XCTAssertEqual(self.bridge.selectedModel, "external-model", file: file, line: line)
        XCTAssertEqual(self.bridge.settings.selectedModelByProvider["external"], "external-model", file: file, line: line)
    }

    // Turns red if browsing the carousel writes defaults, resets verification, loads or downloads,
    // or if activating the previewed model changes the external provider's selection.
    func testBrowsingIsReadOnlyAndActivationLeavesTheExternalProviderAlone() throws {
        try self.makeController(configuredModelID: "mini")
        for _ in 0..<50 {
            self.controller.previewModel("pico")
            self.controller.previewModel("mini")
        }
        self.controller.previewModel("pico")
        self.controller.previewModel("invalid")

        XCTAssertEqual(self.controller.previewModelID, "pico", "An unknown ID is not previewed")
        XCTAssertEqual(self.controller.privateAISelectedModelID, "mini")
        XCTAssertEqual(self.defaults.writtenKeys, [])
        XCTAssertEqual(self.bridge.resetCount, 0)
        XCTAssertEqual(self.runtime.loads + self.runtime.downloads, 0)

        self.controller.activatePreviewModel()
        XCTAssertEqual(self.controller.privateAISelectedModelID, "pico")
        XCTAssertEqual(
            self.defaults.writtenKeys,
            [PrivateAIIntegrationService.selectedModelDefaultsKey, PrivateAIIntegrationService.localModelPathDefaultsKey]
        )
        XCTAssertEqual(self.defaults.string(forKey: PrivateAIIntegrationService.selectedModelDefaultsKey), "pico")
        self.assertExternalProviderUntouched()
    }

    // Turns red if reading another card's update status selects that model, or if maintenance on
    // a model that is not selected runs against the selected runtime.
    func testAnotherCardsStatusReadAndMaintenanceNeverTouchTheSelectedModel() async throws {
        try self.makeController(configuredModelID: "pico")
        self.controller.refreshPrivateAIModelUpdateStatus(self.mini)
        await self.settle { self.controller.privateAIModelUpdateStatusByID["mini"] != nil }

        XCTAssertEqual(self.controller.privateAIModelUpdateStatusByID["mini"]?.state, .current)
        XCTAssertEqual(self.controller.privateAISelectedModelID, "pico")
        XCTAssertEqual(self.defaults.writtenKeys, [])

        self.controller.verifyPrivateAIConnection(self.mini)
        XCTAssertFalse(self.controller.isBusy)
        XCTAssertEqual(self.bridge.verificationCount, 0)
    }

    // Turns red if a busy controller accepts a second download or a model switch, a failed
    // download verifies or stays busy, or late progress replaces the finished state.
    func testFailedDownloadRunsOnceStaysVisibleAndRetryVerifies() async throws {
        try self.makeController(configuredModelID: "pico")
        self.runtime.failDownload = true
        self.controller.downloadPrivateAIModel(self.pico)
        self.controller.downloadPrivateAIModel(self.pico)
        self.controller.persistPrivateAIModelSelection("mini")
        XCTAssertTrue(self.controller.isBusy)
        XCTAssertEqual(self.controller.privateAISelectedModelID, "pico")

        await self.settle { !self.controller.isBusy }
        XCTAssertEqual(self.runtime.downloads, 1)
        XCTAssertEqual(self.bridge.verificationCount, 0)
        XCTAssertNotNil(self.controller.privateAILoadState.failureMessage(for: "pico"))

        self.runtime.failDownload = false
        self.controller.downloadPrivateAIModel(self.pico)
        await self.settle { !self.controller.isBusy }
        XCTAssertTrue(self.controller.privateAILoadState.isLoaded("pico"))
        XCTAssertEqual(self.bridge.verificationCount, 1)

        await self.runtime.lastProgress?(PrivateAIModelDownloadProgress(initialExpectedBytes: 10))
        XCTAssertTrue(self.controller.privateAILoadState.isLoaded("pico"), "Late progress cannot replace ready")
    }

    // Turns red if an update that fails verification is committed, or its error drops the
    // provider's own message; or if a verified update is not committed.
    func testUpdateCommitsOnlyAVerifiedModel() async throws {
        try self.makeController(configuredModelID: "pico")
        self.controller.privateAIModelUpdateStatusByID["pico"] = PrivateAIModelUpdateStatus(
            state: .updateAvailable, installedVersion: "1", availableVersion: "2"
        )
        self.bridge.verified = false
        self.controller.updatePrivateAIModel(self.pico)
        await self.settle { !self.controller.isBusy }

        XCTAssertEqual(self.runtime.rollbacks, 1)
        XCTAssertEqual(self.runtime.commits, 0)
        XCTAssertEqual(self.controller.privateAILoadState.failureMessage(for: "pico")?.contains("test failure"), true)

        await self.settle { self.controller.privateAIModelUpdateStatusByID["pico"]?.state == .current }
        self.controller.privateAIModelUpdateStatusByID["pico"] = PrivateAIModelUpdateStatus(
            state: .updateAvailable, installedVersion: "1", availableVersion: "2"
        )
        self.bridge.verified = true
        self.controller.updatePrivateAIModel(self.pico)
        await self.settle { !self.controller.isBusy }
        XCTAssertEqual(self.runtime.commits, 1)
        XCTAssertEqual(self.runtime.rollbacks, 1)
        XCTAssertTrue(self.controller.privateAILoadState.isLoaded("pico"))
    }

    // Turns red if a coming-soon, unknown or already selected ID persists anything, an action with
    // nothing to do keeps the work slot, or a stale delete removes a model that is not selected.
    func testNoOpSelectionsAndStaleDeletesChangeNothing() async throws {
        try self.makeController(configuredModelID: "pico")
        for upcoming in PrivateAIUpcomingModel.allCases {
            self.controller.previewModel(upcoming.id)
            self.controller.persistPrivateAIModelSelection(upcoming.id)
        }
        self.controller.persistPrivateAIModelSelection("invalid")
        self.controller.persistPrivateAIModelSelection("pico")
        XCTAssertEqual(self.controller.previewModelID, "pico")
        XCTAssertEqual(self.controller.privateAISelectedModelID, "pico")
        XCTAssertEqual(self.defaults.writtenKeys, [])
        XCTAssertEqual(self.bridge.resetCount, 0)

        self.controller.downloadPrivateAIModel(Self.model("pico", downloadable: false))
        XCTAssertFalse(self.controller.isBusy)
        XCTAssertEqual(self.runtime.downloads, 0)

        self.controller.deletePrivateAIModel(self.pico)
        XCTAssertFalse(self.controller.isBusy, "A model that cannot be removed frees the slot")

        self.runtime.installed = true
        self.controller.deletePrivateAIModel(self.mini)
        XCTAssertFalse(self.controller.isBusy)
        XCTAssertEqual(self.runtime.removals, 0, "A stale confirmation for another model deletes nothing")

        self.controller.deletePrivateAIModel(self.pico)
        self.controller.deletePrivateAIModel(self.pico)
        await self.settle { !self.controller.isBusy }
        XCTAssertEqual(self.runtime.removals, 1)
        XCTAssertEqual(self.controller.privateAILoadState, .idle)
        XCTAssertEqual(self.defaults.writtenKeys, [])
        self.assertExternalProviderUntouched()
    }

    // Turns red if a runtime read that started before a load can overwrite the load's state when
    // it lands late, or if the selection can change while the load is running.
    func testLateIdleReadCannotEraseANewerLoad() async throws {
        try self.makeController(configuredModelID: "pico")
        self.runtime.holdRead = true
        self.controller.refreshPrivateAILoadState()
        await self.settle { self.runtime.heldRead != nil }

        self.runtime.installed = true
        self.runtime.holdLoad = true
        self.controller.loadPrivateAIModel(self.pico)
        await self.settle { self.runtime.heldLoad != nil }
        self.runtime.heldRead?.resume(returning: nil)
        self.runtime.heldRead = nil
        await self.yieldBriefly()
        XCTAssertTrue(self.controller.privateAILoadState.isLoading("pico"))
        XCTAssertTrue(self.controller.isBusy)

        self.controller.previewModel("mini")
        self.controller.activatePreviewModel()
        XCTAssertEqual(self.controller.privateAISelectedModelID, "pico", "Activation waits for the load")
        XCTAssertEqual(self.controller.previewModelID, "mini", "Browsing still works during the load")

        self.runtime.heldLoad?.resume(returning: PrivateAIStatus(state: .ready, message: nil))
        self.runtime.heldLoad = nil
        await self.settle { !self.controller.isBusy }
        XCTAssertTrue(self.controller.privateAILoadState.isLoaded("pico"))
    }

    // Turns red if a failed activation switches dictation to Smart, a passive refresh hides the
    // failure, a successful one selects Smart more or less than once, or reopening settings
    // overrides a manual switch back to Basic.
    func testActivationSelectsSmartOnlyAfterVerification() async throws {
        try self.makeController(configuredModelID: "pico")
        self.runtime.installed = true
        self.controller.previewModel("mini")
        var activations = 0

        self.bridge.verified = false
        self.controller.usePreviewModel(isInstalled: true) { activations += 1 }
        self.controller.usePreviewModel(isInstalled: true) { activations += 1 }
        await self.settle { !self.controller.isBusy }
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(self.bridge.smartSelectionCount, 0)

        self.controller.refreshPrivateAILoadState()
        await self.yieldBriefly()
        XCTAssertNotNil(self.controller.privateAILoadState.failureMessage(for: "mini"))

        self.bridge.verified = true
        self.controller.usePreviewModel(isInstalled: true) { activations += 1 }
        await self.settle { !self.controller.isBusy }
        XCTAssertEqual(activations, 1)
        XCTAssertTrue(self.controller.privateAILoadState.isLoaded("mini"))
        XCTAssertTrue(self.bridge.smartSelected)
        XCTAssertEqual(self.bridge.smartSelectionCount, 1)
        self.assertExternalProviderUntouched()

        self.bridge.smartSelected = false
        self.controller.synchronizeSelection()
        XCTAssertFalse(self.bridge.smartSelected, "Reopening settings keeps a manual Basic")
    }

    // Turns red if manual verification reports a result more than once, reports the wrong error,
    // selects Smart, reports for a model that is not selected, or writes defaults.
    func testManualVerificationReportsOnceWithoutChangingRouting() async throws {
        try self.makeController(configuredModelID: "mini")
        self.runtime.installed = true
        var completions = 0
        var reportedError: String?

        self.controller.verifyPrivateAIConnection(self.mini, onCompletion: { error in
            completions += 1
            reportedError = error
        })
        self.controller.verifyPrivateAIConnection(self.mini, onCompletion: { _ in completions += 100 })
        await self.settle { !self.controller.isBusy }
        XCTAssertEqual(completions, 1)
        XCTAssertNil(reportedError)
        XCTAssertEqual(self.bridge.smartSelectionCount, 0)

        self.bridge.verified = false
        self.controller.verifyPrivateAIConnection(self.mini, onCompletion: { error in
            completions += 1
            reportedError = error
        })
        await self.settle { !self.controller.isBusy }
        XCTAssertEqual(completions, 2)
        XCTAssertEqual(reportedError, "test failure")

        self.controller.verifyPrivateAIConnection(self.pico, onCompletion: { _ in completions += 100 })
        XCTAssertEqual(completions, 2)
        XCTAssertEqual(self.defaults.writtenKeys, [])
    }

    // Turns red if missing model files show as a raw failure instead of a repair download, the
    // repair state leaks to another model, verification downloads or deletes on its own, or the
    // explicit repair does not download once and verify.
    func testMissingFilesBecomeARepairDownload() async throws {
        try self.makeController(configuredModelID: "mini")
        self.runtime.installed = true
        self.bridge.verified = false
        var reportedError: String?

        for message in ["Missing local model: model.safetensors.", PrivateAIModelLoadState.missingModelMessage] {
            self.bridge.verificationMessage = message
            let resetsBefore = self.bridge.resetCount
            self.controller.verifyPrivateAIConnection(self.mini, onCompletion: { reportedError = $0 })
            await self.settle { !self.controller.isBusy }
            XCTAssertTrue(self.controller.privateAILoadState.needsDownload("mini"), message)
            XCTAssertFalse(self.controller.privateAILoadState.needsDownload("pico"), message)
            XCTAssertNil(self.controller.privateAILoadState.failureMessage(for: "mini"), message)
            XCTAssertEqual(reportedError, "Model files are missing. Download again to repair.", message)
            XCTAssertEqual(self.bridge.resetCount, resetsBefore + 1, "Stale verification is cleared")
        }
        XCTAssertEqual(self.runtime.downloads, 0)
        XCTAssertEqual(self.runtime.removals, 0)

        self.controller.refreshPrivateAILoadState()
        XCTAssertTrue(self.controller.privateAILoadState.needsDownload("mini"), "A passive refresh keeps the repair state")

        self.bridge.verified = true
        self.controller.usePreviewModel(isInstalled: false) {}
        await self.settle { !self.controller.isBusy }
        XCTAssertTrue(self.controller.privateAILoadState.isLoaded("mini"))
        XCTAssertEqual(self.runtime.downloads, 1)
    }

    // Turns red if the missing-file match widens and swallows another failure's own message.
    func testOtherFailuresKeepTheirMessage() {
        for message in ["Network connection lost", "Not enough disk space", "Model checksum mismatch", "Failed to load local model: model.safetensors."] {
            XCTAssertEqual(PrivateAIModelLoadState.failure(modelID: "mini", message: message).failureMessage(for: "mini"), message)
        }
    }
}
