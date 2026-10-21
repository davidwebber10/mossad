import Foundation

extension Pipeline {
    /// Short text for the UI, such as "Transcribing failed: AssemblyAI key missing". The full error stays in the log.
    public static func failureReason(_ error: Error) -> String {
        switch error {
        case let e as MissingAPIKey: return "\(e.service) key missing"
        case TranscriptionError.http(401, _), SummaryError.http(401, _): return "invalid API key"
        case TranscriptionError.http(let code, _): return "AssemblyAI error \(code)"
        case TranscriptionError.failed: return "AssemblyAI could not transcribe the audio"
        case SummaryError.http(let code, _): return "Anthropic error \(code)"
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
}
