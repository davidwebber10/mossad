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

/// What one call showed of a pattern. Each call adds one; none replaces another, so the moments stay.
public struct CoachObservation: Codable, Equatable, Sendable, Hashable {
    /// `did` when the call showed the good behavior, `missed` when it showed the habit to change.
    public enum Result: String, Codable, Sendable, CaseIterable { case did, missed }

    public var callID: String
    public var date: Date
    /// The pattern's name, as the memory lists it.
    public var pattern: String
    public var result: Result
    public var note: String
    /// The owner's own words only, found in the transcript by code.
    public var quote: String?
    public var at: TimeInterval?

    public init(callID: String, date: Date, pattern: String, result: Result, note: String, quote: String? = nil, at: TimeInterval? = nil) {
        self.callID = callID
        self.date = date
        self.pattern = pattern
        self.result = result
        self.note = note
        self.quote = quote
        self.at = at
    }
}

public struct CoachPatternUpdate: Codable, Equatable, Sendable {
    public var name: String
    public var kind: CoachPattern.Kind
    /// What this call showed, in one sentence.
    public var note: String
    /// The model's own view of a trend, from before the log. Not used: code counts.
    public var trend: CoachPattern.Trend
    /// Nil from a review before the log: the call showed the pattern, as its kind says.
    public var result: CoachObservation.Result?
    public var quote: String?
    public var at: TimeInterval?

    public init(name: String, kind: CoachPattern.Kind, note: String, trend: CoachPattern.Trend = .steady, result: CoachObservation.Result? = nil,
                quote: String? = nil, at: TimeInterval? = nil) {
        self.name = name
        self.kind = kind
        self.note = note
        self.trend = trend
        self.result = result
        self.quote = quote
        self.at = at
    }

    /// What the call showed: the habit itself unless the model said the opposite.
    var shown: CoachObservation.Result { result ?? (kind == .strength ? .did : .missed) }
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
    /// What the coach said, and the calls that showed earlier advice again: see `AdviceRules`.
    public var advice: [CoachAdvice] = []
    /// What each call showed of each pattern, oldest first. Entries are added and never rewritten.
    public var observations: [CoachObservation] = []

    public static let ratedLimit = 30
    public static let guidanceLimit = 25
    /// About a year of calls. The rules read the last 30 days.
    public static let adviceLimit = 400
    public static let observationLimit = 1000
    /// A pattern that no call showed for this long is not a pattern of now.
    public static let patternDays = 30.0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case summary, focus, patterns, people, history, guidance, rated, facts, forgotten, foci, voice, questions, advice, observations
    }

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
        // A log that a later build wrote in another shape is an empty log here, not a memory that cannot be read.
        advice = (try? c.decodeIfPresent([CoachAdvice].self, forKey: .advice)) ?? []
        observations = (try? c.decodeIfPresent([CoachObservation].self, forKey: .observations)) ?? []
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
    /// counts only for the focus they accepted. The memory adds: a call gives each pattern one observation and
    /// the log its lines, and it does not rewrite the summary or what a pattern is.
    public mutating func apply(_ update: CoachProfileUpdate, review: CoachReview, callID: String, title: String, at: Date,
                               proposal: CoachFocus? = nil, advice said: [CoachAdvice] = []) {
        // One call says little about a person. The summary is written across calls, not by each of them.
        if summary.nonBlank == nil, let s = update.summary.nonBlank { summary = s }
        // Older coaching (before agreed foci) set the focus text directly.
        if foci.isEmpty, let f = update.focus.nonBlank { focus = f }
        if let id = review.focusID, let result = review.focusResult { record(result, focus: id) }
        if let proposal, proposedFocus == nil { propose(proposal, at: at) }
        // A call reviewed again replaces its own entries, and only those.
        let again = observations.contains { $0.callID == callID }
        observations.removeAll { $0.callID == callID }
        for p in update.patterns {
            let shows = p.shown == (p.kind == .strength ? .did : .missed)
            if let i = patterns.firstIndex(where: { $0.name.caseInsensitiveCompare(p.name) == .orderedSame }) {
                if shows {
                    if !again { patterns[i].seen += 1 }
                    patterns[i].lastSeen = max(patterns[i].lastSeen, at)
                }
            } else {
                patterns.append(CoachPattern(name: p.name, kind: p.kind, note: p.note, seen: shows ? 1 : 0, firstSeen: at, lastSeen: at, trend: .steady))
            }
            let name = patterns.first { $0.name.caseInsensitiveCompare(p.name) == .orderedSame }?.name ?? p.name
            observations.append(CoachObservation(callID: callID, date: at, pattern: name, result: p.shown, note: p.note, quote: p.quote, at: p.at))
        }
        observations = Array(observations.sorted { $0.date < $1.date }.suffix(Self.observationLimit))
        advice.removeAll { $0.callID == callID }
        advice = Array((advice + said).sorted { $0.date < $1.date }.suffix(Self.adviceLimit))
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

    /// Removes what the memory holds of a deleted meeting: its lines, its moments, and its place in the history.
    public mutating func forget(callID: String) {
        advice.removeAll { $0.callID == callID }
        observations.removeAll { $0.callID == callID }
        history.removeAll { $0.callID == callID }
    }

    /// What the log holds of one pattern, the newest first.
    public func evidence(for pattern: CoachPattern) -> [CoachObservation] {
        observations.filter { $0.pattern.caseInsensitiveCompare(pattern.name) == .orderedSame }.sorted { $0.date > $1.date }
    }

    /// In how many of the calls that the log has for a pattern the call showed it. A call that showed the good
    /// behavior in place of a habit is a call, and not one that showed the habit.
    public func count(_ pattern: CoachPattern) -> (calls: Int, showed: Int) {
        let all = evidence(for: pattern)
        let own: CoachObservation.Result = pattern.kind == .strength ? .did : .missed
        return (Set(all.map(\.callID)).count, Set(all.filter { $0.result == own }.map(\.callID)).count)
    }

    /// One line on where a pattern stands, from the log: "In 4 of 6 calls since Oct 23. Last on Nov 9." A
    /// pattern from before the log has only the day it was last seen: its old count grew each time the model
    /// used its name, and the model's own "improving" was one call's opinion.
    public func standing(_ pattern: CoachPattern, now: Date = Date()) -> String {
        let day = Date.FormatStyle().month(.abbreviated).day()
        guard now.timeIntervalSince(pattern.lastSeen) <= Self.patternDays * 86_400 else { return "Not seen since \(pattern.lastSeen.formatted(day))." }
        let n = count(pattern)
        guard n.calls > 0, let first = evidence(for: pattern).last else { return "Last seen on \(pattern.lastSeen.formatted(day))." }
        return "In \(n.showed) of \(n.calls) calls since \(first.date.formatted(day)). Last on \(pattern.lastSeen.formatted(day))."
    }

    public static func load(from dir: URL) throws -> CoachProfile {
        // A file that does not decode is moved aside and throws, so a save after it cannot replace the memory.
        try StoredFile.load(CoachProfile.self, from: dir.appendingPathComponent(fileName), decoder: .coach, recovery: .synced) ?? CoachProfile()
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
