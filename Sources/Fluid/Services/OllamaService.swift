import Foundation

/// Checks for the local Ollama server and downloads the cleanup model into it.
actor OllamaService {
    static let shared = OllamaService()
    static let modelName = "qwen3:4b-instruct"
    static let baseURL: URL = {
        guard let url = URL(string: "http://localhost:11434") else { preconditionFailure("Invalid Ollama URL") }
        return url
    }()

    enum Status: Equatable {
        case notInstalled
        case modelMissing
        case ready
    }

    struct PullError: LocalizedError {
        let message: String
        var errorDescription: String? { self.message }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func status() async -> Status {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        guard let (data, _) = try? await self.session.data(for: request) else { return .notInstalled }
        let names = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
            .flatMap { $0["models"] as? [[String: Any]] }?
            .compactMap { $0["name"] as? String } ?? []
        guard names.contains(Self.modelName) else { return .modelMissing }
        await Self.selectModelIfEmpty()
        return .ready
    }

    func pullModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": Self.modelName])
        request.timeoutInterval = 3600

        let (bytes, _) = try await self.session.bytes(for: request)
        for try await line in bytes.lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let message = object["error"] as? String {
                throw PullError(message: message)
            }
            if let completed = object["completed"] as? Double, let total = object["total"] as? Double, total > 0 {
                progress(min(1, completed / total))
            }
        }
        await MainActor.run {
            SettingsStore.shared.selectedModelByProvider["ollama"] = Self.modelName
        }
    }

    private static func selectModelIfEmpty() async {
        await MainActor.run {
            let store = SettingsStore.shared
            let current = store.selectedModelByProvider["ollama"] ?? ""
            if current.isEmpty {
                store.selectedModelByProvider["ollama"] = Self.modelName
            }
        }
    }
}
