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

    /// Per audio hour, by provider. Deepgram Nova-3 is $0.0043 a minute; OpenAI's diarizing model $0.006.
    static let deepgramPerHour = 0.258
    static let elevenLabsPerHour = 0.22
    static let openAITranscriptionPerHour = 0.36

    /// OpenAI per million tokens: input, cached input, output.
    static let openAI: [(prefix: String, price: TokenPrice)] = [
        ("gpt-6-astra", TokenPrice(input: 10, output: 50, cacheRead: 1, cacheWrite: 10)),
        ("gpt-6.1-sol", TokenPrice(input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2)),
        ("gpt-6-sol", TokenPrice(input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2)),
        ("gpt-6-luna", TokenPrice(input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.1)),
        ("gpt-5.6-sol", TokenPrice(input: 4, output: 20, cacheRead: 0.4, cacheWrite: 4)),
        ("gpt-5.6-terra", TokenPrice(input: 2, output: 12, cacheRead: 0.2, cacheWrite: 2)),
        ("gpt-5.6-luna", TokenPrice(input: 0.2, output: 1.2, cacheRead: 0.02, cacheWrite: 0.2)),
        ("gpt-5.5", TokenPrice(input: 5, output: 30, cacheRead: 0.5, cacheWrite: 5)),
        ("gpt-5.4-mini", TokenPrice(input: 0.75, output: 4.5, cacheRead: 0.075, cacheWrite: 0.75)),
        ("gpt-5.4-nano", TokenPrice(input: 0.2, output: 1.25, cacheRead: 0.02, cacheWrite: 0.2)),
        ("gpt-5.4", TokenPrice(input: 2.5, output: 15, cacheRead: 0.25, cacheWrite: 2.5)),
        ("gpt-5-mini", TokenPrice(input: 0.25, output: 2, cacheRead: 0.025, cacheWrite: 0.25)),
        ("gpt-5-nano", TokenPrice(input: 0.05, output: 0.4, cacheRead: 0.005, cacheWrite: 0.05)),
        ("gpt-5", TokenPrice(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.25)),
    ]

    static func tokens(_ e: UsageEvent, _ p: TokenPrice) -> Double {
        func m(_ n: Int?) -> Double { Double(n ?? 0) / 1_000_000 }
        return m(e.inputTokens) * p.input + m(e.outputTokens) * p.output + m(e.cacheReadTokens) * p.cacheRead + m(e.cacheWriteTokens) * p.cacheWrite
    }

    public static func cost(_ e: UsageEvent) -> Double {
        if let charged = e.costUSD { return charged }
        let hours = (e.audioSeconds ?? 0) / 3600
        switch e.service {
        case .deepgram: return hours * deepgramPerHour
        case .elevenlabs: return hours * elevenLabsPerHour
        case .openrouter: return 0
        case .openai:
            if e.purpose == .transcription { return hours * openAITranscriptionPerHour }
            // A model this table does not know costs nothing here rather than a guess.
            guard let p = openAI.first(where: { e.model?.hasPrefix($0.prefix) == true })?.price else { return 0 }
            return tokens(e, p)
        case .claude:
            return tokens(e, claude.first { e.model?.hasPrefix($0.prefix) == true }?.price ?? defaultClaude)
        case .assemblyai:
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
