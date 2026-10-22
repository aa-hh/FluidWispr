import Foundation

struct AITextProcessingResult {
    let text: String
    let tokensPerSecond: Double?
    let fluidIntelligenceLatencyMilliseconds: Int?
}

/// AI cleanup of a finished dictation: the system prompt, the provider call, the cloud
/// time budget and its local fallback.
extension DictationSession {
    func processTextWithAI(
        _ inputText: String,
        overrideSystemPrompt: String? = nil,
        overrideProviderID: String? = nil,
        overrideModel: String? = nil,
        dictationSlot: SettingsStore.DictationShortcutSlot? = nil,
        streamHandler: PrivateAIStreamHandler? = nil,
        benchmarkID: String? = nil
    ) async throws -> String {
        try await self.processTextWithAIMetrics(
            inputText,
            overrideSystemPrompt: overrideSystemPrompt,
            overrideProviderID: overrideProviderID,
            overrideModel: overrideModel,
            dictationSlot: dictationSlot,
            streamHandler: streamHandler,
            benchmarkID: benchmarkID
        ).text
    }

    /// Runs dictation cleanup inside its latency budget. Cerebras gets the cloud
    /// budget; local, on-device and other providers get the general one. When
    /// a cloud provider can't be reached, the local Ollama model gets whatever is
    /// left of the general budget, measured from the start of cleanup.
    func cleanUpDictationWithinBudget(
        route: DictationProviderRoute,
        enforcesBudget: Bool,
        primary: @escaping @Sendable () async throws -> AITextProcessingResult,
        localFallback: @escaping @Sendable (String) async throws -> AITextProcessingResult
    ) async throws -> AITextProcessingResult {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let isOnDevice = route.usesPrivateAI || self.isLocalEndpoint(route.baseURL)
        let generalBudget = enforcesBudget ? SettingsStore.shared.dictationCleanupBudgetMilliseconds : 0
        let primaryBudget = enforcesBudget && !isOnDevice && DictationCleanupRouting.usesCloudBudget(providerKey: route.providerKey)
            ? SettingsStore.shared.dictationCloudCleanupBudgetMilliseconds
            : generalBudget
        do {
            return try await LatencyBudget.run(milliseconds: primaryBudget, operation: primary)
        } catch let cloudError {
            let localModel = (SettingsStore.shared.selectedModelByProvider[DictationCleanupRouting.localFallbackProviderID] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let elapsedMilliseconds = Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded())
            let remainingMilliseconds = generalBudget - elapsedMilliseconds
            guard enforcesBudget, !isOnDevice, !localModel.isEmpty, remainingMilliseconds > 0,
                  DictationCleanupRouting.shouldRetryLocally(after: cloudError)
            else {
                throw cloudError
            }
            self.appBench("ai_local_fallback_start provider=\(route.providerKey) remainingMs=\(remainingMilliseconds)")
            DebugLogger.shared.warning(
                "Cloud cleanup failed, retrying on local \(localModel): \(cloudError.localizedDescription)",
                source: "DictationSession"
            )
            do {
                return try await LatencyBudget.run(milliseconds: remainingMilliseconds) {
                    try await localFallback(localModel)
                }
            } catch {
                // Report the cloud error: it names the problem to fix, such as no internet or a missing API key.
                DebugLogger.shared.warning("Local cleanup fallback failed: \(error.localizedDescription)", source: "DictationSession")
                throw cloudError
            }
        }
    }

