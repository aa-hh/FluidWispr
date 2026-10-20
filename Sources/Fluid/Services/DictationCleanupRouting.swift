import Foundation

/// Budget and fallback rules for dictation cleanup when the default provider is
/// a cloud model (Cerebras) and a local Ollama model covers offline use.
nonisolated enum DictationCleanupRouting {
    static let localFallbackProviderID = "ollama"

    static func budgetMilliseconds(isLocalEndpoint: Bool, localBudget: Int, cloudBudget: Int) -> Int {
        isLocalEndpoint ? localBudget : cloudBudget
    }

    /// True when the cloud provider could not be reached or refused the request,
    /// so the local model is worth a try. Running out of budget is not one of
    /// these: by then the rule-cleaned text is the faster answer.
    static func shouldRetryLocally(after error: Error) -> Bool {
        if error is LatencyBudget.Exceeded || error is CancellationError {
            return false
        }
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        if let aiError = error as? AIProcessingError {
            switch aiError {
            case .missingAPIKey, .noVerifiedProvider, .missingModel:
                return true
            case .emptyResponse, .dictationExceedsAIContextWindow:
                return false
            }
        }
        guard let llmError = error as? LLMError else { return false }
        switch llmError {
        case let .networkError(underlying):
            return (underlying as? URLError)?.code != .cancelled
        case .httpError, .invalidResponse:
            return true
        case .timeout, .invalidURL, .encodingError, .invalidRequest:
            return false
        }
    }
}
