import Foundation

/// What an AI request is for. Each purpose keeps the temperature and token budget its
/// caller used before the request settings moved here.
nonisolated enum LLMRequestPurpose {
    case dictationCleanup
    case edit
    case command
    case meetingSummary

    var temperature: Double {
        switch self {
        case .dictationCleanup, .meetingSummary: return 0.2
        case .edit: return 0.7
        case .command: return 0.1
        }
    }

    /// Reasoning models such as o1 need a large budget for their thought chain.
    /// Dictation cleanup has never set one.
    var reasoningModelMaxTokens: Int? {
        self == .dictationCleanup ? nil : 32_000
    }
}

/// The resolved model and endpoint a request goes to.
nonisolated struct LLMRequestTarget {
    let model: String
    let baseURL: String
    let apiKey: String
    let reasoning: SettingsStore.ModelReasoningConfig?
    let supportsTemperature: Bool
    let isReasoningModel: Bool
}

extension DictationProviderRoute {
    /// The provider and model Edit or Command Mode uses: a saved provider's address, a built-in
    /// provider's default address, or no address for anything else. The address is trimmed, as
    /// verification trims it.
    static func resolveChat(settings: SettingsStore, providerID: String, model: String) -> Self {
        let baseURL: String
        if let saved = settings.savedProviders.first(where: { $0.id == providerID }) {
            baseURL = saved.baseURL
        } else if ModelRepository.shared.isBuiltIn(providerID) {
            baseURL = ModelRepository.shared.defaultBaseURL(for: providerID)
        } else {
            baseURL = ""
        }
        return Self(
            providerID: providerID,
            providerKey: ModelRepository.shared.providerKey(for: providerID),
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model,
            apiKey: settings.getAPIKey(for: providerID) ?? ""
        )
    }

    /// The request for this route. Reasoning settings are looked up under the provider key
    /// ("custom:<id>" for a saved provider), the key the AI settings screen saves them under.
    func config(
        for purpose: LLMRequestPurpose,
        messages: [[String: Any]],
        settings: SettingsStore,
        streaming: Bool = false,
        tools: [[String: Any]] = [],
        benchmarkID: String? = nil
    ) -> LLMClient.Config {
        let reasoning = settings.getReasoningConfig(
            forModel: self.model,
            provider: ModelRepository.shared.providerKey(for: self.providerID)
        )
        let target = LLMRequestTarget(
            model: self.model,
            baseURL: self.baseURL,
            apiKey: self.apiKey,
            reasoning: reasoning,
            supportsTemperature: !settings.isTemperatureUnsupported(self.model, baseURL: self.baseURL),
            isReasoningModel: settings.isReasoningModel(self.model)
        )
        return Self.config(
            for: purpose,
            messages: messages,
            target: target,
            streaming: streaming,
            tools: tools,
            benchmarkID: benchmarkID
        )
    }

    /// Builds the request from values already resolved, for callers such as meeting summaries
    /// that resolve their provider before the request is made.
    nonisolated static func config(
        for purpose: LLMRequestPurpose,
        messages: [[String: Any]],
        target: LLMRequestTarget,
        streaming: Bool = false,
        tools: [[String: Any]] = [],
        benchmarkID: String? = nil
    ) -> LLMClient.Config {
        LLMClient.Config(
            messages: messages,
            model: target.model,
            baseURL: target.baseURL,
            apiKey: target.apiKey,
            streaming: streaming,
            tools: tools,
            temperature: target.supportsTemperature ? purpose.temperature : nil,
            maxTokens: target.isReasoningModel ? purpose.reasoningModelMaxTokens : nil,
            extraParameters: target.reasoning?.requestParameters ?? [:],
            benchmarkID: benchmarkID
        )
    }
}
