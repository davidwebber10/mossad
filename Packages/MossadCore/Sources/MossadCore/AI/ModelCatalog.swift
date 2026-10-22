import Foundation

public struct ModelInfo: Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The models each provider offers, for the pickers in Settings.
public enum ModelCatalog {
    /// OpenAI lists every model it has; keep the chat models that can do structured output and tools.
    static let openAIExclusions = ["transcribe", "tts", "audio", "realtime", "image", "embedding", "search", "moderation", "whisper", "dall-e", "codex"]

    static func data(_ json: Data) -> [[String: Any]] {
        ((try? JSONSerialization.jsonObject(with: json)) as? [String: Any])?["data"] as? [[String: Any]] ?? []
    }

    static func parseAnthropic(_ json: Data) -> [ModelInfo] {
        data(json).compactMap { m in (m["id"] as? String).map { ModelInfo(id: $0, name: m["display_name"] as? String ?? $0) } }
    }

    static func parseOpenAI(_ json: Data) -> [ModelInfo] {
        data(json).compactMap { $0["id"] as? String }
            .filter { id in id.hasPrefix("gpt-") && !openAIExclusions.contains { id.contains($0) } }
            .sorted().map { ModelInfo(id: $0, name: $0) }
    }

    static func parseOpenRouter(_ json: Data) -> [ModelInfo] {
        data(json).filter { m in
            let params = m["supported_parameters"] as? [String] ?? []
            return params.contains("tools") && params.contains("structured_outputs")
        }.compactMap { m in (m["id"] as? String).map { ModelInfo(id: $0, name: m["name"] as? String ?? $0) } }
    }

    public static func fetch(_ provider: AIProvider, apiKey: String?, session: URLSession = .shared) async throws -> [ModelInfo] {
        var request: URLRequest
        switch provider {
        case .anthropic:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
            request.setValue(apiKey ?? "", forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openai:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(apiKey ?? "")", forHTTPHeaderField: "Authorization")
        case .openrouter:
            // Public: no key needed to list models.
            request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models?supported_parameters=tools,structured_outputs")!)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ProviderError.http(provider.displayName, status, data.snippet) }
        switch provider {
        case .anthropic: return parseAnthropic(data)
        case .openai: return parseOpenAI(data)
        case .openrouter: return parseOpenRouter(data)
        }
    }
}
