import Foundation

/// A number the app counts that advice can be about.
public enum CoachMeasure: String, Codable, Sendable, CaseIterable {
    /// The share of the owner's commitments that have a day.
    case commitmentDay = "commitment_day"
}

/// The one thing the coach says after a call. A line always has proof: a moment to play, or a measured number
/// with what it stands against. The rest of the review waits behind "Full review".
public struct CoachLine: Codable, Equatable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// How the call went on the focus the owner accepted.
        case focus
        /// A change over enough calls, found by the app and never by the model.
        case progress
        case tryNext
        /// Advice of the last 30 days that more calls showed: a count with the moment, not the advice again.
        case again
        /// A number of this call that is not the owner's usual.
        case number
        case didWell
    }

    public var kind: Kind
    public var text: String
    /// What the line is about, as the advice log keeps it.
    public var skill: String
    /// The owner's own words, found in the transcript by code.
    public var quote: String?
    public var at: TimeInterval?
    /// For "try next time": the words the owner could say.
    public var say: String?
    /// A number the app measured, with what it stands against: "Usually 62 to 70% in your 1:1s with Sam".
    public var number: String?
    public var measure: CoachMeasure?
    /// For the focus: how the call went on it.
    public var outcome: FocusOutcome?
    /// Why it matters, in the model's words. Not counted in `words`: the line shows it only as a card.
    public var why: String?

    public init(kind: Kind, text: String, skill: String, quote: String? = nil, at: TimeInterval? = nil, say: String? = nil,
                number: String? = nil, measure: CoachMeasure? = nil, outcome: FocusOutcome? = nil, why: String? = nil) {
        self.kind = kind
        self.text = text
        self.skill = skill
        self.quote = quote
        self.at = at
        self.say = say
        self.number = number
        self.measure = measure
        self.outcome = outcome
        self.why = why
    }

    init(kind: Kind, note: CoachNote) {
        self.init(kind: kind, text: note.text, skill: note.skill ?? note.text, quote: note.quote, at: note.at, say: note.say,
                  number: note.number, measure: note.measure, why: note.why)
    }

    public var hasProof: Bool { at != nil || number != nil }

    /// Every word the owner reads for this line.
    public var words: Int {
        [text, quote, say, number].compactMap { $0 }.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
    }

    public var title: String {
        switch kind {
        case .focus: "Your focus"
        case .progress: "Improving"
        case .tryNext: "Try next time"
        case .again: "Seen again"
        case .number: "Not your usual"
        case .didWell: "Did well"
        }
    }
}

extension CoachReview {
    /// Reviews written as one line with proof. Older ones have 0.
    public static let currentVersion = 3

    /// The line to show: the stored one, or for a review from before one line, the first of its focus result,
    /// its advice, and what went well. The model's own "improving" is never shown: it was not measured.
    public var shownLine: CoachLine? {
        if version >= Self.currentVersion { return line }
        if let r = focusResult, r.outcome != .noChance {
            return CoachLine(kind: .focus, text: r.evidence, skill: "", at: r.at, outcome: r.outcome)
        }
        if let n = tryNext { return CoachLine(kind: .tryNext, note: n) }
        if let n = didWell { return CoachLine(kind: .didWell, note: n) }
        guard !quiet else { return nil }
        // The oldest reviews have points only.
        if let p = improvements.first { return CoachLine(kind: .tryNext, text: p.title, skill: p.title, quote: p.quote.nonBlank, at: p.at, say: p.tryInstead) }
        return strengths.first.map { CoachLine(kind: .didWell, text: $0.title, skill: $0.title, quote: $0.quote.nonBlank, at: $0.at) }
    }

    /// True when the coach looked and has nothing with proof to say. A review from before one line that has
    /// no line is only an older shape: it shows its read, not "nothing".
    public var saysNothing: Bool { shownLine == nil && (version >= Self.currentVersion || quiet) }

    /// What the review says besides the shown line, for the full review.
    public var others: [CoachLine] {
        let shown = shownLine?.kind
        var out: [CoachLine] = []
        if let n = didWell, shown != .didWell { out.append(CoachLine(kind: .didWell, note: n)) }
        if let n = tryNext, shown != .tryNext { out.append(CoachLine(kind: .tryNext, note: n)) }
        if let n = seenAgain, shown != .again { out.append(CoachLine(kind: .again, note: n)) }
        return out
    }
}
