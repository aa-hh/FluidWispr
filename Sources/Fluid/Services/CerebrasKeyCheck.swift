import Foundation

/// Checks a Cerebras API key against the provider and, when it works, saves it and
/// makes Cerebras the cleanup provider.
enum CerebrasKeyCheck {
    static let providerID = "cerebras"
    static let model = "gpt-oss-120b"

    enum Result: Equatable {
        case accepted
        case rejected
        case unreachable
        case keychainFailed
    }

    typealias FetchModels = (_ providerID: String, _ baseURL: String, _ apiKey: String?) async throws -> [String]

    static var hasKey: Bool {
        KeychainService.shared.containsKey(for: self.providerID)
    }

    static func verify(
        key: String,
        fetch: FetchModels = { try await ModelRepository.shared.fetchModels(for: $0, baseURL: $1, apiKey: $2) }
    ) async -> Result {
        let apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = ModelRepository.shared.defaultBaseURL(for: self.providerID)
        do {
            let models = try await fetch(self.providerID, baseURL, apiKey)
            guard !models.isEmpty else { return .unreachable }
        } catch {
            return Self.result(for: error)
        }

        do {
            try KeychainService.shared.storeKey(apiKey, for: self.providerID)
        } catch {
            return .keychainFailed
        }

        let settings = SettingsStore.shared
        settings.selectedProviderID = self.providerID
        settings.selectedModelByProvider[self.providerID] = self.model
        ProviderModelVerificationStore().recordSuccess(self.identity(apiKey: apiKey))
        if let fingerprint = ProviderVerification.fingerprint(baseURL: baseURL, apiKey: apiKey) {
            settings.verifiedProviderFingerprints[ModelRepository.shared.providerKey(for: self.providerID)] = fingerprint
        }
        return .accepted
    }

    static func removeKey() {
        let settings = SettingsStore.shared
        if let stored = try? KeychainService.shared.fetchKey(for: self.providerID) {
            ProviderModelVerificationStore().remove(self.identity(apiKey: stored))
        }
        try? KeychainService.shared.deleteKey(for: self.providerID)
        settings.verifiedProviderFingerprints.removeValue(forKey: ModelRepository.shared.providerKey(for: self.providerID))
    }

    private static func identity(apiKey: String) -> String {
        ProviderModelVerificationStore.identity(
            providerID: self.providerID,
            baseURL: ModelRepository.shared.defaultBaseURL(for: self.providerID),
            apiKey: apiKey,
            model: self.model
        )
    }

    /// `fetchModels` reports failures as `FetchError`, which `LLMErrorKind` does not read.
    private static func result(for error: Error) -> Result {
        if let fetchError = error as? ModelRepository.FetchError {
            switch fetchError {
            case let .httpError(status, _): return status == 401 || status == 403 ? .rejected : .unreachable
            case .networkError, .invalidURL, .invalidResponse: return .unreachable
            }
        }
        switch LLMErrorKind(error) {
        case .authFailed: return .rejected
        default: return .unreachable
        }
    }
}
