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
    /// The id of this person in the people store, when the name is one saved person on a sure match. The key in
    /// `CoachProfile.people` is then only the person's name of the time: the id says who it is.
    public var person: String?

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
    /// The id of the saved person the fact is about, on a sure match only. The words can name them any way.
    public var person: String?

    public init(kind: Kind, text: String, date: Date? = nil, person: String? = nil) {
        self.kind = kind
        self.text = text
        self.date = date
        self.person = person
    }
}

/// A standing instruction the coach learned from the owner, such as "Fillers do not matter to me."
public struct CoachGuidance: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var id: String { text }
    public var text: String
    public var date: Date
    /// For the reason the owner gave for a no to a card: the card's id, its skill, and the id of its person.
    public var finding: String? = nil
    public var skill: String? = nil
    public var person: String? = nil
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
    /// The owner's answers to the cards of the findings deck: see `CoachTraining`.
    public var answers: [FindingAnswer] = []

    /// The version of `CoachSkill` that the advice log was last read against. 0 for a memory from before the
    /// log: the runner then fills the log one time from the review files.
    public var adviceVersion = 0

    public static let ratedLimit = 30
    public static let guidanceLimit = 25
    /// The newest entries stay. The rules read the last 30 days; at 5 calls a day this is some months.
    public static let adviceLimit = 600
    public static let observationLimit = 1000
    /// Past this many, the pattern that was seen longest ago goes. The model is told the newest ones only.
    public static let patternLimit = 30
    /// A pattern that no call showed for this long is not a pattern of now.
    public static let patternDays = 30.0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case summary, focus, patterns, people, history, guidance, rated, facts, forgotten, foci, voice, questions, advice, observations, adviceVersion
        case answers
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
        // An entry that a later build wrote in another shape is left out. The other entries stay: one entry
        // must not empty a log that the next save would then write.
        advice = try c.decodeIfPresent(LossyArray<CoachAdvice>.self, forKey: .advice)?.values ?? []
        observations = try c.decodeIfPresent(LossyArray<CoachObservation>.self, forKey: .observations)?.values ?? []
        adviceVersion = try c.decodeIfPresent(Int.self, forKey: .adviceVersion) ?? 0
        answers = try c.decodeIfPresent(LossyArray<FindingAnswer>.self, forKey: .answers)?.values ?? []
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
            facts.append(CoachFact(kind: fact.kind, text: text, date: date, person: fact.person))
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
            guard let old = facts[key] else { facts[key] = f; continue }
            var keep = (old.date ?? .distantPast) <= (f.date ?? .distantPast) ? f : old
            // A copy that a build from before person ids saved has none: the other copy's id stays.
            keep.person = keep.person ?? old.person ?? f.person
            facts[key] = keep
        }
        out.facts = (self.facts + other.facts).compactMap { f in
            let key = "\(f.kind.rawValue):\(f.text.lowercased())"
            return facts.removeValue(forKey: key)
        }
        var guidance: [String: CoachGuidance] = [:]
        for g in self.guidance + other.guidance where kept(g.text, g.date) {
            guard let old = guidance[g.text.lowercased()] else { guidance[g.text.lowercased()] = g; continue }
            var keep = old.date <= g.date ? g : old
            keep.finding = keep.finding ?? old.finding ?? g.finding
            keep.skill = keep.skill ?? old.skill ?? g.skill
            keep.person = keep.person ?? old.person ?? g.person
            guidance[g.text.lowercased()] = keep
        }
        out.guidance = (self.guidance + other.guidance).compactMap { guidance.removeValue(forKey: $0.text.lowercased()) }
        var rated: [String: RatedPoint] = [:]
        for r in self.rated + other.rated where (rated["\(r.callID)|\(r.title)"]?.date ?? .distantPast) <= r.date { rated["\(r.callID)|\(r.title)"] = r }
        out.rated = Array(rated.values.sorted { $0.date < $1.date }.suffix(Self.ratedLimit))
        // The owner answers proposals on either device, so foci merge by their own dates, not by who coaches.
        out.foci = Self.mergedFoci(foci, other.foci)
        out.questions = Self.mergedQuestions(questions, other.questions)
        // The owner answers cards on either device.
        out.answers = Self.mergedAnswers(answers, other.answers)
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
    /// `ids` gives the person id of a name in this call, where the name is one saved person on a sure match: the
    /// note then goes to that person, under whatever name an earlier call wrote it.
    public mutating func apply(_ update: CoachProfileUpdate, review: CoachReview, callID: String, title: String, at: Date,
                               proposal: CoachFocus? = nil, advice said: [CoachAdvice] = [], people ids: [String: String] = [:]) {
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
        if patterns.count > Self.patternLimit {
            let gone = Set(patterns.sorted { $0.lastSeen < $1.lastSeen }.prefix(patterns.count - Self.patternLimit).map(\.name))
            patterns.removeAll { gone.contains($0.name) }
        }
        advice.removeAll { $0.callID == callID }
        advice = Array((advice + said).sorted { $0.date < $1.date }.suffix(Self.adviceLimit))
        for p in update.people {
            guard let note = p.note.nonBlank else { continue }
            let id = ids[p.name]
            // The same person under an earlier name: the note moves to the name of now.
            if let id, people[p.name]?.person != id, let old = people.first(where: { $0.value.person == id })?.key {
                let moved = people.removeValue(forKey: old)
                if people[p.name] == nil { people[p.name] = moved }
            }
            var person = CoachPerson(note: note, calls: (people[p.name]?.calls ?? 0) + 1, lastSeen: at)
            person.brief = people[p.name]?.brief
            person.person = id ?? people[p.name]?.person
            people[p.name] = person
        }
        // A call reviewed again replaces its earlier entry.
        history.removeAll { $0.callID == callID }
        history.append(CoachHistoryEntry(callID: callID, title: title, date: at, headline: review.headline,
                                         focusProgress: review.focusResult?.evidence ?? review.focusProgress, delivery: review.delivery, value: review.value?.rating,
                                         score: review.scorecard?.score))
        history = Array(history.suffix(Self.historyLimit))
    }

    /// Fills the advice log one time from what the reviews showed before the log existed. Entries that a
    /// review of this build already wrote stay; an older entry of the same call does not come twice.
    public mutating func seed(_ entries: [CoachAdvice]) {
        let have = Set(advice.map(\.callID))
        advice = Array((advice + entries.filter { !have.contains($0.callID) }).sorted { $0.date < $1.date }.suffix(Self.adviceLimit))
        adviceVersion = CoachSkill.version
    }

    /// Removes what the memory holds of a deleted meeting: its lines, its moments, its place in the history,
    /// its results on a focus, and the questions from it that wait for an answer. What the owner confirmed is a
    /// fact of its own and stays, and so do the names of patterns and the notes on people.
    public mutating func forget(callID: String) {
        advice.removeAll { $0.callID == callID }
        observations.removeAll { $0.callID == callID }
        history.removeAll { $0.callID == callID }
        for i in foci.indices { foci[i].results.removeAll { $0.callID == callID } }
        questions.removeAll { $0.callID == callID && $0.status == .open }
        // What the owner blocked for good is the owner's decision, like a fact: it stays.
        answers.removeAll { $0.callID == callID && $0.verdict != .never }
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
        standing(pattern, evidence: evidence(for: pattern), now: now)
    }

    /// The standing of each pattern by its name, with one pass over the log: for a list of all patterns.
    public func standings(now: Date = Date()) -> [String: String] {
        let byName = Dictionary(grouping: observations) { $0.pattern.lowercased() }
        return Dictionary(patterns.map { ($0.name, standing($0, evidence: byName[$0.name.lowercased()] ?? [], now: now)) }, uniquingKeysWith: { a, _ in a })
    }

    private func standing(_ pattern: CoachPattern, evidence all: [CoachObservation], now: Date) -> String {
        let day = Date.FormatStyle().month(.abbreviated).day()
        guard now.timeIntervalSince(pattern.lastSeen) <= Self.patternDays * 86_400 else { return "Not seen since \(pattern.lastSeen.formatted(day))." }
        guard let first = all.map(\.date).min() else { return "Last seen on \(pattern.lastSeen.formatted(day))." }
        let own: CoachObservation.Result = pattern.kind == .strength ? .did : .missed
        let calls = Set(all.map(\.callID)).count, showed = Set(all.filter { $0.result == own }.map(\.callID)).count
        return "In \(showed) of \(calls) calls since \(first.formatted(day)). Last on \(pattern.lastSeen.formatted(day))."
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
