import Foundation

/// Stars for a few aspects of a provider or model, and a price level from $ to $$$$, with what they rest on.
public struct Rating: Equatable, Sendable {
    /// Aspect name to 1...5 stars, in display order by `aspects`.
    public var stars: [String: Int]
    /// 1...4, shown as $ to $$$$.
    public var price: Int
    /// Where the numbers come from, for the tooltip.
    public var basis: String
    /// Costs nothing to run, shown as "Free" in place of a price level.
    public var free = false

    public init(stars: [String: Int], price: Int, basis: String, free: Bool = false) {
        self.stars = stars
        self.price = price
        self.basis = basis
        self.free = free
    }

    public var dollars: String { String(repeating: "$", count: max(1, min(4, price))) }
    public static let transcriptionAspects = ["Accuracy", "Speakers", "Word times"]
    public static let modelAspects = ["Quality", "Speed"]

    // MARK: Price levels

    /// Audio hours: up to $0.10, $0.30, $0.60, or more.
    public static func priceLevel(perHour: Double) -> Int {
        perHour <= 0.10 ? 1 : perHour <= 0.30 ? 2 : perHour <= 0.60 ? 3 : 4
    }

    /// The cost of one typical coach review, about 20k tokens in and 3k out: under 2, 8, or 25 cents, or more.
    public static func priceLevel(inputPerMillion: Double, outputPerMillion: Double) -> Int {
        let cost = 0.02 * inputPerMillion + 0.003 * outputPerMillion
        return cost < 0.02 ? 1 : cost < 0.08 ? 2 : cost < 0.25 ? 3 : 4
    }

    // MARK: Models

    /// Stars by the model's tier in its maker's lineup. Matched on the name, so OpenRouter's "anthropic/claude-opus-5.5"
    /// is rated like Anthropic's "claude-opus-5-5".
    static let tiers: [(match: String, quality: Int, speed: Int)] = [
        ("fable", 5, 2), ("mythos", 5, 2), ("opus", 5, 3), ("sonnet", 4, 4), ("haiku", 3, 5),
        ("gpt-6-astra", 5, 3), ("gpt-6.1-sol", 4, 4), ("gpt-6-sol", 4, 4), ("gpt-6-luna", 3, 5),
        ("gpt-5.6-sol", 4, 3), ("gpt-5.6-terra", 4, 4), ("gpt-5.6-luna", 3, 5), ("gpt-5.5", 4, 3),
        ("nano", 2, 5), ("mini", 3, 5), ("gpt-5.4", 3, 4), ("gpt-5", 3, 4),
    ]

    public static func model(_ info: ModelInfo, provider: AIProvider) -> Rating? {
        let id = info.id.lowercased().replacingOccurrences(of: ".", with: "-")
        let tier = tiers.first { id.contains($0.match.replacingOccurrences(of: ".", with: "-")) }
        var input = info.inputPerMillion, output = info.outputPerMillion
        if input == nil {
            let table = provider == .anthropic ? Pricing.claude : provider == .openai ? Pricing.openAI : []
            if let p = table.first(where: { info.id.hasPrefix($0.prefix) })?.price { input = p.input; output = p.output }
        }
        guard input != nil || tier != nil else { return nil }
        let stars = tier.map { ["Quality": $0.quality, "Speed": $0.speed] } ?? [:]
        let price = input.map { priceLevel(inputPerMillion: $0, outputPerMillion: output ?? 0) } ?? 0
        return Rating(stars: stars, price: price,
                      basis: (tier == nil ? "No stars: Mossad knows nothing about this model's quality." : "Stars by the model's tier in its maker's lineup, not measured.")
                          + (input == nil ? "" : " Price from list prices, for a typical coach review."))
    }

    public static func model(_ id: String, provider: AIProvider) -> Rating? {
        model(ModelInfo(id: id, name: id), provider: provider)
    }
}

extension TranscriptionProvider {
    public var perHour: Double {
        switch self {
        case .assemblyai: Pricing.batchModels[Pricing.defaultBatchModel]! + Pricing.speakerLabelsPerHour
        case .deepgram: Pricing.deepgramPerHour
        case .elevenlabs: Pricing.elevenLabsPerHour
        case .openai: Pricing.openAITranscriptionPerHour
        case .local: 0
        }
    }

    public var rating: Rating {
        let price = Rating.priceLevel(perHour: perHour)
        return switch self {
        case .assemblyai:
            Rating(stars: ["Accuracy": 5, "Speakers": 4, "Word times": 5], price: price,
                   basis: "Accuracy measured on your calls: it got product names such as Triple Whale and Databricks right.")
        case .deepgram:
            Rating(stars: ["Accuracy": 4, "Speakers": 4, "Word times": 5], price: price,
                   basis: "Accuracy is an estimate; Mossad has not measured it on your calls. Words come with speakers and times.")
        case .elevenlabs:
            Rating(stars: ["Accuracy": 4, "Speakers": 4, "Word times": 5], price: price,
                   basis: "Accuracy is an estimate; Mossad has not measured it on your calls. Words come with speakers and times.")
        case .openai:
            Rating(stars: ["Accuracy": 4, "Speakers": 3, "Word times": 1], price: price,
                   basis: "Accuracy is an estimate. It returns no word times and labels speakers by segment only.")
        case .local:
            Rating(stars: ["Accuracy": 3, "Speakers": 3, "Word times": 4], price: 0,
                   basis: "Accuracy measured on your calls: 94% the same words as AssemblyAI, but it missed product names such as Triple Whale. Speakers are an estimate.",
                   free: true)
        }
    }
}
