import CryptoKit
import Foundation

/// The 11 fixed ways a person can be read from a transcript, each with a short list of values, so that code can
/// count "the same value in 3 calls" and "another value in 1 call". A free dimension ("free:<label>") is named by
/// the model; a person has 2 at most.
public enum PersonaDimension: String, CaseIterable, Codable, Sendable {
    case order, detail, evidence, decision, risk, objection, trust, pace, authority, drivers, expects

    public static let freePrefix = "free:"
    public static let freeLimit = 2

    public var title: String {
        switch self {
        case .order: "Order and format"
        case .detail: "Level of detail"
        case .evidence: "Evidence they need"
        case .decision: "How they decide"
        case .risk: "Risk"
        case .objection: "How they object"
        case .trust: "What earns trust"
        case .pace: "Pace and airtime"
        case .authority: "Who they defer to"
        case .drivers: "What they optimize for"
        case .expects: "What they expect from you"
        }
    }

    /// The values the model may give. Empty: a free label.
    public var values: [String] {
        switch self {
        case .order: ["answer_first", "path_first", "options_first", "material_before", "live_walkthrough"]
        case .detail: ["big_picture", "detail_first", "high_then_deep"]
        case .evidence: ["numbers", "comparison", "earlier_case", "demonstration", "named_owner", "chain_of_reasons"]
        case .decision: ["in_the_room", "asks_for_time", "needs_second_person", "small_trial"]
        case .risk: ["downside_first", "upside_first", "yes_if_reversible"]
        case .objection: ["direct", "by_question", "own_numbers", "silent_then_later", "more_work"]
        case .trust: ["follow_through", "unknowns_admitted", "numbers_checked", "early_notice"]
        case .pace: ["short_turns", "long_turns", "cuts_in", "waits"]
        case .authority: ["decides_alone", "refers_up", "refers_to_expert", "group_agreement"]
        case .drivers: ["cost", "time", "customer", "quality", "team_load", "risk_rules", "growth"]
        // A fixed list, so the same expectation meets itself in 3 calls.
        case .expects: ["material_ahead", "short_updates", "recommendation_first", "owner_and_date", "promises_kept", "early_warning",
                        "written_recap", "prepared_numbers"]
        }
    }

    /// The values that cannot both be a habit of one person in one setting. Other values of a dimension can
    /// (a person can need numbers and a named owner), so they are no counter-evidence of each other.
    static let opposites: [PersonaDimension: [(String, String)]] = [
        .order: [("answer_first", "path_first")],
        .detail: [("big_picture", "detail_first")],
        .decision: [("in_the_room", "asks_for_time"), ("in_the_room", "needs_second_person")],
        .risk: [("downside_first", "upside_first")],
        .objection: [("direct", "silent_then_later"), ("direct", "by_question")],
        .pace: [("short_turns", "long_turns"), ("cuts_in", "waits")],
        .authority: [("decides_alone", "refers_up"), ("decides_alone", "group_agreement"), ("decides_alone", "refers_to_expert")],
    ]

    /// Whether a moment with value `b` is counter-evidence for a trait with value `a`, in dimension `key`.
    public static func contradicts(_ key: String, _ a: String, _ b: String) -> Bool {
        guard a != b, let d = PersonaDimension(rawValue: key) else { return false }
        return (opposites[d] ?? []).contains { ($0.0 == a && $0.1 == b) || ($0.0 == b && $0.1 == a) }
    }

    /// A dimension key and a value the model gave, as stored: a fixed key with one of its values, "expects" with a
    /// free label, or "free:<label>" with a free label. Nil for anything else.
    public static func normalized(dimension: String, value: String, label: String = "") -> (dimension: String, value: String)? {
        let d = slug(dimension), v = slug(value)
        if let fixed = PersonaDimension(rawValue: d) {
            if fixed.values.isEmpty { return v.isEmpty ? nil : (d, v) }
            return fixed.values.contains(v) ? (d, v) : nil
        }
        if d == "free" || d.hasPrefix("free_") || dimension.hasPrefix(freePrefix) {
            let name = slug(label.isEmpty ? String(dimension.dropFirst(dimension.hasPrefix(freePrefix) ? freePrefix.count : 0)) : label)
            guard !name.isEmpty, name != "free", !v.isEmpty else { return nil }
            return (freePrefix + name, v)
        }
        return nil
    }

    static func slug(_ text: String) -> String {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(5)
        return words.joined(separator: "_")
    }

    /// "answer first", for a page and for the model.
    public static func words(_ value: String) -> String { value.replacingOccurrences(of: "_", with: " ") }

