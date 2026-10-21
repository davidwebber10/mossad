import Foundation

/// List prices in US dollars, October 2026. Costs are worked out when shown, so a price change here
/// updates every past figure.
public enum Pricing {
    struct TokenPrice {
        /// Per million tokens.
        let input, output, cacheRead, cacheWrite: Double
    }

    /// Longest prefix first, so "claude-opus-5-5" does not match "claude-opus-5".
    static let claude: [(prefix: String, price: TokenPrice)] = [
        ("claude-opus-5-5", TokenPrice(input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5)),
        ("claude-opus-5", TokenPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)),
        ("claude-sonnet-5", TokenPrice(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5)),
        ("claude-haiku-5", TokenPrice(input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125)),
        ("claude-fable-5", TokenPrice(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5)),
    ]
    /// The model Mossad asks for; also the price of a model this table does not know.
    static let defaultClaude = claude[0].price

    /// Per audio hour.
    static let batchModels: [String: Double] = ["universal-3-5-pro": 0.21, "universal-2": 0.15]
    static let defaultBatchModel = "universal-3-5-pro"
    static let speakerLabelsPerHour = 0.02
    static let streamingPerHour = 0.15

    public static func cost(_ e: UsageEvent) -> Double {
        switch e.service {
        case .claude:
            let p = claude.first { e.model?.hasPrefix($0.prefix) == true }?.price ?? defaultClaude
            func m(_ n: Int?) -> Double { Double(n ?? 0) / 1_000_000 }
            return m(e.inputTokens) * p.input + m(e.outputTokens) * p.output + m(e.cacheReadTokens) * p.cacheRead + m(e.cacheWriteTokens) * p.cacheWrite
        case .assemblyai:
            let hours = (e.audioSeconds ?? 0) / 3600
            if e.purpose == .live { return hours * streamingPerHour }
            return hours * ((batchModels[e.model ?? ""] ?? batchModels[defaultBatchModel]!) + speakerLabelsPerHour)
        }
    }

    /// Typical reply sizes, for the estimates.
    static let summaryOutputTokens = 2_500
    static let promptTokens = 1_500

    /// Usage for calls processed before the log existed: both tracks transcribed for the whole call, and one
    /// summary with the transcript as input (about 4 characters per token).
    public static func estimates(for records: [CallRecord], logged: [UsageEvent]) -> [UsageEvent] {
        let known = Set(logged.compactMap(\.callID))
        return records.filter { $0.status == .written && !known.contains($0.id) && !$0.utterances.isEmpty }.flatMap { r -> [UsageEvent] in
            let seconds = r.end.timeIntervalSince(r.start)
            let characters = r.utterances.map(\.text.count).reduce(0, +)
            return [
                UsageEvent(date: r.end, callID: r.id, service: .assemblyai, purpose: .transcription, model: defaultBatchModel,
                           audioSeconds: seconds * 2, estimated: true),
                UsageEvent(date: r.end, callID: r.id, service: .claude, purpose: .summary, model: claude[0].prefix,
                           inputTokens: characters / 4 + promptTokens, outputTokens: summaryOutputTokens, estimated: true),
            ]
        }
    }
}
