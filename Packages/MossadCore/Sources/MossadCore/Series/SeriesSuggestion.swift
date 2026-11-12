import Foundation

/// A point the coach suggests for the next meeting of a series. Code finds each one in what Mossad already knows,
/// with its source; nothing is made up. It stays apart from the owner's own points until the owner keeps it.
public struct SeriesSuggestion: Sendable, Equatable, Identifiable, Hashable {
    public enum Kind: String, Sendable, CaseIterable, Codable {
        /// Another person's action item from the last meeting.
        case openItem
        /// One of the owner's own tasks for these people, due by the next meeting.
        case promise
        /// A decision that the meeting left open.
        case pendingDecision
        /// The owner's question that nobody answered last time.
        case unanswered
        /// The coach's goal that the owner took on.
        case goal

        /// The name of the kind for the owner, as the page and Undo say it.
        public var title: String {
            switch self {
            case .openItem: "Open action items"
            case .promise: "Your due tasks"
            case .pendingDecision: "Open decisions"
            case .unanswered: "Questions with no answer"
            case .goal: "Your coach goal"
            }
        }
    }

    /// Where the suggestion comes from: the line of a meeting, a task, or the goal.
    public struct Source: Sendable, Equatable, Hashable {
        public var callID: String?
        public var at: TimeInterval?
        public var commitment: UUID?
        /// "From Oct 14", "Your task, due Nov 3", "Your coach goal".
        public var label: String
    }

    /// The kind and the source, the same each time the suggestion is made: the answers are kept by it.
    public var key: String
    public var kind: Kind
    public var text: String
    public var source: Source
    public var id: String { key }
}

/// Which kinds of suggestion the owner wants, from their answers, by the rules of the Findings deck
/// (`CoachTraining`): a keep raises a kind, a dismiss lowers it, an answer counts for 90 days, and "never" blocks
/// the kind until the owner allows it again. A lowered kind shows no more suggestions.
public struct SuggestionTraining: Equatable, Sendable {
    public private(set) var weights: [String: Int] = [:]
    public private(set) var blocked: Set<String> = []
    public let answered: Set<String>

    public init(answers: [SuggestionAnswer], asOf date: Date = Date()) {
        answered = Set(answers.map(\.key))
        for a in answers {
            switch a.verdict {
            case .never: blocked.insert(a.kind)
            case .keep where date.timeIntervalSince(a.date) <= CoachTraining.weightDays * 86_400: weights[a.kind, default: 0] += 1
            case .dismiss where date.timeIntervalSince(a.date) <= CoachTraining.weightDays * 86_400: weights[a.kind, default: 0] -= 1
            default: break
            }
        }
        weights = weights.mapValues { min(CoachTraining.limit, max(-CoachTraining.limit, $0)) }.filter { $0.value != 0 }
    }

    public func weight(_ kind: SeriesSuggestion.Kind) -> Int { weights[kind.rawValue] ?? 0 }
    public func isLowered(_ kind: SeriesSuggestion.Kind) -> Bool { weight(kind) <= CoachTraining.lowered }
    public func isBlocked(_ kind: SeriesSuggestion.Kind) -> Bool { blocked.contains(kind.rawValue) }
    public func shows(_ kind: SeriesSuggestion.Kind) -> Bool { !isBlocked(kind) && !isLowered(kind) }
}

extension SeriesSuggestion {
    public static let limit = 5
    /// Questions shorter than this are small talk ("Can you hear me?").
    static let questionWords = 6
    static let questionsPerMeeting = 2

