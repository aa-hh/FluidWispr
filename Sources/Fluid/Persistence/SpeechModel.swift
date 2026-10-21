//
//  SpeechModel.swift
//  fluid
//
//  Speech model catalog: every model the app can run, its provider, and its download state.
//

import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Unified speech recognition model selection.
/// Replaces the old TranscriptionProviderOption + WhisperModelSize dual-setting.
enum SpeechModel: String, CaseIterable, Identifiable, Codable {
    /// Temporarily disabled in UI/runtime while Parakeet word boosting work is prioritized.
    /// Flip to `true` in a future round to re-enable Qwen without deleting implementation.
    static let qwenPreviewEnabled = false

    // MARK: - FluidAudio Models (Apple Silicon Only)

    case parakeetTDT = "parakeet-tdt"
    case parakeetTDTv2 = "parakeet-tdt-v2"
    case fluidParakeetMini = "fluid-parakeet-mini"
    case fluidParakeetPico = "fluid-parakeet-pico"
    case parakeetRealtime = "parakeet-realtime"
    case qwen3Asr = "qwen3-asr"
    case cohereTranscribeSixBit = "cohere-transcribe-6bit"
    case nemotronOffline = "nemotron-3.5-offline"
    case nemotronStreaming = "nemotron-3.5-streaming"
    case nemotronStreaming320 = "nemotron-3.5-streaming-320"

    // MARK: - Apple Native

    case appleSpeech = "apple-speech"
    case appleSpeechAnalyzer = "apple-speech-analyzer"

    // MARK: - Whisper Models (Universal)

    case whisperTiny = "whisper-tiny"
    case whisperBase = "whisper-base"
    case whisperSmall = "whisper-small"
    case whisperMedium = "whisper-medium"
    case whisperLargeTurbo = "whisper-large-turbo"
    case whisperLarge = "whisper-large"

    var parakeetDescriptor: ParakeetSpeechModelCatalog.Descriptor? {
        ParakeetSpeechModelCatalog.descriptor(forModelID: self.rawValue)
    }

    /// Relative product ratings for display and sorting, not benchmark accuracy.
    var hasPerformanceRatings: Bool {
        guard let descriptor = self.parakeetDescriptor else { return true }
        return descriptor.performanceRatings != nil
    }

    var id: String {
        rawValue
    }

    // MARK: - Display Properties

    var displayName: String {
        switch self {
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico: return self.parakeetDescriptor?.displayName ?? self.rawValue
        case .parakeetRealtime: return "Parakeet Flash (Beta)"
        case .qwen3Asr: return "Qwen3 ASR (Beta)"
        case .cohereTranscribeSixBit: return "Cohere Transcribe"
        case .nemotronOffline: return "Nemotron 3.5 Multilingual"
        case .nemotronStreaming: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
        case .nemotronStreaming320: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
        case .appleSpeech: return "Apple ASR Legacy"
        case .appleSpeechAnalyzer: return "Apple Speech - macOS 26+"
        case .whisperTiny: return "Whisper Tiny"
        case .whisperBase: return "Whisper Base"
        case .whisperSmall: return "Whisper Small"
        case .whisperMedium: return "Whisper Medium"
        case .whisperLargeTurbo: return "Whisper Large Turbo"
        case .whisperLarge: return "Whisper Large"
        }
    }

    var languageSupport: String {
        switch self {
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico: return self.parakeetDescriptor?.languageSupport ?? "English Only"
        case .parakeetRealtime: return "English Only (Live Streaming)"
        case .qwen3Asr: return "30 Languages"
        case .cohereTranscribeSixBit: return "14 Languages (Select Manually)"
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320: return "Around 40 Languages"
        case .appleSpeech: return "System Languages"
        case .appleSpeechAnalyzer: return "EN, ES, FR, DE, IT, JA, KO, PT, ZH"
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
            return "99 Languages"
        }
    }

