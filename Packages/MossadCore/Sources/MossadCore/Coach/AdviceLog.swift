import Foundation

/// Something the coach said in a review, or a call that showed earlier advice again and was only counted.
/// The log of these is the coach's memory of its own words: it is what stops the same advice after each call.
public struct CoachAdvice: Codable, Equatable, Sendable, Hashable {
    public var callID: String
    /// The start of the call.
    public var date: Date
    public var kind: CoachLine.Kind
    public var skill: String
    public var text: String
    public var at: TimeInterval?
    public var measure: CoachMeasure?
    /// True when the call showed earlier advice again and nothing was said: a count, with its moment.
    public var held: Bool

    public init(callID: String, date: Date, kind: CoachLine.Kind, skill: String, text: String, at: TimeInterval?, measure: CoachMeasure?, held: Bool) {
        self.callID = callID
        self.date = date
        self.kind = kind
        self.skill = skill
        self.text = text
        self.at = at
        self.measure = measure
        self.held = held
    }

    init(_ line: CoachLine, callID: String, date: Date) {
        self.init(callID: callID, date: date, kind: line.kind, skill: line.skill, text: line.text, at: line.at, measure: line.measure, held: false)
    }
}

/// When a line says what the coach said before.
public enum AdviceRules {
    /// The same thing is not said twice in this many days.
    public static let repeatDays = 30.0
    /// Advice comes back, as a count, when this many more calls showed it and this many days passed.
    public static let againCalls = 3
    public static let againDays = 7.0
    /// Two sentences with this part of their words in common say the same.
    static let sameWords = 0.75
    static let minimumWords = 3

    /// A skill's name without case, punctuation, or extra spaces.
    static func key(_ skill: String) -> String {
        let plain = String(String.UnicodeScalarView(skill.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? $0 : " " }))
        return plain.split(separator: " ").joined(separator: " ")
    }

    /// Advice and its count are one family: a count does not let the advice come again. Praise for a skill is
    /// not the advice about it: "you did it" after "try it" is news.
    private static func family(_ kind: CoachLine.Kind) -> CoachLine.Kind { kind == .again ? .tryNext : kind }

    private static func words(_ text: String) -> Set<String> { Set(key(text).split(separator: " ").filter { $0.count > 3 }.map(String.init)) }

    private static func sameWords(_ a: String, _ b: String) -> Bool {
        let x = words(a), y = words(b), least = min(x.count, y.count)
        return least >= minimumWords && Double(x.intersection(y).count) / Double(least) >= sameWords
    }

    /// The line that was said within `repeatDays` of `date`, in another call, and says the same as this one:
    /// the same skill by name, the same measured number, or nearly the same words. Nil when this one is new.
    /// The focus is the owner's own goal and its result may come each call, so a focus line is never a repeat.
    static func earlier(kind: CoachLine.Kind, skill: String, text: String, measure: CoachMeasure?, in log: [CoachAdvice], callID: String,
                        date: Date) -> CoachAdvice? {
        guard kind != .focus else { return nil }
        let name = key(skill)
        return log.filter { e in
            guard !e.held, e.callID != callID, family(e.kind) == family(kind), abs(e.date.timeIntervalSince(date)) <= repeatDays * 86_400 else { return false }
            if !name.isEmpty, key(e.skill) == name { return true }
            guard family(kind) == .tryNext else { return false }
            if let measure, e.measure == measure { return true }
            return sameWords(text, e.text) || sameWords(skill, e.text) || sameWords(text, e.skill)
        }.max { $0.date < $1.date }
    }

    /// How many calls showed the skill again since it was last said, with the call that is being reviewed, and
    /// whether that makes the count worth a line.
    static func again(after earlier: CoachAdvice, in log: [CoachAdvice], callID: String, date: Date) -> (calls: Int, due: Bool) {
        let name = key(earlier.skill)
        let held = Set(log.filter { $0.held && $0.callID != callID && key($0.skill) == name && $0.date > earlier.date && $0.date <= date }.map(\.callID))
        let calls = held.count + 1
        return (calls, calls >= againCalls && date.timeIntervalSince(earlier.date) >= againDays * 86_400)
    }

    /// The log as the review files of the last `repeatDays` give it, for a memory that has none yet: what the
    /// owner saw before the log existed must not come back either. A review from before one line has no skill
    /// names, so its advice is its own name.
    static func seed(from reviews: [(callID: String, date: Date, review: CoachReview)], now: Date) -> [CoachAdvice] {
        reviews.filter { now.timeIntervalSince($0.date) <= repeatDays * 86_400 }.sorted { $0.date < $1.date }.flatMap { item -> [CoachAdvice] in
            let r = item.review
            var lines = [r.tryNext.map { CoachLine(kind: .tryNext, note: $0) }, r.version >= CoachReview.currentVersion ? r.didWell.map { CoachLine(kind: .didWell, note: $0) } : nil]
                .compactMap { $0 }
            if let line = r.line, !lines.contains(where: { $0.kind == line.kind }) { lines.append(line) }
            return lines.map { CoachAdvice($0, callID: item.callID, date: item.date) }
        }
    }
}
