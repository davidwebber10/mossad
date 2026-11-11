import Foundation

/// A trait that shows, as the pages, Chat, other AI apps, and the iPhone read it: the sentence, what to do, the
/// counts, and pointers to the moments. No hidden candidate, and no words of the person.
public struct ShownTrait: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var dimension: String
    public var value: String
    public var condition: PersonaSetting?
    public var statement: String
    public var soDoThis: String
    public var confirmed: Bool
    public var confidence: Double
    public var supportCalls: Int
    public var counterCalls: Int
    public var moments: [PersonaPointer]
    public var counter: [PersonaPointer]
    public var lastSeen: Date

    public init(_ t: PersonaTrait, name: String) {
        id = t.id
        dimension = t.dimension
        value = t.value
        condition = t.condition
        statement = t.text?.statement ?? ""
        soDoThis = t.text?.soDoThis ?? ""
        confirmed = t.state == .confirmed
        confidence = t.confidence
        supportCalls = t.supportCalls
        counterCalls = t.counterCalls
        // The newest moments first; one for each call.
        var seen: Set<String> = []
        moments = t.support.reversed().filter { seen.insert($0.callID).inserted }.prefix(5).map(\.pointer)
        counter = t.counter.reversed().prefix(3).map(\.pointer)
        lastSeen = t.lastSeen ?? .distantPast
    }

    public var label: String { confirmed ? "You confirmed" : confidence >= PersonaConfidence.established ? "Established" : "Likely" }
    public var countLine: String { "seen in \(supportCalls) of \(supportCalls + counterCalls) \(supportCalls + counterCalls == 1 ? "call" : "calls")" }
    /// "Likely, seen in 3 of 4 calls".
    public var confidenceLine: String { "\(label), \(countLine)" }
    /// The number, for the trait's detail: "0.62".
    public var numberText: String { String(format: "%.2f", confidence) }
}

/// "How to present to them": five lines at most, each from shown traits only. Code builds it from the stored
/// sentences: opening a meeting makes no request, and the card is the same each time.
public struct PersonaCard: Codable, Equatable, Sendable {
    public enum LineKind: String, Codable, Sendable, CaseIterable {
        case open, evidence, ask, objections, avoid

        public var title: String {
            switch self {
            case .open: "Open with"
            case .evidence: "Evidence they need"
            case .ask: "Frame the ask"
            case .objections: "Likely objections"
            case .avoid: "Avoid"
            }
        }

        /// Which line a trait feeds. Each trait feeds one line.
        static func of(dimension: String, value: String) -> LineKind {
            switch PersonaDimension(rawValue: dimension) {
            case .order, .detail: .open
            case .evidence, .trust, .expects: .evidence
            case .decision, .authority, .drivers: .ask
            case .risk: value == "downside_first" ? .objections : .ask
            case .objection: .objections
            case .pace: .avoid
            case nil: .avoid
            }
        }
    }

    public struct Line: Codable, Equatable, Sendable, Identifiable {
        public var kind: LineKind
        /// The "so do this" sentences of its traits, the strongest first.
        public var text: String
        public var traits: [String]
        /// The strongest trait's label and count, and its best moment.
        public var confidenceLine: String
        public var moment: PersonaPointer?
        public var id: String { kind.rawValue }
    }

    public static let minimumLines = 2
    static let traitsPerLine = 2

    public var headline: String
    public var lines: [Line]

    /// Nil with fewer than 2 lines: a line with no trait is left out, never filled with a general tip.
    public static func build(_ traits: [ShownTrait]) -> PersonaCard? {
        let usable = traits.filter { $0.soDoThis.nonBlank != nil && $0.statement.nonBlank != nil }
            .sorted { ($0.confirmed ? 1 : 0, $0.confidence, $1.id) > ($1.confirmed ? 1 : 0, $1.confidence, $0.id) }
        var lines: [Line] = []
        for kind in LineKind.allCases {
            let mine = usable.filter { LineKind.of(dimension: $0.dimension, value: $0.value) == kind }.prefix(traitsPerLine)
            guard let first = mine.first else { continue }
            lines.append(Line(kind: kind, text: mine.map { sentence($0.soDoThis) }.joined(separator: " "), traits: mine.map(\.id),
                              confidenceLine: first.confidenceLine, moment: first.moments.first))
        }
        guard lines.count >= minimumLines, let top = usable.first else { return nil }
        // The headline is the strongest trait's "so do this", from the opening line when there is one.
        let lead = lines.first { $0.kind == .open }.flatMap { l in usable.first { $0.id == l.traits.first } } ?? top
        return PersonaCard(headline: sentence(lead.soDoThis), lines: lines)
    }

    static func sentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return t }
        return ".!?".contains(last) ? t : t + "."
    }

    /// The calls a person needs before a card can show, by the show rule.
    public static let callsNeeded = 3

    /// "The coach needs more calls with Sam. It has 2. It needs 3." The count is true to the rule.
    public static func needsMore(first: String, calls: Int) -> String {
        "The coach needs more calls with \(first). It has \(calls). It needs \(callsNeeded)."
    }
}

/// One person's read as the pages show it and as it syncs to the iPhone: shown traits, the card, and counts.
public struct PersonaSummary: Codable, Equatable, Sendable, Identifiable {
    public var person: String
    public var updated: Date
    public var traits: [ShownTrait]
    public var card: PersonaCard?
    /// Calls with moments of this person.
    public var calls: Int
    /// "3 more things seen in one call": hidden traits of one call, as a count only.
    public var oneCall: Int

    public var id: String { person }

    public init(person: String, updated: Date, traits: [ShownTrait], card: PersonaCard?, calls: Int, oneCall: Int) {
        self.person = person
        self.updated = updated
        self.traits = traits
        self.card = card
        self.calls = calls
        self.oneCall = oneCall
    }

    /// From the person's file and the owner's answers. `name` is the person's name now, for the sentences.
    public static func make(_ persona: Persona, answers: [FindingAnswer], name: String, doNotProfile: Bool = false) -> PersonaSummary? {
        guard !doNotProfile else { return nil }
        let traits = PersonaTraits.build(persona, answers: answers)
        let shown = traits.filter(\.isShown).map { ShownTrait($0, name: name) }
        let oneCall = traits.filter { $0.state == .hidden && $0.supportCalls == 1 }.count
        return PersonaSummary(person: persona.person, updated: persona.updated, traits: shown, card: PersonaCard.build(shown), calls: persona.calls.count, oneCall: oneCall)
    }

    /// The text for Chat and other AI apps: the shown traits with their counts, then the card.
    public func text(name: String) -> String {
        var lines: [String] = []
        if let card { lines.append("How to present to \(name): " + card.lines.map { "\($0.kind.title): \($0.text)" }.joined(separator: " / ")) }
        for t in traits { lines.append("- \(t.statement) (\(t.confidenceLine))") }
        return lines.joined(separator: "\n")
    }
}

/// The card is covered while the owner shares the screen or records a call with that person: a colleague must not
/// read "likely objections" on the owner's screen. One click opens it.
public enum PersonaCover {
    /// `sharing` is nil when Mossad cannot tell. While a call is recorded and the share is not known, the card is
    /// covered: unknown is not false.
    public static func isCovered(person: String?, recording: Bool, callPeople: Set<String>, sharing: Bool?) -> Bool {
        if sharing == true { return true }
        guard recording else { return false }
        if sharing == nil { return true }
        return person.map(callPeople.contains) ?? false
    }
}
