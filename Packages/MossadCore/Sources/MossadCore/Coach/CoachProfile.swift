import Foundation

/// A habit the coach has seen across calls.
public struct CoachPattern: Codable, Equatable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case strength, growth }
    public enum Trend: String, Codable, Sendable { case improving, steady, slipping }

    public var name: String
    public var kind: Kind
    public var note: String
    /// How many reviewed calls showed it.
    public var seen: Int
    public var firstSeen: Date
    public var lastSeen: Date
    public var trend: Trend

    public init(name: String, kind: Kind, note: String, seen: Int, firstSeen: Date, lastSeen: Date, trend: Trend) {
        self.name = name
        self.kind = kind
        self.note = note
        self.seen = seen
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.trend = trend
    }
}

/// How the owner and one person work together, from the owner's side.
public struct CoachPerson: Codable, Equatable, Sendable, Hashable {
    public var note: String
    public var calls: Int
    public var lastSeen: Date
    /// The coach's fuller read on them across calls; written separately from the reviews.
    public var brief: PersonBrief?

    public init(note: String, calls: Int, lastSeen: Date) {
        self.note = note
        self.calls = calls
        self.lastSeen = lastSeen
    }
}

public struct CoachHistoryEntry: Codable, Equatable, Sendable, Hashable {
    public var callID: String
    public var title: String
    public var date: Date
    public var headline: String
    public var focusProgress: String?
    public var delivery: DeliveryStats?
    public var value: MeetingValue.Rating?
    public var score: Int?
}

public struct CoachPatternUpdate: Codable, Equatable, Sendable {
    public var name: String
    public var kind: CoachPattern.Kind
    public var note: String
    public var trend: CoachPattern.Trend

    public init(name: String, kind: CoachPattern.Kind, note: String, trend: CoachPattern.Trend) {
        self.name = name
        self.kind = kind
        self.note = note
        self.trend = trend
    }
}

public struct CoachPersonUpdate: Codable, Equatable, Sendable {
    public var name: String
    public var note: String

    public init(name: String, note: String) {
        self.name = name
        self.note = note
    }
}

/// What the coach learned from one call, to fold into the profile.
public struct CoachProfileUpdate: Codable, Equatable, Sendable {
    public var summary: String
    public var focus: String
    public var patterns: [CoachPatternUpdate]
    public var people: [CoachPersonUpdate]

    public init(summary: String, focus: String, patterns: [CoachPatternUpdate], people: [CoachPersonUpdate]) {
        self.summary = summary
        self.focus = focus
        self.patterns = patterns
        self.people = people
    }
}

/// A point the owner rated, kept so later reviews know what landed and what missed.
public struct RatedPoint: Codable, Equatable, Sendable {
    public var callID: String
    public var callTitle: String
    public var title: String
    public var principle: String
    public var agree: Bool
    public var note: String?
    public var date: Date
}

/// Something true about the owner that the coach should judge their calls against.
public struct CoachFact: Codable, Equatable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case role, responsibility, goal, relationship
        /// Things about meetings and preferences the owner confirmed, such as "Legal approves dates first."
        case context

        public var title: String {
            switch self {
            case .role: "Your role"
            case .responsibility: "What you are responsible for"
            case .goal: "Your goals"
            case .relationship: "Your relationships"
            case .context: "Context"
            }
        }
    }

    public var id: String { "\(kind.rawValue):\(text)" }
    public var kind: Kind
    public var text: String
    /// When it was added, so a later removal on another device wins and an earlier one does not.
    public var date: Date?

    public init(kind: Kind, text: String, date: Date? = nil) {
        self.kind = kind
        self.text = text
        self.date = date
    }
}

/// A standing instruction the coach learned from the owner, such as "Fillers do not matter to me."
public struct CoachGuidance: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var id: String { text }
    public var text: String
    public var date: Date
}

/// The coach's memory across calls, kept in `~/Mossad/Coach/profile.json`. Each review reads it and updates it,
/// so advice builds on what came before instead of starting over each call.
public struct CoachProfile: Codable, Equatable, Sendable {
    public static let fileName = "profile.json"
    public static let historyLimit = 40

