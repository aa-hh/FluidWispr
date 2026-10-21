//
//  SpeechProviderCache.swift
//  fluid
//
//  Builds the transcription provider for a speech model and keeps one instance per
//  provider kind until ASRService resets or releases it.
//

import Foundation

final class SpeechProviderCache {
    private(set) var fluidAudioProvider: FluidAudioProvider?
    private var parakeetRealtimeProvider: ParakeetRealtimeProvider?
    private var externalCoreMLProvider: ExternalCoreMLTranscriptionProvider?
    private var nemotronProviders: [NemotronProvider.Mode: NemotronProvider] = [:]
    private var whisperProvider: WhisperProvider?
    private var cachedAppleSpeechProvider: AppleSpeechProvider?
    /// Stored as Any? because @available cannot be applied to stored properties
    private var cachedAppleSpeechAnalyzerProvider: Any?

    /// The shared provider for `model`, created on first use.
    func provider(for model: SpeechModel) -> TranscriptionProvider {
        switch model {
        case .appleSpeechAnalyzer:
            if #available(macOS 26.0, *) {
                return self.appleSpeechAnalyzerProvider()
            } else {
                // Fallback to legacy Apple Speech on older macOS
                return self.appleSpeechProvider()
            }
        case .appleSpeech:
            return self.appleSpeechProvider()
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico:
            return self.getFluidAudioProvider()
        case .parakeetRealtime:
            return self.getParakeetRealtimeProvider()
        case .cohereTranscribeSixBit:
            return self.getExternalCoreMLProvider()
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return self.getNemotronProvider(mode: model.nemotronProviderMode)
        case .qwen3Asr:
            return self.getFluidAudioProvider()
        default:
            return self.getWhisperProvider()
        }
    }

    /// A new provider for `model` that is not cached, used to download or delete a model
    /// without touching the active one.
    static func makeStandaloneProvider(for model: SpeechModel, updateWeights: Bool = false) -> TranscriptionProvider {
        switch model {
        case .appleSpeechAnalyzer:
            if #available(macOS 26.0, *) {
                return AppleSpeechAnalyzerProvider()
            } else {
                return AppleSpeechProvider()
            }
        case .appleSpeech:
            return AppleSpeechProvider()
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico:
            // Create a new provider configured for the specific model
            return FluidAudioProvider(modelOverride: model, configureWordBoosting: false, updateCompactWeights: updateWeights)
        case .parakeetRealtime:
            return ParakeetRealtimeProvider()
        case .cohereTranscribeSixBit:
            return ExternalCoreMLTranscriptionProvider(modelOverride: model)
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return NemotronProvider(mode: model.nemotronProviderMode)
        case .qwen3Asr:
            // Qwen support removed; route legacy requests to Parakeet v3.
            return FluidAudioProvider(modelOverride: .parakeetTDT, configureWordBoosting: false)
        default:
            // Whisper models - create provider with specific model override
            return WhisperProvider(modelOverride: model)
        }
    }

    func cachedNemotronProvider(mode: NemotronProvider.Mode) -> NemotronProvider? {
        self.nemotronProviders[mode]
    }

    /// Drops every provider except Nemotron's, which keeps one instance per mode.
    func resetAfterModelChange() {
        self.fluidAudioProvider = nil
        self.parakeetRealtimeProvider = nil
        self.externalCoreMLProvider = nil
        self.whisperProvider = nil
        self.cachedAppleSpeechProvider = nil
        self.cachedAppleSpeechAnalyzerProvider = nil
    }

    func releaseAll() {
        self.resetAfterModelChange()
        self.nemotronProviders.removeAll()
    }

    func appleSpeechProvider() -> AppleSpeechProvider {
        if let existing = self.cachedAppleSpeechProvider {
            return existing
        }
        let provider = AppleSpeechProvider()
        self.cachedAppleSpeechProvider = provider
        DebugLogger.shared.info("ASRService: Created AppleSpeech provider", source: "ASRService")
        return provider
    }

    @available(macOS 26.0, *)
    func appleSpeechAnalyzerProvider() -> AppleSpeechAnalyzerProvider {
        if let existing = self.cachedAppleSpeechAnalyzerProvider as? AppleSpeechAnalyzerProvider {
            return existing
        }
        let provider = AppleSpeechAnalyzerProvider()
        self.cachedAppleSpeechAnalyzerProvider = provider
        DebugLogger.shared.info("ASRService: Created AppleSpeechAnalyzer provider", source: "ASRService")
        return provider
    }

    private func getFluidAudioProvider() -> FluidAudioProvider {
        if let existing = self.fluidAudioProvider {
            return existing
        }
        let provider = FluidAudioProvider(
            configureWordBoosting: SettingsStore.shared.vocabularyBoostingEnabled
        )
        self.fluidAudioProvider = provider
        DebugLogger.shared.info(
            "ASRService: Created FluidAudio provider [vocabBoosting=\(SettingsStore.shared.vocabularyBoostingEnabled)]",
            source: "ASRService"
        )
        return provider
    }

    private func getParakeetRealtimeProvider() -> ParakeetRealtimeProvider {
        if let existing = self.parakeetRealtimeProvider {
            return existing
        }
        let provider = ParakeetRealtimeProvider()
        self.parakeetRealtimeProvider = provider
        DebugLogger.shared.info("ASRService: Created Parakeet real-time provider", source: "ASRService")
        return provider
    }

    private func getExternalCoreMLProvider() -> ExternalCoreMLTranscriptionProvider {
        if let existing = self.externalCoreMLProvider {
            return existing
        }
        let provider = ExternalCoreMLTranscriptionProvider()
        self.externalCoreMLProvider = provider
        DebugLogger.shared.info("ASRService: Created external CoreML provider", source: "ASRService")
        return provider
    }

    private func getNemotronProvider(mode: NemotronProvider.Mode) -> NemotronProvider {
        if let existing = self.nemotronProviders[mode] { return existing }
        let provider = NemotronProvider(mode: mode)
        self.nemotronProviders[mode] = provider
        DebugLogger.shared.info("ASRService: Created \(provider.name) provider", source: "ASRService")
        return provider
    }

    private func getWhisperProvider() -> WhisperProvider {
        if let existing = self.whisperProvider {
            return existing
        }
        let provider = WhisperProvider()
        self.whisperProvider = provider
        DebugLogger.shared.info("ASRService: Created Whisper provider", source: "ASRService")
        return provider
    }
}
