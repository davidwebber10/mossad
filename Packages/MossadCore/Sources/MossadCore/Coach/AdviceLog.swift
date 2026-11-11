import Foundation

/// Something the coach wrote in a review, or a call that showed earlier advice again and was only counted.
/// The log of these is the coach's memory of its own words: it is what stops the same advice after each call.
public struct CoachAdvice: Codable, Equatable, Sendable, Hashable {
    public var callID: String
    /// The start of the call.
    public var date: Date
    public var kind: CoachLine.Kind
    /// The skill's id (`CoachSkill.id`), or the id of a number or a trend.
    public var skill: String
    public var text: String
    public var at: TimeInterval?
    /// True when the call showed earlier advice again and nothing was said: a count, with its moment.
    public var held: Bool
    /// False for a note that waits in the full review: the owner did not get it as the line, so it is not
    /// "said", and it can still be the line of a later call.
    public var shown: Bool

    public init(callID: String, date: Date, kind: CoachLine.Kind, skill: String, text: String, at: TimeInterval?, held: Bool = false, shown: Bool = true) {
        self.callID = callID
        self.date = date
        self.kind = kind
        self.skill = skill
        self.text = text
        self.at = at
        self.held = held
        self.shown = shown
    }

    init(_ line: CoachLine, callID: String, date: Date, shown: Bool = true) {
        self.init(callID: callID, date: date, kind: line.kind, skill: line.skill, text: line.text, at: line.at, shown: shown)
    }

    enum CodingKeys: String, CodingKey { case callID, date, kind, skill, text, at, held, shown }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callID = try c.decode(String.self, forKey: .callID)
        date = try c.decode(Date.self, forKey: .date)
        kind = try c.decode(CoachLine.Kind.self, forKey: .kind)
        skill = try c.decode(String.self, forKey: .skill)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        at = try c.decodeIfPresent(TimeInterval.self, forKey: .at)
        held = try c.decodeIfPresent(Bool.self, forKey: .held) ?? false
        shown = try c.decodeIfPresent(Bool.self, forKey: .shown) ?? true
    }

    /// The number the app counts for this advice, from its skill.
    public var measure: CoachMeasure? { CoachSkill(id: skill)?.measure }
}

/// When a line says what the coach said before. The same skill is the same advice, whatever the words are:
/// the model tags each note with a key of `CoachSkill`, and code compares the keys.
public enum AdviceRules {
    /// The same thing is not said twice in this many days.
    public static let repeatDays = 30.0
    /// Advice that more calls show comes back as a count when this many more calls showed it.
    public static let againCalls = 3
    /// The days from the last line about a skill to its first count, and from the first count to the second.
    /// There is no third: the count stops, and after `repeatDays` without a line the advice itself can come again.
    public static let againDays = [7.0, 14.0]