    /// Who the owner is as a communicator, in a few sentences.
    public var summary = ""
    /// The one thing the owner works on now.
    public var focus = ""
    public var patterns: [CoachPattern] = []
    public var people: [String: CoachPerson] = [:]
    public var history: [CoachHistoryEntry] = []
    /// What the owner told the coach about its coaching.
    public var guidance: [CoachGuidance] = []
    /// The owner's latest ratings of individual points.
    public var rated: [RatedPoint] = []
    /// Who the owner is: role, responsibilities, goals, and relationships.
    public var facts: [CoachFact] = []
    /// Removed facts and guidance by lowercased text, with when, so a sync from another device does not bring them back.
    public var forgotten: [String: Date] = [:]
    /// Every focus the coach proposed, with the owner's answer and the results per call.
    public var foci: [CoachFocus] = []
    public var voice = CoachVoice.direct
    /// Conclusions the coach asked the owner to confirm, with their answers.
    public var questions: [CoachQuestion] = []

    public static let ratedLimit = 30
    public static let guidanceLimit = 25

    public init() {}

    enum CodingKeys: String, CodingKey { case summary, focus, patterns, people, history, guidance, rated, facts, forgotten, foci, voice, questions }

    /// Profiles from before feedback existed have no guidance or ratings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        focus = try c.decodeIfPresent(String.self, forKey: .focus) ?? ""
        patterns = try c.decodeIfPresent([CoachPattern].self, forKey: .patterns) ?? []
        people = try c.decodeIfPresent([String: CoachPerson].self, forKey: .people) ?? [:]
        history = try c.decodeIfPresent([CoachHistoryEntry].self, forKey: .history) ?? []
        guidance = try c.decodeIfPresent([CoachGuidance].self, forKey: .guidance) ?? []
        rated = try c.decodeIfPresent([RatedPoint].self, forKey: .rated) ?? []
        facts = try c.decodeIfPresent([CoachFact].self, forKey: .facts) ?? []
        forgotten = try c.decodeIfPresent([String: Date].self, forKey: .forgotten) ?? [:]
        foci = try c.decodeIfPresent([CoachFocus].self, forKey: .foci) ?? []
        voice = try c.decodeIfPresent(CoachVoice.self, forKey: .voice) ?? .direct
        questions = try c.decodeIfPresent([CoachQuestion].self, forKey: .questions) ?? []
    }

    public func facts(_ kind: CoachFact.Kind) -> [CoachFact] { facts.filter { $0.kind == kind } }

    /// Adds facts without duplicates (ignoring case and spaces) and removes those named by their text.
    public mutating func updateFacts(add: [CoachFact], remove: [String], at date: Date = Date()) {
        let gone = Set(remove.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        facts.removeAll { gone.contains($0.text.lowercased()) }
        for text in gone { forgotten[text] = date }
        for fact in add {
            guard let text = fact.text.nonBlank,
                  !facts.contains(where: { $0.kind == fact.kind && $0.text.caseInsensitiveCompare(text) == .orderedSame }) else { continue }
            facts.append(CoachFact(kind: fact.kind, text: text, date: date))
            forgotten[text.lowercased()] = nil
        }
    }

    /// This profile combined with another device's copy. Facts, guidance, and ratings from both are kept,
    /// unless removed later than they were added. The coaching fields (summary, focus, patterns, people,
    /// history) come from this copy, or from the other one with `takeCoaching`: the Mac writes those.
    public func merged(with other: CoachProfile, takeCoaching: Bool = false) -> CoachProfile {
        var out = takeCoaching ? other : self
        out.forgotten = forgotten.merging(other.forgotten) { max($0, $1) }
        func kept(_ text: String, _ date: Date?) -> Bool {
            guard let removed = out.forgotten[text.lowercased()] else { return true }
            return (date ?? .distantPast) > removed
        }
        var facts: [String: CoachFact] = [:]
        for f in self.facts + other.facts where kept(f.text, f.date) {
            let key = "\(f.kind.rawValue):\(f.text.lowercased())"
            if (facts[key]?.date ?? .distantPast) <= (f.date ?? .distantPast) || facts[key] == nil { facts[key] = f }
        }
        out.facts = (self.facts + other.facts).compactMap { f in
            let key = "\(f.kind.rawValue):\(f.text.lowercased())"
            return facts.removeValue(forKey: key)
        }
        var guidance: [String: CoachGuidance] = [:]
        for g in self.guidance + other.guidance where kept(g.text, g.date) {
            if (guidance[g.text.lowercased()]?.date ?? .distantPast) <= g.date { guidance[g.text.lowercased()] = g }
        }
        out.guidance = (self.guidance + other.guidance).compactMap { guidance.removeValue(forKey: $0.text.lowercased()) }
        var rated: [String: RatedPoint] = [:]
        for r in self.rated + other.rated where (rated["\(r.callID)|\(r.title)"]?.date ?? .distantPast) <= r.date { rated["\(r.callID)|\(r.title)"] = r }
        out.rated = Array(rated.values.sorted { $0.date < $1.date }.suffix(Self.ratedLimit))
        // The owner answers proposals on either device, so foci merge by their own dates, not by who coaches.
        out.foci = Self.mergedFoci(foci, other.foci)
        out.questions = Self.mergedQuestions(questions, other.questions)
        out.focus = out.activeFocus?.plan ?? (out.foci.isEmpty ? out.focus : "")
        return out
    }

    /// Keeps the owner's rating of a point; a new rating of the same point replaces the old one.
    public mutating func remember(_ feedback: CoachFeedback, on point: CoachPoint, callID: String, title: String) {
        rated.removeAll { $0.callID == callID && $0.title == point.title }
        rated.append(RatedPoint(callID: callID, callTitle: title, title: point.title, principle: point.principle,
                                agree: feedback.agree, note: feedback.note?.nonBlank, date: feedback.date))
        rated = Array(rated.suffix(Self.ratedLimit))
    }

    public mutating func updateGuidance(add: [String], remove: [String], at date: Date) {
        let gone = Set(remove.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        guidance.removeAll { gone.contains($0.text.lowercased()) }
        for text in gone { forgotten[text] = date }
        for text in add.compactMap(\.nonBlank) where !guidance.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
            guidance.append(CoachGuidance(text: text, date: date))
            forgotten[text.lowercased()] = nil
        }
        guidance = Array(guidance.suffix(Self.guidanceLimit))
    }

    /// Folds one review in. The focus changes only through the owner: a proposal waits for them, and a result
    /// counts only for the focus they accepted.
    public mutating func apply(_ update: CoachProfileUpdate, review: CoachReview, callID: String, title: String, at: Date,
                               proposal: CoachFocus? = nil) {
        if let s = update.summary.nonBlank { summary = s }
        // Older coaching (before agreed foci) set the focus text directly.
        if foci.isEmpty, let f = update.focus.nonBlank { focus = f }
        if let id = review.focusID, let result = review.focusResult { record(result, focus: id) }
        if let proposal, proposedFocus == nil { propose(proposal, at: at) }
        for p in update.patterns {
            if let i = patterns.firstIndex(where: { $0.name.caseInsensitiveCompare(p.name) == .orderedSame }) {
                patterns[i].kind = p.kind
                patterns[i].note = p.note
                patterns[i].trend = p.trend
                patterns[i].seen += 1
                patterns[i].lastSeen = at
            } else {
                patterns.append(CoachPattern(name: p.name, kind: p.kind, note: p.note, seen: 1, firstSeen: at, lastSeen: at, trend: p.trend))
            }
        }
        for p in update.people {
            guard let note = p.note.nonBlank else { continue }
            var person = CoachPerson(note: note, calls: (people[p.name]?.calls ?? 0) + 1, lastSeen: at)
            person.brief = people[p.name]?.brief
            people[p.name] = person
        }
        // A call reviewed again replaces its earlier entry.
        history.removeAll { $0.callID == callID }
        history.append(CoachHistoryEntry(callID: callID, title: title, date: at, headline: review.headline,
                                         focusProgress: review.focusResult?.evidence ?? review.focusProgress, delivery: review.delivery, value: review.value?.rating,
                                         score: review.scorecard?.score))
        history = Array(history.suffix(Self.historyLimit))
    }

    public static func load(from dir: URL) throws -> CoachProfile {
        let url = dir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return CoachProfile() }
        return try JSONDecoder.coach.decode(CoachProfile.self, from: Data(contentsOf: url))
    }

    public func save(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.coach.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

extension String {
    var nonBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
