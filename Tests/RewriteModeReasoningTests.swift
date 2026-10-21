import Foundation

// Only the production reasoning lookup is compiled in (see run_rewrite_mode_reasoning_tests.sh);
// its settings and model list are test doubles.
@MainActor final class SettingsStore {
    struct ModelReasoningConfig: Equatable { let parameterName: String }
    static let shared = SettingsStore()
    var configs: [String: ModelReasoningConfig] = [:]
    func getReasoningConfig(forModel model: String, provider: String) -> ModelReasoningConfig? {
        self.configs["\(provider):\(model)"]
    }
}

@MainActor final class ModelRepository {
    static let shared = ModelRepository()
    func isBuiltIn(_ provider: String) -> Bool { provider == "openai" }
    func providerKey(for providerID: String) -> String {
        if self.isBuiltIn(providerID) || providerID.hasPrefix("custom:") { return providerID }
        return "custom:\(providerID)"
    }
}

@MainActor final class RewriteModeService {}

@main @MainActor enum RewriteModeReasoningTests {
    static func main() {
        let effort = SettingsStore.ModelReasoningConfig(parameterName: "reasoning_effort")
        SettingsStore.shared.configs = ["custom:myserver:qwen3": effort, "openai:o3": effort]
        let service = RewriteModeService()

        // Saved under "custom:<id>"; a lookup by the raw id finds nothing.
        precondition(service.reasoningConfig(forModel: "qwen3", providerID: "myserver") == effort)
        precondition(service.reasoningConfig(forModel: "qwen3", providerID: "custom:myserver") == effort)
        // Built-in providers keep their plain id.
        precondition(service.reasoningConfig(forModel: "o3", providerID: "openai") == effort)
        precondition(service.reasoningConfig(forModel: "qwen3", providerID: "other") == nil)
    }
}
