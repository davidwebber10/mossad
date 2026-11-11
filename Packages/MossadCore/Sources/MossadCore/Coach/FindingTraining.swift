import Foundation

/// What the owner's answers to the cards taught the coach, read from the log of answers each time. Nothing here
/// is stored: an answer that is taken back is gone from it at once.
///
/// - A yes or a no on a finding moves the weight of its skill by one, for `weightDays`, within `limit`.
/// - A skill at `lowered` or less waits longer before its advice can come again, and stands behind the other
///   news of a call. No number of no's blocks a skill.
/// - "No, never again" on a finding blocks its skill for good. On a goal offer it blocks that goal only.
public struct CoachTraining: Equatable, Sendable {
    /// An answer counts for this long.
    public static let weightDays = 90.0
    public static let limit = 3
    /// "A few no's": two more than the yes's.
    public static let lowered = -2
    public static let raised = 2
    /// The days a lowered skill waits longer, for each step below zero.
    public static let extraDays = 15.0

    public private(set) var weights: [String: Int] = [:]
    public private(set) var blocked: Set<String> = []
    public private(set) var blockedGoals: Set<String> = []

    public init(answers: [FindingAnswer] = [], asOf date: Date = Date()) {
        for a in answers {
            let key = AdviceRules.key(a.skill)
            guard !key.isEmpty, let verdict = a.verdict else { continue }
            switch (verdict, a.kind) {
            case (.never, .goalOffer): blockedGoals.insert(key)
            case (.never, let kind) where kind.isBehavior: blocked.insert(key)
            case (.yes, let kind) where kind.isBehavior && Self.counts(a, date): weights[key, default: 0] += 1
            case (.no, let kind) where kind.isBehavior && Self.counts(a, date): weights[key, default: 0] -= 1
            default: break
            }
        }
        weights = weights.mapValues { min(Self.limit, max(-Self.limit, $0)) }.filter { $0.value != 0 }
    }

    private static func counts(_ a: FindingAnswer, _ date: Date) -> Bool { date.timeIntervalSince(a.date) <= weightDays * 86_400 }

    public func weight(_ skill: String) -> Int { weights[AdviceRules.key(skill)] ?? 0 }
    public func isLowered(_ skill: String) -> Bool { weight(skill) <= Self.lowered }
    public func isRaised(_ skill: String) -> Bool { weight(skill) >= Self.raised }
    public func isBlocked(_ skill: String) -> Bool { blocked.contains(AdviceRules.key(skill)) }
    public func isGoalBlocked(_ skill: String) -> Bool { blockedGoals.contains(AdviceRules.key(skill)) }

    /// The days before the same advice can come again: longer for a skill that the owner said no to a few times.
    public func repeatDays(_ skill: String) -> Double { AdviceRules.repeatDays + Self.extraDays * Double(max(0, -weight(skill))) }
}

extension CoachProfile {
    /// The most answers the memory keeps. The ones with "never again" always stay.
    public static let answerLimit = 1000

    public func training(asOf date: Date = Date()) -> CoachTraining { CoachTraining(answers: answers, asOf: date) }

    /// The owner's answer to a card, when it has one that was not taken back.
    public func answer(to id: String) -> FindingAnswer? { answers.first { $0.id == id && $0.verdict != nil } }

    /// What the owner blocked for good, the newest first: for Settings, where each can be taken back.
    public var neverAgain: [FindingAnswer] { answers.filter { $0.verdict == .never }.sorted { $0.date > $1.date } }