    /// The title of a stored key, also a free one.
    public static func title(of key: String) -> String {
        if let d = PersonaDimension(rawValue: key) { return d.title }
        let name = words(String(key.dropFirst(freePrefix.count)))
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// Where a moment took place. Code sets it from the call: a 1:1 is the owner and one other person.
public enum PersonaSetting: String, Codable, Sendable, CaseIterable {
    case oneOnOne = "one_on_one", group

    public var words: String { self == .oneOnOne ? "in a 1:1" : "in a group" }
}

/// One moment that shows how a person acts. The model finds it; code checks that the words are a line of that
/// person in that call and keeps a pointer to the line, never a copy of the words: when the meeting is deleted,
/// the quote goes with it.
public struct PersonaEvidence: Codable, Equatable, Hashable, Sendable {
    public enum Strength: String, Codable, Sendable { case clear, weak }
    public enum Role: String, Codable, Sendable, CaseIterable { case decides, advises, doesTheWork = "does_the_work", informed }

    public var callID: String
    /// The start of the call.
    public var date: Date
    public var pointer: PersonaPointer
    public var dimension: String
    public var value: String
    public var strength: Strength
    public var role: Role?
    public var setting: PersonaSetting
    /// The call's series (its title as a key) and its topic tags: support from one topic can be the topic's doing.
    public var series: String
    public var tags: [String]
    /// The prompt's version, so a later prompt can replace only its own evidence.
    public var version: Int

    public init(callID: String, date: Date, pointer: PersonaPointer, dimension: String, value: String, strength: Strength, role: Role? = nil,
                setting: PersonaSetting, series: String, tags: [String] = [], version: Int = PersonaExtractor.promptVersion) {
        self.callID = callID
        self.date = date
        self.pointer = pointer
        self.dimension = dimension
        self.value = value
        self.strength = strength
        self.role = role
        self.setting = setting
        self.series = series
        self.tags = tags
        self.version = version
    }

    /// Days since 1970 in UTC: two calls on one day are one, on each device the same.
    var day: Int { Int((date.timeIntervalSince1970 / 86_400).rounded(.down)) }
}

/// Where a person's words are: the call, the time, and a short hash of the line. The words themselves are read
/// from the call's record when a page shows them.
public struct PersonaPointer: Codable, Equatable, Hashable, Sendable {
    public var callID: String
    public var at: TimeInterval
    /// The first 12 hex characters of the SHA-256 of the line's words, lowercased and with single spaces.
    public var line: String

    public init(callID: String, at: TimeInterval, line: String) {
        self.callID = callID
        self.at = at
        self.line = line
    }

    public init(callID: String, utterance: Utterance) {
        self.init(callID: callID, at: utterance.start, line: Self.hash(utterance.text))
    }

    static func hash(_ text: String) -> String {
        let plain = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return SHA256.hash(data: Data(plain.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The line it points to, when the record still has it: the same words, at that time if it can.
    public func utterance(in record: CallRecord) -> Utterance? {
        guard record.id == callID else { return nil }
        let same = record.utterances.filter { Self.hash($0.text) == line }
        return same.min { abs($0.start - at) < abs($1.start - at) }
    }

    /// The line, only while its speaker is still that person: a voice named again as someone else gives none.
    public func utterance(in record: CallRecord, person: String, saved: CoachPeople) -> Utterance? {
        guard record.id == callID else { return nil }
        func isPerson(_ key: String) -> Bool {
            if let id = record.speakerPeople?[key], saved.knows(id) { return saved.canonical(id) == person }
            return record.speakerNames[key].flatMap { saved.id(of: $0) }.map(saved.canonical) == person
        }
        let same = record.utterances.filter { Self.hash($0.text) == line && isPerson($0.speakerKey) }
        return same.min { abs($0.start - at) < abs($1.start - at) }
    }

    /// `mossad://call/<id>?t=<seconds>`, to play the moment.
    public var link: URL? { URL(string: "mossad://call/\(callID)?t=\(Int(at.rounded(.down)))") }
}

/// What the model wrote about one trait: the sentence, what to do, and its rating of the moments. Written again
/// only when the evidence changed; never again after the owner confirmed it.
public struct PersonaText: Codable, Equatable, Sendable {
    public enum Rating: String, Codable, Sendable, CaseIterable { case high, medium, low }

    /// About the person, with the person's first name: "When a proposal has a number, Sam asks what it compares with."
    public var statement: String
    /// One sentence for the card: "Bring last year's figure next to each new one."
    public var soDoThis: String
    public var rating: Rating
    public var written: Date
    /// The calls for and against when it was written, to know when to write it again.
    public var calls: Int
    public var counter: Int
    /// Why the word check refused the sentence, by reason ("topic: freight", "number"). Nil when it passed.
    public var refused: [String]?

    public init(statement: String, soDoThis: String, rating: Rating, written: Date, calls: Int, counter: Int) {
        self.statement = statement
        self.soDoThis = soDoThis
        self.rating = rating
        self.written = written
        self.calls = calls
        self.counter = counter
    }
}

/// What the coach knows about how one person thinks: the moments, and the sentences the model wrote about groups
/// of them. One file for each person id, in `~/Mossad/Coach/people/<id>.json`. Traits are not stored: code makes
/// them from the evidence and the owner's answers each time (`PersonaTraits`).
public struct Persona: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = Persona.currentVersion
    public var person: String
    public var evidence: [PersonaEvidence] = []
    /// By trait id.
    public var texts: [String: PersonaText] = [:]
    public var updated: Date

    public init(person: String, updated: Date) {
        self.person = person
        self.updated = updated
    }

    enum CodingKeys: String, CodingKey { case version, person, evidence, texts, updated }

    /// One entry of a later shape is left out; the rest stays.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        person = try c.decode(String.self, forKey: .person)
        evidence = try c.decodeIfPresent(LossyArray<PersonaEvidence>.self, forKey: .evidence)?.values ?? []
        texts = (try? c.decodeIfPresent([String: PersonaText].self, forKey: .texts)) ?? [:]
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? .distantPast
    }

    /// The calls with evidence.
    public var calls: Set<String> { Set(evidence.map(\.callID)) }

    /// A call read again replaces its own evidence, and only that.
    public mutating func replace(callID: String, with new: [PersonaEvidence], at date: Date) {
        evidence.removeAll { $0.callID == callID }
        evidence += new.filter { $0.callID == callID }
        evidence.sort { ($0.date, $0.pointer.at) < ($1.date, $1.pointer.at) }
        updated = date
    }
}
