import Foundation

/// Tries a pasted key with the cheapest real request each provider has: a free, read-only list or account call,
/// so a check never bills anything.
public enum KeyCheck {
    public enum Service: String, Sendable, CaseIterable {
        case assemblyai, deepgram, elevenlabs, openai, anthropic, openrouter

        public init?(_ provider: TranscriptionProvider) {
            switch provider {
            case .assemblyai: self = .assemblyai
            case .deepgram: self = .deepgram
            case .elevenlabs: self = .elevenlabs
            case .openai: self = .openai
            case .local: return nil
            }
        }

        /// Nil for the local providers, which need no key.
        public init?(_ provider: AIProvider) {
            switch provider {
            case .anthropic: self = .anthropic
            case .openai: self = .openai
            case .openrouter: self = .openrouter
            case .localServer, .apple: return nil
            }
        }

        public var displayName: String {
            switch self {
            case .assemblyai: "AssemblyAI"
            case .deepgram: "Deepgram"
            case .elevenlabs: "ElevenLabs"
            case .openai: "OpenAI"
            case .anthropic: "Anthropic"
            case .openrouter: "OpenRouter"
            }
        }

        /// Where to make a key.
        public var keysPage: URL {
            let page = switch self {
            case .assemblyai: "https://www.assemblyai.com/app/api-keys"
            case .deepgram: "https://console.deepgram.com/"
            case .elevenlabs: "https://elevenlabs.io/app/settings/api-keys"
            case .openai: "https://platform.openai.com/api-keys"
            case .anthropic: "https://console.anthropic.com/settings/keys"
            case .openrouter: "https://openrouter.ai/settings/keys"
            }
            return URL(string: page)!
        }
    }

    /// What a key row says: no key, a key that is saved, or a saved key that a check just proved.
    public enum Status: Equatable, Sendable {
        case missing, saved, works

        public init(saved: Bool, passed: Bool) {
            self = !saved ? .missing : passed ? .works : .saved
        }

        public var label: String {
            switch self {
            case .missing: "No key"
            case .saved: "Key saved"
            case .works: "Key works"
            }
        }
    }

    public static func request(_ service: Service, key: String) -> URLRequest {
        let (url, header, value): (String, String, String) = switch service {
        case .assemblyai: ("https://api.assemblyai.com/v2/transcript?limit=1", "Authorization", key)
        case .deepgram: ("https://api.deepgram.com/v1/projects", "Authorization", "Token \(key)")
        case .elevenlabs: ("https://api.elevenlabs.io/v1/user", "xi-api-key", key)
        case .openai: ("https://api.openai.com/v1/models", "Authorization", "Bearer \(key)")
        case .anthropic: ("https://api.anthropic.com/v1/models?limit=1", "x-api-key", key)
        case .openrouter: ("https://openrouter.ai/api/v1/key", "Authorization", "Bearer \(key)")
        }
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue(value, forHTTPHeaderField: header)
        if service == .anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        return request
    }

    /// Throws `ProviderError.http` when the provider does not accept the key; FriendlyError words it.
    public static func run(_ service: Service, key: String, session: URLSession = .shared) async throws {
        let (data, response) = try await session.data(for: request(service, key: key))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ProviderError.http(service.displayName, status, String(decoding: data.prefix(400), as: UTF8.self))
        }
    }
}
