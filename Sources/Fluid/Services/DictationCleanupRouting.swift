import Foundation

/// Budget and fallback rules for dictation cleanup when the default provider is
/// a fast cloud model (Cerebras) and a local Ollama model covers offline use.
nonisolated enum DictationCleanupRouting {
    static let localFallbackProviderID = "ollama"

    /// Providers fast enough for the tight cloud budget. Other cloud providers
    /// keep the general budget so their cleanup isn't silently cut off.
    static let cloudBudgetProviderKeys: Set<String> = ["cerebras"]

    static func usesCloudBudget(providerKey: String) -> Bool {
        self.cloudBudgetProviderKeys.contains(providerKey.lowercased())
    }

    /// True when the cloud provider could not be reached or refused the request,
    /// so the local model is worth a try. Running out of budget is not one of
    /// these: by then the rule-cleaned text is the faster answer.
    static func shouldRetryLocally(after error: Error) -> Bool {
        if error is LatencyBudget.Exceeded {
            return false
        }
        if let aiError = error as? AIProcessingError {
            switch aiError {
            case .missingAPIKey, .noVerifiedProvider, .missingModel:
                return true
            case .emptyResponse, .dictationExceedsAIContextWindow:
                return false
            }
        }
        switch LLMErrorKind(error) {
        case .unreachable, .authFailed, .rateLimited, .providerError, .badResponse:
            return true
        case .cancelled, .timedOut, .badRequest, .other:
            return false
        }
    }
}
