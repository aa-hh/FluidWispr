import Foundation

/// What went wrong with an AI request, in the terms callers decide on. Every AI request path
/// reads this instead of matching `LLMError` cases itself, so a new error case is sorted once.
nonisolated enum LLMErrorKind: Equatable {
    /// The request was cancelled, by the app or by URLSession.
    case cancelled
    /// The provider could not be reached: no connection, host not found, connection lost.
    case unreachable
    /// The provider took longer than the request's time limit.
    case timedOut
    /// HTTP 401 or 403: the key is wrong or lacks access.
    case authFailed
    /// HTTP 429.
    case rateLimited
    /// Any other HTTP error status.
    case providerError(Int)
    /// The provider answered with something that is not a usable response.
    case badResponse
    /// The request could not be built or was refused before it was sent.
    case badRequest
    /// Not an AI request error.
    case other

    init(_ error: Error) {
        if error is CancellationError {
            self = .cancelled
            return
        }
        if let urlError = error as? URLError {
            self = urlError.code == .cancelled ? .cancelled : .unreachable
            return
        }
        guard let llmError = error as? LLMError else {
            self = .other
            return
        }
        switch llmError {
        case let .networkError(underlying):
            self = (underlying as? URLError)?.code == .cancelled ? .cancelled : .unreachable
        case .timeout:
            self = .timedOut
        case let .httpError(status, _):
            switch status {
            case 401, 403: self = .authFailed
            case 429: self = .rateLimited
            default: self = .providerError(status)
            }
        case .invalidResponse:
            self = .badResponse
        case .invalidURL, .encodingError, .invalidRequest:
            self = .badRequest
        }
    }
}
