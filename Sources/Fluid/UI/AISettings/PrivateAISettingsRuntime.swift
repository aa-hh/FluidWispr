import Foundation

/// The provider settings that `PrivateAISettingsController` reads and edits.
/// `AIEnhancementSettingsViewModel` is the app's one conformer; tests pass their own.
@MainActor
protocol PrivateAISettingsProviderBridge: AnyObject {
    var settings: SettingsStore { get }
    var selectedProviderID: String { get }
    var availableModelsByProvider: [String: [String]] { get set }
    var selectedModelByProvider: [String: String] { get set }
    var availableModels: [String] { get set }
    var selectedModel: String { get set }
    var isTestingConnection: Bool { get }
    var routesDictationThroughPrivateAI: Bool { get }

    func providerKey(for providerID: String) -> String
    func refreshProviderItems()
    func connectionErrorMessage(for providerID: String) -> String
    func resetVerification(for providerID: String)
    func updateConnectionStatus(_ status: AIConnectionStatus, for providerID: String)
    func verifyPrivateAIProvider(model: PrivateAIRegisteredModel) async -> Bool
    func selectPrivateAIPromptIfAvailable()
    func turnOffPrivateAIDictationSlots()
}

extension AIEnhancementSettingsViewModel: PrivateAISettingsProviderBridge {}

/// The model catalog, downloads and loaded runtime behind the Private AI settings card.
/// `LivePrivateAISettingsRuntime` forwards to `PrivateAIIntegrationService`; tests pass their own.
@MainActor
protocol PrivateAISettingsRuntime: AnyObject {
    var providerID: String { get }
    var configuredModelID: String { get }
    var defaultModel: PrivateAIRegisteredModel { get }
    var modelDirectoryURL: URL { get }

    func model(id: String) -> PrivateAIRegisteredModel?
    func modelIDs() -> [String]
    func canonicalModelID(for id: String) -> String?
    func isModelInstalled(_ model: PrivateAIRegisteredModel) -> Bool
    func canRemoveInstalledModel(_ model: PrivateAIRegisteredModel) -> Bool
    func modelUpdateStatus(_ model: PrivateAIRegisteredModel) async -> PrivateAIModelUpdateStatus
    func prepareModel(
        _ model: PrivateAIRegisteredModel,
        progressHandler: PrivateAIModelDownloadProgressHandler?
    ) async throws -> URL
    func updateModel(
        _ model: PrivateAIRegisteredModel,
        progressHandler: PrivateAIModelDownloadProgressHandler?
    ) async throws -> PrivateAIModelUpdateToken
    func commitModelUpdate(_ token: PrivateAIModelUpdateToken) async
    func rollbackModelUpdate(_ token: PrivateAIModelUpdateToken) async
    func loadedModelState() async -> PrivateAIIntegrationService.LoadedModelState?
    func loadModel(_ model: PrivateAIRegisteredModel) async throws -> PrivateAIStatus
    func unloadCachedRuntime(reason: String) async
    func unloadAndRemoveInstalledModel(_ model: PrivateAIRegisteredModel, reason: String) async throws
}

@MainActor
final class LivePrivateAISettingsRuntime: PrivateAISettingsRuntime {
    /// Nonisolated so it can be the controller init's default argument.
    nonisolated init() {}

    var providerID: String { PrivateAIProviderFeature.shared.providerID }
    var configuredModelID: String { PrivateAIIntegrationService.configuredModelID }
    var defaultModel: PrivateAIRegisteredModel { PrivateAIModelRegistry.defaultModel }
    var modelDirectoryURL: URL { PrivateAIIntegrationService.modelDirectoryURL }

    func model(id: String) -> PrivateAIRegisteredModel? { PrivateAIModelRegistry.model(id: id) }
    func modelIDs() -> [String] { PrivateAIModelRegistry.modelIDs() }
    func canonicalModelID(for id: String) -> String? { PrivateAIModelRegistry.canonicalModelID(for: id) }
    func isModelInstalled(_ model: PrivateAIRegisteredModel) -> Bool { PrivateAIIntegrationService.isModelInstalled(model) }

    func canRemoveInstalledModel(_ model: PrivateAIRegisteredModel) -> Bool {
        PrivateAIIntegrationService.canRemoveInstalledModel(model)
    }

    func modelUpdateStatus(_ model: PrivateAIRegisteredModel) async -> PrivateAIModelUpdateStatus {
        await PrivateAIIntegrationService.modelUpdateStatus(model)
    }

    func prepareModel(
        _ model: PrivateAIRegisteredModel,
        progressHandler: PrivateAIModelDownloadProgressHandler?
    ) async throws -> URL {
        try await PrivateAIIntegrationService.prepareModel(model, progressHandler: progressHandler)
    }

    func updateModel(
        _ model: PrivateAIRegisteredModel,
        progressHandler: PrivateAIModelDownloadProgressHandler?
    ) async throws -> PrivateAIModelUpdateToken {
        try await PrivateAIIntegrationService.updateModel(model, progressHandler: progressHandler)
    }

    func commitModelUpdate(_ token: PrivateAIModelUpdateToken) async {
        await PrivateAIIntegrationService.commitModelUpdate(token)
    }

    func rollbackModelUpdate(_ token: PrivateAIModelUpdateToken) async {
        await PrivateAIIntegrationService.rollbackModelUpdate(token)
    }

    func loadedModelState() async -> PrivateAIIntegrationService.LoadedModelState? {
        await PrivateAIIntegrationService.shared.loadedModelState()
    }

    func loadModel(_ model: PrivateAIRegisteredModel) async throws -> PrivateAIStatus {
        try await PrivateAIIntegrationService.shared.loadModel(model)
    }

    func unloadCachedRuntime(reason: String) async {
        await PrivateAIIntegrationService.shared.unloadCachedRuntime(reason: reason)
    }

    func unloadAndRemoveInstalledModel(_ model: PrivateAIRegisteredModel, reason: String) async throws {
        try await PrivateAIIntegrationService.shared.unloadAndRemoveInstalledModel(model, reason: reason)
    }
}
