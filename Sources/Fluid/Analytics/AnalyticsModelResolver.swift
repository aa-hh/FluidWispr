import Foundation

extension SpeechModel {
    var analyticsDescriptor: AnalyticsModelDescriptor {
        let resolvedModel: SpeechModel
        switch self {
        case .appleSpeechAnalyzer:
            if #available(macOS 26.0, *) {
                resolvedModel = self
            } else {
                resolvedModel = .appleSpeech
            }
        case .qwen3Asr:
            resolvedModel = .parakeetTDT
        default:
            resolvedModel = self
        }
        return AnalyticsModelDescriptor(
            provider: resolvedModel.provider.rawValue,
            model: resolvedModel.rawValue
        )
    }
}