    var downloadSize: String {
        switch self {
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico: return self.parakeetDescriptor?.downloadSize ?? ""
        case .parakeetRealtime: return "~428.4 MiB"
        case .qwen3Asr: return "~2.0 GiB"
        case .cohereTranscribeSixBit: return "~1.54 GiB"
        case .nemotronOffline: return "~530.8 MiB"
        case .nemotronStreaming: return "~668.2 MiB"
        case .nemotronStreaming320: return "~668.2 MiB"
        case .appleSpeech: return "Built-in"
        case .appleSpeechAnalyzer: return "Built-in"
        case .whisperTiny: return "~43.9 MiB"
        case .whisperBase: return "~81.0 MiB"
        case .whisperSmall: return "~257.3 MiB"
        case .whisperMedium: return "~793.0 MiB"
        case .whisperLargeTurbo: return "~845.3 MiB"
        case .whisperLarge: return "~1.55 GiB"
        }
    }

    var expectedDownloadBytes: Int64 {
        switch self {
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico: return self.parakeetDescriptor?.expectedDownloadBytes ?? 0
        case .parakeetRealtime: return 449_190_189
        case .qwen3Asr: return 2000 * 1024 * 1024
        case .cohereTranscribeSixBit: return 1_650_748_785
        case .nemotronOffline: return 556_552_620
        case .nemotronStreaming, .nemotronStreaming320: return 700_685_415
        case .whisperTiny: return 45_981_088
        case .whisperBase: return 84_962_880
        case .whisperSmall: return 269_751_136
        case .whisperMedium: return 831_538_144
        case .whisperLargeTurbo: return 886_381_760
        case .whisperLarge: return 1_668_741_440
        case .appleSpeech, .appleSpeechAnalyzer: return 0
        }
    }

    var requiresAppleSilicon: Bool {
        switch self {
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .parakeetRealtime, .qwen3Asr, .cohereTranscribeSixBit, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320: return true
        default: return false
        }
    }

    var isWhisperModel: Bool {
        switch self {
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .parakeetRealtime, .qwen3Asr, .cohereTranscribeSixBit, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320, .appleSpeech,
             .appleSpeechAnalyzer: return false
        default: return true
        }
    }

    /// The GGUF filename for transcribe.cpp Whisper models.
    var whisperModelFile: String? {
        switch self {
        case .whisperTiny: return "whisper-tiny-Q8_0.gguf"
        case .whisperBase: return "whisper-base-Q8_0.gguf"
        case .whisperSmall: return "whisper-small-Q8_0.gguf"
        case .whisperMedium: return "whisper-medium-Q8_0.gguf"
        case .whisperLargeTurbo: return "whisper-large-v3-turbo-Q8_0.gguf"
        case .whisperLarge: return "whisper-large-v3-Q8_0.gguf"
        default: return nil
        }
    }

    var legacyWhisperModelFile: String? {
        switch self {
        case .whisperTiny: return "ggml-tiny.bin"
        case .whisperBase: return "ggml-base.bin"
        case .whisperSmall: return "ggml-small.bin"
        case .whisperMedium: return "ggml-medium.bin"
        case .whisperLargeTurbo: return "ggml-large-v3-turbo.bin"
        case .whisperLarge: return "ggml-large-v3.bin"
        default: return nil
        }
    }

    static let legacyWhisperModelFiles: Set<String> = [
        "ggml-tiny.bin",
        "ggml-base.bin",
        "ggml-small.bin",
        "ggml-medium.bin",
        "ggml-large-v3-turbo.bin",
        "ggml-large-v3.bin",
    ]

    /// The short model name for whisper.cpp internal usage
    var whisperModelName: String? {
        switch self {
        case .whisperTiny: return "tiny"
        case .whisperBase: return "base"
        case .whisperSmall: return "small"
        case .whisperMedium: return "medium"
        case .whisperLargeTurbo: return "large-v3-turbo"
        case .whisperLarge: return "large-v3"
        default: return nil
        }
    }

    // MARK: - Architecture Filtering

    /// Requires macOS 26 (Tahoe) or later
    var requiresMacOS26: Bool {
        switch self {
        case .appleSpeechAnalyzer: return true
        default: return false
        }
    }