    /// The suggestions for the next meeting of `series`, at most `limit`, each with its source.
    ///
    /// - `records`: the meetings (only the series' own are read).
    /// - `commitments`: the owner's tasks; nil when they cannot be read, and then there are no task suggestions.
    /// - `points`: the owner's points of the series, so a suggestion they already wrote is not made again.
    /// - `goal`: the plan of the active coach goal and whether it is for 1:1s only.
    public static func make(for series: MeetingSeries, records: [CallRecord], commitments: [Commitment]?, owner: OwnerIdentity,
                            points: [NextTimePoint], answers: [SuggestionAnswer], goal: (plan: String, oneOnOne: Bool)?, now: Date = Date(),
                            calendar: Calendar = .current) -> [SeriesSuggestion] {
        let training = SuggestionTraining(answers: answers, asOf: now)
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let meetings = series.meetings.compactMap { byID[$0.id] }
        var out: [SeriesSuggestion] = []

        if let last = meetings.first {
            let ownerKeys = owner.speakerKeys(in: last)
            let ownerNames = Set(ownerKeys.compactMap { last.speakerNames[$0] })
            let words = last.utterances.map { MeetingPrep.keywords($0.text) }
            for (i, item) in last.actionItems.enumerated() {
                guard let who = item.owner?.nonBlank, !owner.isOwner(who), !ownerNames.contains(who) else { continue }
                out.append(SeriesSuggestion(key: "openItem:\(last.id):\(i)", kind: .openItem, text: "Ask \(first(who)) about: \(item.task)",
                                            source: Source(callID: last.id, at: MeetingPrep.moment(of: item.task, in: last.utterances, words: words), label: "From \(day(last.start, calendar))")))
            }
            for q in unanswered(in: last, owner: owner).prefix(questionsPerMeeting) {
                out.append(SeriesSuggestion(key: "unanswered:\(last.id):\(Int(q.start))", kind: .unanswered, text: "Ask again: \u{201C}\(q.text)\u{201D}",
                                            source: Source(callID: last.id, at: q.start, label: "No answer on \(day(last.start, calendar))")))
            }
        }

        // Decisions that say they are still open, in the last three meetings.
        for r in meetings.prefix(3) {
            for (i, d) in r.decisions.enumerated() where isPending(d.text) {
                out.append(SeriesSuggestion(key: "pendingDecision:\(r.id):\(i)", kind: .pendingDecision, text: "Close the decision: \(d.text)",
                                            source: Source(callID: r.id, at: d.at, label: "Left open on \(day(r.start, calendar))")))
            }
        }

        // The owner's open tasks from this series, or for its usual people, due by the next meeting.
        if let commitments {
            let callIDs = Set(series.meetings.map(\.id))
            let people = Set(series.usualPeople.map(PersonNames.key))
            let by = calendar.startOfDay(for: series.next?.start ?? now.addingTimeInterval(7 * 86_400)).addingTimeInterval(86_400)
            for c in commitments where !c.deleted && c.done == nil {
                guard let due = c.due, due < by else { continue }
                let here = c.callID.map(callIDs.contains) ?? false
                let toThem = c.to.map { to in people.contains(PersonNames.key(to)) || people.contains { $0.hasPrefix(PersonNames.key(to) + " ") } } ?? false
                guard here || toThem else { continue }
                let when = due < calendar.startOfDay(for: now) ? "overdue since" : "due"
                out.append(SeriesSuggestion(key: "promise:\(c.id.uuidString)", kind: .promise, text: "Update on: \(c.text)",
                                            source: Source(callID: c.callID, at: c.at, commitment: c.id, label: "Your task, \(when) \(day(due, calendar))")))
            }
        }

        if let goal, !goal.oneOnOne || series.usualPeople.count == 1 {
            out.append(SeriesSuggestion(key: "goal:\(PersonNames.key(goal.plan))", kind: .goal, text: "Your goal: \(goal.plan)",
                                        source: Source(label: "Your coach goal")))
        }

        let written = points.map { MeetingPrep.keywords($0.text) }
        let order = Kind.allCases
        return out.filter { s in
            guard training.shows(s.kind), !training.answered.contains(s.key) else { return false }
            // A point the owner already wrote is not suggested again.
            let words = MeetingPrep.keywords(s.text)
            return !written.contains { w in !w.isEmpty && Double(w.intersection(words).count) / Double(w.union(words).count) >= MeetingPrep.sameTask }
        }
        .enumerated()
        .sorted { (-training.weight($0.element.kind), order.firstIndex(of: $0.element.kind)!, $0.offset)
            < (-training.weight($1.element.kind), order.firstIndex(of: $1.element.kind)!, $1.offset) }
        .prefix(limit).map(\.element)
    }

    static func first(_ name: String) -> String { name.split(separator: " ").first.map(String.init) ?? name }

    static func day(_ date: Date, _ calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private static let pendingWords = ["pending", "tbd", "to be decided", "not yet decided", "undecided", "revisit", "deferred", "on hold",
                                       "next meeting", "next time", "parked", "open question"]

    /// A decision whose words say it is still open.
    static func isPending(_ text: String) -> Bool {
        let t = text.lowercased()
        return pendingWords.contains { t.contains($0) }
    }

    /// The owner's questions in a meeting that nobody answered: a line of the owner's that ends in a question of
    /// at least `questionWords` words, after which the owner spoke again, or nobody did.
    static func unanswered(in r: CallRecord, owner: OwnerIdentity) -> [(start: TimeInterval, text: String)] {
        let keys = owner.speakerKeys(in: r)
        guard !keys.isEmpty else { return [] }
        let lines = Transcript.interleaved(r.utterances)
        var out: [(TimeInterval, String)] = []
        for (i, u) in lines.enumerated() where keys.contains(u.speakerKey) {
            let text = u.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasSuffix("?") else { continue }
            let sentence = lastSentence(text)
            guard sentence.split(separator: " ").count >= questionWords else { continue }
            let next = lines[(i + 1)...].first { $0.start >= u.start }
            if next == nil || keys.contains(next!.speakerKey) { out.append((u.start, sentence)) }
        }
        return out
    }

    static func lastSentence(_ text: String) -> String {
        let body = String(text.dropLast())
        let cut = body.lastIndex { ".!?".contains($0) }.map { body.index(after: $0) } ?? body.startIndex
        return String(body[cut...]).trimmingCharacters(in: .whitespaces) + "?"
    }
}