    /// Saves the owner's answer to one card and does what it means:
    /// - a conclusion: yes makes it a fact (with its person), no drops this one card, never marks it not true;
    /// - a goal offer: yes accepts the focus, no and never dismiss it;
    /// - a finding: nothing more here. `CoachTraining` reads the log.
    public mutating func answer(_ finding: CoachFinding, _ verdict: FindingVerdict, at date: Date) {
        // A card answered again: first as it was before the earlier answer.
        if answer(to: finding.id) != nil { takeBack(finding.id, at: date) }
        let note = answers.first { $0.id == finding.id }?.note
        var entry = FindingAnswer(finding, verdict: verdict, date: date)
        entry.note = verdict == .yes ? nil : note
        answers.removeAll { $0.id == finding.id }
        answers.append(entry)
        trimAnswers()

        if finding.kind == .learning, let id = finding.questionID, let i = questions.firstIndex(where: { $0.id == id }) {
            switch verdict {
            case .yes:
                answer(id, .confirmed, note: nil, at: date)
                if let person = questions[i].person, let f = facts.firstIndex(where: { $0.text.caseInsensitiveCompare(questions[i].statement) == .orderedSame }) {
                    facts[f].person = person
                }
            case .no:
                questions[i].dismissed = date
                questions[i].updated = date
            case .never:
                answer(id, .rejected, note: nil, at: date)
            }
        }
        if finding.kind == .goalOffer, let id = finding.focusID {
            if verdict == .yes { acceptFocus(id, plan: nil, at: date) } else { dismissFocus(id, at: date) }
        }
    }

    /// Takes an answer back: Undo in the deck, and "Allow again" in Settings. The card is as it was before.
    public mutating func takeBack(_ id: String, at date: Date) {
        guard let a = answers.firstIndex(where: { $0.id == id }), let verdict = answers[a].verdict else { return }
        let entry = answers[a]
        answers[a].verdict = nil
        answers[a].note = nil
        answers[a].date = date
        let reasons = guidance.filter { $0.finding == id }.map(\.text)
        if !reasons.isEmpty { updateGuidance(add: [], remove: reasons, at: date) }

        if entry.kind == .learning, let qid = entry.questionID, let i = questions.firstIndex(where: { $0.id == qid }) {
            if verdict == .yes { updateFacts(add: [], remove: [questions[i].statement], at: date) }
            questions[i].status = .open
            questions[i].dismissed = nil
            questions[i].updated = date
        }
        if entry.kind == .goalOffer, let fid = entry.focusID, let i = foci.firstIndex(where: { $0.id == fid }) {
            foci[i].status = .proposed
            foci[i].accepted = nil
            foci[i].updated = date
            focus = activeFocus?.plan ?? ""
        }
    }

    /// Why the owner said no to a card, as guidance for that card: its skill, and its person when it is about one.
    /// A later reason for the same card replaces the earlier one. A card with no answer takes none.
    public mutating func explain(_ id: String, note: String, at date: Date) {
        guard let a = answers.firstIndex(where: { $0.id == id && $0.verdict != nil }), let words = note.nonBlank else { return }
        answers[a].note = words
        answers[a].date = max(answers[a].date, date)
        let earlier = guidance.filter { $0.finding == id }.map(\.text)
        if !earlier.isEmpty { updateGuidance(add: [], remove: earlier, at: date) }
        let text = "About \u{201C}\(answers[a].text)\u{201D}: \(words)"
        updateGuidance(add: [text], remove: [], at: date)
        guard let g = guidance.firstIndex(where: { $0.text == text }) else { return }
        guidance[g].finding = id
        guidance[g].skill = answers[a].skill.nonBlank
        guidance[g].person = answers[a].person
    }

    mutating func trimAnswers() {
        guard answers.count > Self.answerLimit else { return }
        let extra = answers.count - Self.answerLimit
        let gone = Set(answers.filter { $0.verdict != .never }.sorted { $0.date < $1.date }.prefix(extra).map(\.id))
        answers.removeAll { gone.contains($0.id) }
    }

    /// Each answer from either copy; the newer one of a card wins, also when it is a taken-back answer.
    static func mergedAnswers(_ a: [FindingAnswer], _ b: [FindingAnswer]) -> [FindingAnswer] {
        var byID: [String: FindingAnswer] = [:]
        for x in a + b where (byID[x.id]?.date ?? .distantPast) <= x.date { byID[x.id] = x }
        var seen = Set<String>()
        return (a + b).compactMap { seen.insert($0.id).inserted ? byID[$0.id] : nil }
    }
}