    /// Requires macOS 15 or later.
    var requiresMacOS15: Bool {
        switch self {
        case .fluidParakeetMini, .fluidParakeetPico, .qwen3Asr, .cohereTranscribeSixBit: return true
        default: return false
        }
    }

    /// Returns models available for the current Mac's architecture and OS
    static var availableModels: [SpeechModel] {
        allCases.filter { model in
            if model == .whisperLargeTurbo, !CPUArchitecture.isAppleSilicon {
                return false
            }
            if model == .whisperLarge, !CPUArchitecture.isAppleSilicon {
                return false
            }
            if model == .qwen3Asr, !Self.qwenPreviewEnabled {
                return false
            }
            if model == .nemotronStreaming320 {
                return false
            }
            // Filter by Apple Silicon requirement
            if model.requiresAppleSilicon, !CPUArchitecture.isAppleSilicon {
                return false
            }
            // Filter by macOS 15 requirement
            if model.requiresMacOS15, #unavailable(macOS 15.0) {
                return false
            }
            // Filter by macOS 26 requirement
            if model.requiresMacOS26 {
                if #available(macOS 26.0, *) {
                    return true
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// Default model for the current architecture
    static var defaultModel: SpeechModel {
        CPUArchitecture.isAppleSilicon ? .parakeetTDT : .whisperBase
    }

    // MARK: - UI Card Metadata

    /// Human-readable marketing name for the card UI
    var humanReadableName: String {
        switch self {
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico: return self.parakeetDescriptor?.humanReadableName ?? self.rawValue
        case .parakeetRealtime: return "Flash Dictation"
        case .qwen3Asr: return "Qwen3 - Multilingual"
        case .cohereTranscribeSixBit: return "Cohere - High Accuracy"
        case .nemotronOffline: return "Nemotron 3.5 Multilingual"
        case .nemotronStreaming: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
        case .nemotronStreaming320: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
        case .appleSpeech: return "Apple ASR Legacy"
        case .appleSpeechAnalyzer: return "Apple Speech - macOS 26+"
        case .whisperTiny: return "Fast & Light"
        case .whisperBase: return "Standard Choice"
        case .whisperSmall: return "Balanced Speed & Accuracy"
        case .whisperMedium: return "Medium Quality"
        case .whisperLargeTurbo: return "Higher Quality but Faster"
        case .whisperLarge: return "Maximum Accuracy"
        }
    }

    /// One-line description for the card UI
    var cardDescription: String {
        switch self {
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico:
            return self.parakeetDescriptor?.cardDescription ?? ""
        case .parakeetRealtime:
            return "English-only streaming local dictation with low-latency partial text and end-of-utterance detection."
        case .qwen3Asr:
            return "Qwen3 multilingual ASR via FluidAudio. Higher quality, heavier memory footprint."
        case .cohereTranscribeSixBit:
            return "High-accuracy multilingual transcription. Select the language manually before dictation for best results."
        case .nemotronOffline:
            return "Slower but more accurate NVIDIA Nemotron 3.5 transcription. Supports 40 language-locales with auto or manual language selection."
        case .nemotronStreaming:
            return "NVIDIA Nemotron 3.5 streaming-capable transcription. Supports 40 language-locales with auto or manual language selection."
        case .nemotronStreaming320:
            return "NVIDIA Nemotron 3.5 streaming-capable transcription. Supports 40 language-locales with auto or manual language selection."
        case .appleSpeech:
            return "Built-in macOS speech recognition. No model download required."
        case .appleSpeechAnalyzer:
            return "Advanced and modern on-device recognition for newer macOS devices."
        case .whisperTiny:
            return "Minimal resource usage. Best for older Macs or battery life."
        case .whisperBase:
            return "Good balance of speed and accuracy. Works on any Mac."
        case .whisperSmall:
            return "Better accuracy than Base. Moderate resource usage."
        case .whisperMedium:
            return "High accuracy for demanding tasks. Requires more memory."
        case .whisperLargeTurbo:
            return "Near-maximum accuracy with optimized speed."
        case .whisperLarge:
            return "Best possible accuracy. Large download and memory usage."
        }
    }

    /// Minimum recommended RAM in GB for this model to run safely
    var requiredMemoryGB: Double {
        switch self {
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .parakeetRealtime:
            return 4.0
        case .qwen3Asr:
            return 8.0
        case .cohereTranscribeSixBit:
            return 8.0
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return 8.0
        case .appleSpeech, .appleSpeechAnalyzer:
            return 2.0 // Built-in, minimal overhead
        case .whisperTiny:
            return 2.0
        case .whisperBase:
            return 3.0
        case .whisperSmall:
            return 4.0
        case .whisperMedium:
            return 5.0
        case .whisperLargeTurbo:
            return 6.0
        case .whisperLarge:
            return 8.0
        }
    }

    /// Warning text for models with high memory requirements, nil if no warning needed
    var memoryWarning: String? {
        switch self {
        case .qwen3Asr:
            return "⚠️ Requires 8GB+ RAM. Best on newer Apple Silicon Macs."
        case .whisperLarge:
            return "⚠️ Requires 10GB+ RAM. May crash on systems with limited memory."
        case .whisperLargeTurbo:
            return "⚠️ Requires 8GB+ RAM. May be unstable on some systems."
        case .whisperMedium:
            return "Requires 6GB+ RAM for stable operation."
        default:
            return nil
        }
    }

    /// Speed rating (1-5, higher is faster)
    var speedRating: Int {
        switch self {
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico: return self.parakeetDescriptor?.performanceRatings?.speedRating ?? 0
        case .parakeetRealtime: return 5
        case .qwen3Asr: return 3
        case .cohereTranscribeSixBit: return 3
        case .nemotronOffline: return 3
        case .nemotronStreaming, .nemotronStreaming320: return 4
        case .appleSpeech: return 4
        case .appleSpeechAnalyzer: return 4
        case .whisperTiny: return 4
        case .whisperBase: return 4
        case .whisperSmall: return 3
        case .whisperMedium: return 2
        case .whisperLargeTurbo: return 3
        case .whisperLarge: return 1
        }
    }

    /// Accuracy rating (1-5, higher is more accurate)
    var accuracyRating: Int {
        switch self {
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico: return self.parakeetDescriptor?.performanceRatings?.accuracyRating ?? 0
        case .parakeetRealtime: return 4
        case .qwen3Asr: return 4
        case .cohereTranscribeSixBit: return 5
        case .nemotronOffline: return 5
        case .nemotronStreaming, .nemotronStreaming320: return 4
        case .appleSpeech: return 4
        case .appleSpeechAnalyzer: return 4
        case .whisperTiny: return 2
        case .whisperBase: return 3
        case .whisperSmall: return 4
        case .whisperMedium: return 4
        case .whisperLargeTurbo: return 5
        case .whisperLarge: return 5
        }
    }

    /// Exact speed percentage (0.0 - 1.0) for the liquid bars
    var speedPercent: Double {
        switch self {
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico: return self.parakeetDescriptor?.performanceRatings?.speedPercent ?? 0
        case .parakeetRealtime: return 1.0
        case .qwen3Asr: return 0.45
        case .cohereTranscribeSixBit: return 0.85
        case .nemotronOffline: return 0.85
        case .nemotronStreaming, .nemotronStreaming320: return 1.0
        case .appleSpeech: return 0.60
        case .appleSpeechAnalyzer: return 0.85
        case .whisperTiny: return 0.90
        case .whisperBase: return 0.80
        case .whisperSmall: return 0.60
        case .whisperMedium: return 0.40
        case .whisperLargeTurbo: return 0.65
        case .whisperLarge: return 0.20
        }
    }

    /// Exact accuracy percentage (0.0 - 1.0) for the liquid bars
    var accuracyPercent: Double {
        switch self {
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico: return self.parakeetDescriptor?.performanceRatings?.accuracyPercent ?? 0
        case .parakeetRealtime: return 0.75
        case .qwen3Asr: return 0.90
        case .cohereTranscribeSixBit: return 0.98
        case .nemotronOffline: return 0.90
        case .nemotronStreaming, .nemotronStreaming320: return 0.85
        case .appleSpeech: return 0.60
        case .appleSpeechAnalyzer: return 0.80
        case .whisperTiny: return 0.40
        case .whisperBase: return 0.60
        case .whisperSmall: return 0.70
        case .whisperMedium: return 0.80
        case .whisperLargeTurbo: return 0.95
        case .whisperLarge: return 1.00
        }
    }

    /// Optional badge text for the card (e.g., "FluidVoice Pick")
    var badgeText: String? {
        switch self {
        case .parakeetTDT: return "FluidVoice Pick"
        case .parakeetTDTv2: return "FluidVoice Pick"
        case .fluidParakeetMini, .fluidParakeetPico: return "New"
        case .parakeetRealtime: return "Beta"
        case .qwen3Asr: return "Beta"
        case .cohereTranscribeSixBit: return "New"
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320: return "New + Beta"
        case .appleSpeechAnalyzer: return "New"
        default: return nil
        }
    }

    /// Optimization level for Apple Silicon (for display)
    var appleSiliconOptimized: Bool {
        switch self {
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .parakeetRealtime, .qwen3Asr, .cohereTranscribeSixBit, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320, .appleSpeechAnalyzer:
            return true
        default:
            return false
        }
    }

    /// Whether this model supports real-time streaming/chunk processing.
    /// Large Whisper models are too slow for streaming, so they only do final transcription on stop.
    var supportsStreaming: Bool {
        switch self {
        case .qwen3Asr, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
            return false // Too slow for real-time chunk processing
        default:
            return true // All other models support streaming
        }
    }

    var supportsPronunciationMatching: Bool {
        #if arch(arm64)
        switch self {
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico:
            return true
        default:
            return false
        }
        #else
        return false
        #endif
    }

    /// Streaming engines feed each live-preview pass into the state their final pass finishes,
    /// so skipping those passes moves the work to key-up.
    var finalPassContinuesLivePreview: Bool {
        switch self {
        case .parakeetRealtime, .nemotronStreaming, .nemotronStreaming320:
            return true
        default:
            return false
        }
    }

    /// Preview update cadence for real-time transcription.
    /// Models without native incremental decoding should use a slower interval.
    var streamingPreviewIntervalSeconds: Double {
        switch self {
        case .parakeetRealtime:
            return 0.2
        case .nemotronStreaming, .nemotronStreaming320:
            return 0.32
        case .cohereTranscribeSixBit:
            return 1.0
        default:
            return 0.6
        }
    }

    /// Minimum audio required before attempting a preview decode.
    /// Cohere performs better with a slightly larger prefix than the default 1 second.
    var minimumStreamingPreviewSeconds: Double {
        switch self {
        case .parakeetRealtime:
            return 0.2
        case .nemotronStreaming, .nemotronStreaming320:
            return 0.64
        case .cohereTranscribeSixBit:
            return 1.5
        default:
            return 1.0
        }
    }

    /// Provider category for tab grouping
    enum Provider: String, CaseIterable {
        case nvidia = "NVIDIA"
        case apple = "Apple"
        case openai = "OpenAI"
        case qwen = "Qwen"
        case cohere = "Cohere"
    }

    /// Which provider this model belongs to
    var provider: Provider {
        switch self {
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .parakeetRealtime, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return .nvidia
        case .appleSpeech, .appleSpeechAnalyzer:
            return .apple
        case .qwen3Asr:
            return .qwen
        case .cohereTranscribeSixBit:
            return .cohere
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
            return .openai
        }
    }

    /// Get models filtered by provider
    static func models(for provider: Provider) -> [SpeechModel] {
        self.availableModels.filter { $0.provider == provider }
    }

    /// Whether this model is built-in or already downloaded on disk
    var isInstalled: Bool {
        switch self {
        case .appleSpeech, .appleSpeechAnalyzer:
            return true
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico:
            #if canImport(FluidAudio)
            guard let descriptor = self.parakeetDescriptor else { return false }
            return Self.parakeetModelsExist(descriptor: descriptor)
            #else
            return false
            #endif
        case .parakeetRealtime:
            #if canImport(FluidAudio)
            return Self.parakeetRealtimeModelsExist()
            #else
            return false
            #endif
        case .qwen3Asr:
            #if canImport(FluidAudio) && ENABLE_QWEN
            if #available(macOS 15.0, *) {
                return Qwen3AsrModels.modelsExist(at: Qwen3AsrModels.defaultCacheDirectory())
            }
            return false
            #else
            return false
            #endif
        case .cohereTranscribeSixBit:
            guard
                let spec = self.externalCoreMLSpec,
                let directory = SettingsStore.shared.externalCoreMLArtifactsDirectory(for: self)
            else {
                return false
            }
            return spec.validatesInstalledArtifacts(at: directory)
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            let hint: String
            switch self {
            case .nemotronOffline:
                hint = "nemotron-3.5-asr-offline-6bit-CoreML"
            default:
                hint = "nemotron-3.5-asr-streaming320-int8-CoreML"
            }
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent(hint, isDirectory: true)
            #if arch(arm64)
            return directory.map { NemotronProvider.artifactsAreComplete(at: $0) } ?? false
            #else
            return false
            #endif
        default:
            // Whisper models
            guard let whisperFile = self.whisperModelFile else { return false }
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("WhisperModels")
            let modelURL = directory?.appendingPathComponent(whisperFile)
            guard
                let modelURL,
                let attributes = try? FileManager.default.attributesOfItem(atPath: modelURL.path),
                let size = attributes[.size] as? NSNumber,
                size.int64Value > 0
            else {
                return false
            }
            return size.int64Value == self.expectedDownloadBytes
        }
    }

    #if canImport(FluidAudio)
    private static func parakeetModelsExist(descriptor: ParakeetSpeechModelCatalog.Descriptor) -> Bool {
        let modelsDirectory = AsrModels.defaultCacheDirectory().deletingLastPathComponent()
        let directory = descriptor.cacheDirectory(in: modelsDirectory)
        return descriptor.artifactsAreComplete(at: directory)
    }

    private static func parakeetRealtimeModelsExist() -> Bool {
        let modelsDirectory = AsrModels.defaultCacheDirectory().deletingLastPathComponent()
        let modelDirectory = modelsDirectory
            .appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
            .appendingPathComponent(Repo.parakeetEou160.folderName, isDirectory: true)

        return ModelNames.ParakeetEOU.requiredModels.allSatisfy { modelName in
            let artifact = modelDirectory.appendingPathComponent(modelName)
            return HuggingFaceModelDownloader.artifactIsComplete(
                at: artifact,
                isDirectory: modelName.hasSuffix(".mlmodelc")
            )
        }
    }
    #endif

    /// Brand/provider name for the model (NVIDIA, Apple, OpenAI)
    var brandName: String {
        switch self {
        case .fluidParakeetMini, .fluidParakeetPico:
            return "FluidVoice"
        case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return "NVIDIA"
        case .qwen3Asr:
            return "Qwen"
        case .cohereTranscribeSixBit:
            return "Cohere"
        case .appleSpeech, .appleSpeechAnalyzer:
            return "Apple"
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
            return "OpenAI"
        }
    }

    /// Whether this model uses Apple's SF Symbol for branding (apple.logo)
    var usesAppleLogo: Bool {
        switch self {
        case .appleSpeech, .appleSpeechAnalyzer: return true
        default: return false
        }
    }

    /// Brand color for the provider badge
    var brandColorHex: String {
        switch self {
        case .fluidParakeetMini, .fluidParakeetPico:
            return "#1A75FF" // FluidBrandColors.blue
        case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return "#76B900"
        case .qwen3Asr:
            return "#E67E22"
        case .cohereTranscribeSixBit:
            return "#FA6B3C"
        case .appleSpeech, .appleSpeechAnalyzer:
            return "#A2AAAD" // Apple Gray
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
            return "#10A37F" // OpenAI Teal
        }
    }
}
