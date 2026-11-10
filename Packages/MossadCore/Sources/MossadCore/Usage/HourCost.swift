import Foundation

/// What an hour of meetings costs with the owner's choices, part by part. Setup and Settings both show it, so
/// every part that a provider bills must be here: a number that leaves one out reads as a promise.
public struct HourCost: Equatable, Sendable {
    public struct Part: Equatable, Sendable {
        public enum Kind: Sendable { case transcription, liveTranscript, notes, coach }
        public var kind: Kind
        /// Nil when the provider bills it but the model has no list price here. Unknown is not free.
        public var amount: Double?

        public init(_ kind: Kind, _ amount: Double?) {
            self.kind = kind
            self.amount = amount
        }
    }

    /// The parts that are on, in the order shown.
    public var parts: [Part]
    /// One weekly or monthly coach email, when they are on and the model has a list price above zero.
    public var email: Double?

    public init(parts: [Part], email: Double? = nil) {
        self.parts = parts
        self.email = email
    }

    private var hasUnknown: Bool { parts.contains { $0.amount == nil } }
    private var known: [Double] { parts.compactMap(\.amount) }

    /// The known parts together. A part with no list price adds nothing.
    public var total: Double { known.reduce(0, +) }

    /// The sum of the parts as they show, each one rounded to a cent first, so the headline and the parts agree.
    private var shownTotal: Double { known.map { ($0 * 100).rounded() / 100 }.reduce(0, +) }

    /// "About $0.93", "Free" only when no part bills, or "At least $0.46" when a part has no list price.
    public var headline: String {
        if hasUnknown { return shownTotal > 0 ? "At least \(Pricing.dollars(shownTotal))" : "Not known" }
        if total == 0 { return "Free" }
        return shownTotal == 0 ? "Less than $0.01" : "About \(Pricing.dollars(shownTotal))"
    }

    /// "Transcription: $0.46 for both tracks. Live transcript: $0.30. Notes: $0.17. Coach: $0.14."
    public var detail: String {
        // The notes and the coach use one model, so one sentence says that its price is not known.
        let noPrice = Set(parts.filter { $0.amount == nil }.map(\.kind))
        let together = noPrice.isSuperset(of: [.notes, .coach])
        return parts.compactMap { part -> String? in
            switch part.kind {
            case .transcription:
                let amount = part.amount ?? 0
                return "Transcription: \(amount > 0 ? "\(Self.amount(amount)) for both tracks" : "free on this Mac")."
            case .liveTranscript: return "Live transcript: \(Self.words(part.amount))."
            case .notes: return "\(together ? "Notes and coach" : "Notes"): \(Self.words(part.amount))."
            case .coach: return together ? nil : "Coach: \(Self.words(part.amount))."
            }
        }
        .joined(separator: " ")
    }

    /// "Each coach email: about $0.04."
    public var emailDetail: String? {
        email.flatMap { $0 > 0 ? "Each coach email: about \(Self.amount($0))." : nil }
    }

    private static func words(_ amount: Double?) -> String {
        amount.map { $0 > 0 ? Self.amount($0) : "free" } ?? "no list price for this model"
    }

    private static func amount(_ value: Double) -> String { value < 0.005 ? "less than $0.01" : Pricing.dollars(value) }
}

extension Pricing {
    /// The read for what the owner promised: the transcript with a short prompt, and a short list back.
    static let commitmentsPromptTokens = 600
    static let commitmentsOutputTokens = 300
    /// A provisional title, once for each call, from about 5 minutes of live transcript.
    static let liveTitleInputTokens = 1_200
    static let liveTitleOutputTokens = 20
    /// One coach review: the transcript with the profile, the numbers, and the prompt; about 20,000 tokens in.
    static let coachExtraInputTokens = 6_500
    static let coachOutputTokens = 3_000
    /// One weekly or monthly email, from the period's reviews.
    static let emailInputTokens = 6_000
    static let emailOutputTokens = 1_000

    /// The known parts of an hour together: what setup and the tests call the estimate.
    public static func hourEstimate(transcription: TranscriptionProvider, ai: AIProvider, model: String) -> Double {
        hourCost(transcription: transcription, ai: ai, model: model).total
    }

    /// An hour of meetings as one call. `liveTranscript` is true only when sessions open: the switch is on and
    /// an AssemblyAI key is saved. Chat, and the coach's occasional questions and briefs, are not in it: they do
    /// not follow the hours of meetings.
    public static func hourCost(transcription: TranscriptionProvider, ai: AIProvider, model: String, liveTranscript: Bool = false,
                                coach: Bool = false, coachEmail: Bool = false) -> HourCost {
        let audio: UsageEvent.Service? = switch transcription {
        case .assemblyai: .assemblyai
        case .deepgram: .deepgram
        case .elevenlabs: .elevenlabs
        case .openai: .openai
        case .local: nil
        }
        let service: UsageEvent.Service = switch ai {
        case .anthropic: .claude
        case .openai: .openai
        case .openrouter: .openrouter
        case .localServer, .apple: .local
        }
        let name = ai.resolvedModel(model)
        func priced(_ model: String) -> Bool {
            switch ai {
            case .anthropic, .localServer, .apple: true
            case .openai: openAI.contains { model.hasPrefix($0.prefix) }
            case .openrouter: false
            }
        }
        func request(_ purpose: UsageEvent.Purpose, model: String, input: Int, output: Int) -> Double {
            cost(UsageEvent(date: Date(), callID: nil, service: service, purpose: purpose, model: model, inputTokens: input,
                            outputTokens: output, estimated: true))
        }
        let transcript = audio.map {
            cost(UsageEvent(date: Date(), callID: nil, service: $0, purpose: .transcription,
                            model: $0 == .assemblyai ? defaultBatchModel : nil, audioSeconds: 2 * 3600, estimated: true))
        } ?? 0
        // The title of a live call comes from the provider's small model when it has one.
        let titleModel = ai.smallModel ?? name
        var notes: Double? = priced(name) ? request(.summary, model: name, input: hourTranscriptTokens + promptTokens, output: summaryOutputTokens)
            + request(.summary, model: name, input: hourTranscriptTokens + commitmentsPromptTokens, output: commitmentsOutputTokens) : nil
        if liveTranscript, let known = notes {
            notes = priced(titleModel) ? known + request(.summary, model: titleModel, input: liveTitleInputTokens, output: liveTitleOutputTokens) : nil
        }
        var parts = [HourCost.Part(.transcription, transcript)]
        if liveTranscript { parts.append(.init(.liveTranscript, liveHourCost)) }
        parts.append(.init(.notes, notes))
        if coach {
            parts.append(.init(.coach, priced(name) ? request(.coach, model: name, input: hourTranscriptTokens + coachExtraInputTokens,
                                                              output: coachOutputTokens) : nil))
        }
        let email = coach && coachEmail && priced(name) ? request(.weeklyEmail, model: name, input: emailInputTokens, output: emailOutputTokens) : nil
        return HourCost(parts: parts, email: email)
    }
}
