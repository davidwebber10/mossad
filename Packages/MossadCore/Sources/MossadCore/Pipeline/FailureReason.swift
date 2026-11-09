import Foundation

extension Pipeline {
    /// Short text for the UI, such as "Transcribing failed: AssemblyAI key missing". The full error stays in the log.
    public static func failureReason(_ error: Error) -> String {
        switch error {
        case let e as MissingAPIKey: return "\(e.service) key missing"
        case TranscriptionError.http(401, _), SummaryError.http(401, _), ProviderError.http(_, 401, _): return "invalid API key"
        case ProviderError.http(let p, let code, let body): return "\(p) error \(code)" + said(code, body)
        case ProviderError.failed(let p, let message): return "\(p): \(message)"
        case TranscriptionError.http(let code, let body): return "AssemblyAI error \(code)" + said(code, body)
        case TranscriptionError.failed: return "AssemblyAI could not transcribe the audio"
        case SummaryError.http(let code, let body): return "Anthropic error \(code)" + said(code, body)
        case let e as SummaryError: return e.description
        case let e as URLError:
            switch e.code {
            case .timedOut: return "the request timed out"
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "no network connection"
            default: return "network error"
            }
        default: return "unexpected error"
        }
    }

    /// The provider refused the key (HTTP 401). Nothing is billed, so the call waits for a good key without
    /// using up attempts.
    static func keyRejected(_ error: Error) -> Bool {
        switch error {
        case TranscriptionError.http(401, _), SummaryError.http(401, _), ProviderError.http(_, 401, _): true
        default: false
        }
    }

    /// A refused request keeps the provider's own words when they read as a sentence, so the card can say why.
    private static func said(_ code: Int, _ body: String) -> String {
        guard (400..<500).contains(code), let message = FriendlyError.providerMessage(body) else { return "" }
        return ": " + message.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