    func processTextWithAIMetrics(
        _ inputText: String,
        overrideSystemPrompt: String? = nil,
        overrideProviderID: String? = nil,
        overrideModel: String? = nil,
        dictationSlot: SettingsStore.DictationShortcutSlot? = nil,
        streamHandler: PrivateAIStreamHandler? = nil,
        benchmarkID: String? = nil,
        stopSnapshot: DictationStopSnapshot? = nil,
        contextSnapshot: DictationStopSnapshot? = nil
    ) async throws -> AITextProcessingResult {
        guard let summaryActivity = MeetingSummaryActivityCoordinator.shared.beginProcessing() else {
            throw MeetingModelResidencyError.busy
        }
        defer { MeetingSummaryActivityCoordinator.shared.endProcessing(summaryActivity) }

        let routeStartedAt = ProcessInfo.processInfo.systemUptime
        // contextSnapshot says where the user is dictating without supplying a
        // route, for the local fallback that runs on a different provider.
        let contextSource = stopSnapshot ?? contextSnapshot
        let appInfo = contextSource?.appInfo ?? self.recordingAppInfo ?? self.getCurrentAppInfo()
        let route: DictationProviderRoute
        if let stopSnapshot {
            route = stopSnapshot.route
        } else if let overrideProviderID, let overrideModel {
            route = DictationProviderRoute.resolve(
                settings: SettingsStore.shared,
                providerID: overrideProviderID,
                model: overrideModel
            )
        } else {
            route = DictationProviderRoute.resolve(
                settings: SettingsStore.shared,
                dictationSlot: dictationSlot,
                appBundleID: appInfo.bundleId
            )
        }
        self.appBench(
            "ai_route_resolved elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - routeStartedAt) * 1000).rounded()))"
        )
        let currentSelectedProviderID = route.providerID
        let derivedCurrentProvider = route.providerKey
        let derivedBaseURL = route.baseURL
        let derivedSelectedModel = route.model

        guard !derivedCurrentProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProcessingError.noVerifiedProvider
        }
        if derivedSelectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIProcessingError.missingModel(provider: derivedCurrentProvider)
        }

        DebugLogger.shared.debug("processTextWithAI using provider=\(derivedCurrentProvider), model=\(derivedSelectedModel)", source: "DictationSession")

        let isDictationCall = overrideSystemPrompt != nil || dictationSlot != nil
        let isPrivateAIProvider = route.usesPrivateAI
        let usePrivateAIProvider = !(stopSnapshot?.hasCustomPrompt ?? (overrideSystemPrompt != nil)) &&
            isDictationCall &&
            (isPrivateAIProvider || PrivateAIIntegrationService.shouldHandleDictation(model: derivedSelectedModel))

        if usePrivateAIProvider {
            if self.shouldTracePromptProcessing {
                self.logDictationPromptTrace("Private AI Provider task", value: "dictationEnhancement")
                self.logDictationPromptTrace("Input transcription (Q)", value: inputText)
                self.logDictationPromptTrace("Selected context text", value: "<none (dictation mode)>")
            }

            self.appBench("ai_private_call")
            let fluidIntelligenceStartedAt = ProcessInfo.processInfo.systemUptime
            let response = try await PrivateAIIntegrationService.shared.enhanceDictation(
                inputText,
                runtime: PrivateAIIntegrationService.RuntimeConfiguration(
                    selectedProviderID: currentSelectedProviderID,
                    providerKey: derivedCurrentProvider,
                    baseURL: derivedBaseURL,
                    model: derivedSelectedModel,
                    apiKey: route.apiKey,
                    localModelPath: PrivateAIIntegrationService.configuredLocalModelPath,
                    usesStablePromptPrefixKVCache: SettingsStore.shared.privateAIPrefixKVCacheEnabled,
                    usesFluid1Boost: SettingsStore.shared.privateAIBoostEnabled,
                    contextTokenLimit: SettingsStore.shared.privateAIContextTokenLimit
                ),
                context: PrivateAIIntegrationService.AppContext(
                    appName: appInfo.name,
                    bundleID: appInfo.bundleId,
                    windowTitle: appInfo.windowTitle,
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                ),
                streamHandler: streamHandler
            )
            self.appBench("ai_private_return")
            SettingsStore.shared.recordFluidIntelligenceUse(output: response.outputText)

            if self.shouldTracePromptProcessing {
                self.logDictationPromptTrace("Model answer (A)", value: response.outputText)
            }
            let tokensPerSecond = response.tokensPerSecond.flatMap { value in
                value.isFinite && value > 0 ? value : nil
            }
            let fluidIntelligenceLatencyMilliseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - fluidIntelligenceStartedAt) * 1000).rounded()
            )
            return AITextProcessingResult(
                text: response.outputText,
                tokensPerSecond: tokensPerSecond,
                fluidIntelligenceLatencyMilliseconds: fluidIntelligenceLatencyMilliseconds
            )
        }

        // Resolve the effective prompt once so every provider path honors
        // transient overrides such as "Transcribe with Prompt".
        let promptText: String = {
            if let stopSnapshot { return stopSnapshot.systemPrompt }
            if let overrideSystemPrompt { return overrideSystemPrompt }
            return self.buildSystemPrompt(appInfo: appInfo, dictationSlot: dictationSlot)
        }()

        // Local endpoints get cleanup context by default. They, and a remote provider verified
        // without a key, skip the API key check below.
        let isLocal = self.isLocalEndpoint(derivedBaseURL)
        let sendsCleanupContext = isDictationCall && SettingsStore.shared.dictationCleanupContextEnabled &&
            (isLocal || SettingsStore.shared.dictationCloudCleanupContextEnabled)
        // A snapshot's preceding text is authoritative: it is empty on purpose
        // when focus moved to a different field.
        let cleanupContext = sendsCleanupContext
            ? DictationPromptContext(
                app: appInfo.name == "Unknown" ? nil : appInfo.name,
                windowTitle: appInfo.windowTitle,
                textBeforeCursor: contextSource?.precedingText ?? self.recordingPrecedingText
            )
            : nil
        // Keep cleanup instructions separate from transcript data. Explicit
        // ${transcript} templates retain their authored single-turn layout.
        let request = isDictationCall
            ? DictationPromptRequest(
                promptText: promptText,
                transcript: inputText,
                context: cleanupContext,
                contextEnabled: sendsCleanupContext
            )
            : DictationPromptRequest(systemPrompt: promptText, userContent: inputText)
        let systemPrompt = request.systemPrompt
        let userMessageContent = request.userContent
        let apiKey = route.apiKey

        // A remote provider verified without a key, such as a keyless gateway, may send without one.
        if !isLocal, apiKey.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty,
           !DictationAIPostProcessingGate.isVerified(route: route, settings: SettingsStore.shared)
        {
            throw AIProcessingError.missingAPIKey(provider: derivedCurrentProvider)
        }

        DebugLogger.shared.debug("Using app context for AI: app=\(appInfo.name), bundleId=\(appInfo.bundleId), title=\(appInfo.windowTitle)", source: "DictationSession")
        if self.shouldTracePromptProcessing {
            let activeSlot = dictationSlot ?? self.currentDictationShortcutSlot(for: self.activeRecordingMode) ?? .primary
            let selectedProfile = SettingsStore.shared.resolvedDictationPromptProfile(
                for: activeSlot,
                appBundleID: appInfo.bundleId
            )
            let selectedPromptName: String = {
                if SettingsStore.shared.dictationPromptSelection(for: activeSlot) == .off {
                    return "Off"
                }
                if let profile = selectedProfile {
                    return profile.name.isEmpty ? "Untitled Prompt" : profile.name
                }
                return "Default"
            }()
            self.logDictationPromptTrace("Selected prompt profile", value: selectedPromptName)
            self.logDictationPromptTrace(
                "Prompt body (custom/default body)",
                value: SettingsStore.shared.effectiveDictationPromptBody(for: activeSlot, appBundleID: appInfo.bundleId)
            )
            self.logDictationPromptTrace("Built-in default system prompt (baseline)", value: SettingsStore.defaultSystemPromptText(for: .dictate))
            self.logDictationPromptTrace("Prompt override in use", value: (overrideSystemPrompt?.isEmpty == false) ? "yes" : "no")
            if let overrideSystemPrompt, !overrideSystemPrompt.isEmpty {
                self.logDictationPromptTrace("Override system prompt", value: overrideSystemPrompt)
            }
            self.logDictationPromptTrace("Final system prompt sent to model", value: systemPrompt)
            self.logDictationPromptTrace("Input transcription (Q)", value: inputText)
            if userMessageContent != inputText {
                self.logDictationPromptTrace("Final user message sent to model", value: userMessageContent)
            }
            self.logDictationPromptTrace("Selected context text", value: cleanupContext?.isEmpty == false ? "<sent in user message>" : "<none (dictation mode)>")
        }

        let messages = request.messages
        let enableStreaming = streamHandler != nil && (!isDictationCall || DictationCleanupRouting.streamsCleanup(
            providerKey: derivedCurrentProvider,
            isLocal: isLocal,
            cloudBudgetMilliseconds: SettingsStore.shared.dictationCloudCleanupBudgetMilliseconds
        ))
        var config = route.config(
            for: .dictationCleanup,
            messages: messages,
            settings: SettingsStore.shared,
            streaming: enableStreaming,
            benchmarkID: benchmarkID
        )
        if enableStreaming {
            config.onContentChunk = { chunk in
                streamHandler?(chunk)
            }
        }

        DebugLogger.shared.info("Using LLMClient for transcription (streaming=\(enableStreaming))", source: "DictationSession")

        let response: LLMClient.Response
        if enableStreaming {
            do {
                response = try await LLMClient.shared.call(config)
            } catch {
                guard DictationStreamingFallbackPolicy.shouldRetryWithoutStreaming(after: error) else {
                    self.appBench("ai_streaming_fallback_skipped reason=transport_or_cancel")
                    throw error
                }
                self.appBench("ai_streaming_fallback_start")
                DebugLogger.shared.warning(
                    "Streaming dictation post-processing failed; retrying without streaming: \(error.localizedDescription)",
                    source: "DictationSession"
                )
                let fallbackConfig = route.config(
                    for: .dictationCleanup,
                    messages: messages,
                    settings: SettingsStore.shared,
                    benchmarkID: benchmarkID
                )
                response = try await LLMClient.shared.call(fallbackConfig)
            }
        } else {
            response = try await LLMClient.shared.call(config)
        }

        // Log thinking if present (for debugging)
        if let thinking = response.thinking {
            DebugLogger.shared.debug("LLM thinking tokens extracted (\(thinking.count) chars)", source: "DictationSession")
            if self.shouldTracePromptProcessing {
                self.logDictationPromptTrace("Model thinking", value: thinking)
            }
        }

        if self.shouldTracePromptProcessing {
            self.logDictationPromptTrace("Model answer (A)", value: response.content)
        }

        guard !response.content.isEmpty else {
            throw AIProcessingError.emptyResponse
        }
        return AITextProcessingResult(
            text: response.content,
            tokensPerSecond: nil,
            fluidIntelligenceLatencyMilliseconds: nil
        )
    }

    func buildSystemPrompt(
        appInfo: (name: String, bundleId: String, windowTitle: String),
        dictationSlot: SettingsStore.DictationShortcutSlot? = nil
    ) -> String {
        if let slot = dictationSlot ?? self.currentDictationShortcutSlot(for: self.activeRecordingMode) {
            return SettingsStore.shared.effectiveDictationSystemPrompt(for: slot, appBundleID: appInfo.bundleId)
        }
        return SettingsStore.shared.effectiveSystemPrompt(for: .dictate, appBundleID: appInfo.bundleId)
    }

    var shouldTracePromptProcessing: Bool {
        self.forcePromptTraceToConsole ||
            UserDefaults.standard.bool(forKey: "EnableDebugLogs")
    }

    var forcePromptTraceToConsole: Bool {
        ProcessInfo.processInfo.environment["FLUID_PROMPT_TRACE"] == "1"
    }

    func logDictationPromptTrace(_ title: String, value: String) {
        let line = "[PromptTrace][Dictate] \(title):\n\(value)"
        if self.forcePromptTraceToConsole {
            print(line)
        }
        DebugLogger.shared.debug(line, source: "DictationSession")
    }

    func isLocalEndpoint(_ urlString: String) -> Bool {
        ModelRepository.shared.isLocalEndpoint(urlString)
    }

    func currentDictationShortcutSlot(for mode: RecordingMode) -> SettingsStore.DictationShortcutSlot? {
        switch mode {
        case .dictate:
            return self.activeDictationShortcutSlot ?? .primary
        case .promptMode:
            return self.activeDictationShortcutSlot ?? .secondary
        case .none, .edit, .command:
            return nil
        }
    }

    func benchmarkLoadAverage() -> String {
        var loadAverages = [Double](repeating: 0, count: 3)
        let loadSampleCount = getloadavg(&loadAverages, 3)
        return loadSampleCount > 0 ? String(format: "%.1f", loadAverages[0]) : "nil"
    }

    func logAIProcessCall(
        _ pipelineID: String,
        _ modelInfo: (provider: String?, model: String?),
        _ inputChars: Int
    ) {
        let provider = (modelInfo.provider ?? "unknown").replacingOccurrences(of: " ", with: "_")
        let model = (modelInfo.model ?? "unknown").replacingOccurrences(of: " ", with: "_")
        self.appBench(
            "ai_process_call id=\(pipelineID) provider=\(provider) model=\(model) inputChars=\(inputChars)"
        )
    }
}