    /// A name without case, punctuation, or extra spaces.
    static func key(_ skill: String) -> String {
        let plain = String(String.UnicodeScalarView(skill.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? $0 : " " }))
        return plain.split(separator: " ").joined(separator: " ")
    }

    /// Advice and its count are one family: a count does not let the advice come again. Praise for a skill is
    /// not the advice about it: "you did it" after "try it" is news.
    private static func family(_ kind: CoachLine.Kind) -> CoachLine.Kind { kind == .again ? .tryNext : kind }

    private static func near(_ e: CoachAdvice, _ kind: CoachLine.Kind, _ skill: String, _ callID: String, _ date: Date) -> Bool {
        e.callID != callID && family(e.kind) == family(kind) && key(e.skill) == key(skill) && abs(e.date.timeIntervalSince(date)) <= repeatDays * 86_400
    }

    /// The newest line about this skill that the owner got within `repeatDays` of `date`, in another call. Nil
    /// when this one is new. The focus is the owner's own goal and its result may come each call, so a focus
    /// line is never a repeat.
    static func earlier(kind: CoachLine.Kind, skill: String, in log: [CoachAdvice], callID: String, date: Date) -> CoachAdvice? {
        guard kind != .focus, !key(skill).isEmpty else { return nil }
        return log.filter { !$0.held && $0.shown && near($0, kind, skill, callID, date) }.max { $0.date < $1.date }
    }

    /// True when a note about this skill already waits in the full review of another call of the last
    /// `repeatDays`. It can become the line, but it is not written into a second full review.
    static func waits(kind: CoachLine.Kind, skill: String, in log: [CoachAdvice], callID: String, date: Date) -> Bool {
        log.contains { !$0.held && !$0.shown && near($0, kind, skill, callID, date) }
    }

    /// How many calls showed the skill again since its last line, with the call that is being reviewed, of how
    /// many calls the coach reviewed since then, and whether that makes the count worth a line.
    static func again(after earlier: CoachAdvice, in log: [CoachAdvice], reviewed: [CoachHistoryEntry], callID: String, date: Date) -> (calls: Int, of: Int, due: Bool) {
        let name = key(earlier.skill)
        func after(_ d: Date) -> Bool { d > earlier.date && d <= date }
        let calls = Set(log.filter { $0.held && $0.callID != callID && key($0.skill) == name && after($0.date) }.map(\.callID)).count + 1
        let of = max(calls, reviewed.filter { $0.callID != callID && after($0.date) }.count + 1)
        // The counts since the advice itself was last said.
        let own = log.filter { !$0.held && $0.shown && key($0.skill) == name && $0.date <= date }
        let advised = own.filter { $0.kind == .tryNext }.map(\.date).max() ?? .distantPast
        let counts = own.filter { $0.kind == .again && $0.date > advised }.count
        guard calls >= againCalls, counts < againDays.count else { return (calls, of, false) }
        return (calls, of, date.timeIntervalSince(earlier.date) >= againDays[counts] * 86_400)
    }

    /// The log, with the focus that waits for the owner's answer as advice that was said: the proposal is that
    /// advice, in Settings and under the review that made it.
    static func said(_ profile: CoachProfile) -> [CoachAdvice] {
        guard let p = profile.proposedFocus else { return profile.advice }
        return profile.advice + [CoachAdvice(callID: "focus:\(p.id.uuidString)", date: p.proposed, kind: .tryNext, skill: p.skillID, text: p.plan, at: nil)]
    }

    /// The log as the review files of the last `repeatDays` give it, for a memory from before the log: what the
    /// owner saw then must not come back either. A review from before the skill list has no keys, so its advice
    /// gets one from its words by the fixed rules of `CoachSkill.infer`.
    static func seed(from reviews: [(callID: String, date: Date, review: CoachReview)], now: Date) -> [CoachAdvice] {
        reviews.filter { now.timeIntervalSince($0.date) <= repeatDays * 86_400 }.sorted { $0.date < $1.date }.flatMap { item -> [CoachAdvice] in
            let r = item.review
            guard r.version < CoachReview.currentVersion else {
                // A review with one line: its line was shown, and the rest waits in its full review.
                let shown = r.line.map { [CoachAdvice($0, callID: item.callID, date: item.date)] } ?? []
                return shown + r.others.filter { $0.kind != .again }.map { CoachAdvice($0, callID: item.callID, date: item.date, shown: false) }
            }
            // An older review showed its advice below the call.
            guard let line = r.shownLine, line.kind == .tryNext else { return [] }
            return [CoachAdvice(callID: item.callID, date: item.date, kind: .tryNext, skill: CoachSkill.seedID(line.text), text: line.text, at: line.at)]
        }
    }
}

/// An array from a file where one entry that does not decode is left out, and the others stay. A log is added
/// to for months: one entry from a later build must not empty it.
struct LossyArray<Element: Decodable>: Decodable {
    private struct Anything: Decodable {}
    var values: [Element] = []

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        while !c.isAtEnd {
            if let v = try? c.decode(Element.self) { values.append(v) } else if (try? c.decode(Anything.self)) == nil { break }
        }
    }
}
