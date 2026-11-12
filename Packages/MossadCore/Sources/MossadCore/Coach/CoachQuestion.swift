import Foundation

/// A conclusion the coach drew and asks the owner to confirm, such as "Jordan reports to you." The answer
/// shapes how later calls are judged: a Yes becomes a fact, a correction becomes the owner's own words, and
/// a No is remembered so the coach never asks again.
public struct CoachQuestion: Codable, Equatable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case relationship, role
        case meetingPurpose = "meeting_purpose"
        case preference
        case thisCall = "this_call"

        /// Where a confirmed answer goes among the coach's facts.
        var factKind: CoachFact.Kind {
            switch self {
            case .relationship: .relationship
            case .role: .role
            case .meetingPurpose, .preference, .thisCall: .context
            }
        }
    }

    public enum Status: String, Codable, Sendable { case open, confirmed, corrected, rejected }

    public var id = UUID()
    public var statement: String
    public var kind: Kind
    /// The quote behind it, with its time.
    public var evidence: String
    public var callID: String?
    /// Seconds into that call.
    public var at: TimeInterval?
    public var status = Status.open
    /// The owner's own words when the statement was not quite right.
    public var note: String?
    public var asked: Date
    /// When asked or answered; the newer copy wins between devices.
    public var updated: Date
    /// When the owner said a plain no to its card: this one card is gone, and the question is not "not true".
    /// The coach can ask it again from another call after the days of the repeat rule.
    public var dismissed: Date?
    /// The person the conclusion is about, as the model named the speaker.
    public var about: String?
    /// The id of that person in the people store, on a sure match only, and the person's name at that time.
    public var person: String?
    public var personName: String?

    public init(statement: String, kind: Kind, evidence: String, callID: String?, at: TimeInterval?, asked: Date) {
        self.statement = statement
        self.kind = kind
        self.evidence = evidence
        self.callID = callID
        self.at = at
        self.asked = asked
        updated = asked
    }

    /// "Jordan reports to you." and "jordan reports to you" are the same question.
    var key: String {
        statement.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}

extension CoachProfile {
    /// More would turn a few good questions into homework.
    public static let openQuestionLimit = 10

    /// The questions that wait for an answer. One that got a plain no to its card does not wait.
    public var openQuestions: [CoachQuestion] { questions.filter { $0.status == .open && $0.dismissed == nil } }

    /// Adds the coach's new questions, skipping any asked before in any form and any past the limit. A question
    /// that got a plain no comes back one time when another call brings it after `AdviceRules.repeatDays`; one
    /// that the owner called not true never does.
    public mutating func ask(_ new: [CoachQuestion]) {
        for q in new where q.statement.nonBlank != nil {
            guard openQuestions.count < Self.openQuestionLimit,
                  !facts.contains(where: { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) == q.key }) else { continue }
            guard let i = questions.firstIndex(where: { $0.key == q.key }) else { questions.append(q); continue }
            guard questions[i].status == .open, let no = questions[i].dismissed, q.callID != questions[i].callID,
                  q.asked.timeIntervalSince(no) >= AdviceRules.repeatDays * 86_400 else { continue }
            var again = q
            again.id = questions[i].id
            again.updated = q.asked
            questions[i] = again
        }
    }

    public mutating func answer(_ id: UUID, _ status: CoachQuestion.Status, note: String?, at date: Date) {
        guard let i = questions.firstIndex(where: { $0.id == id }) else { return }
        questions[i].status = status
        questions[i].note = note?.nonBlank
        questions[i].updated = date
        let q = questions[i]
        // A conclusion about one call is true of that call only: no fact for the calls after it.
        guard q.kind != .thisCall else { return }
        switch status {
        case .confirmed: updateFacts(add: [CoachFact(kind: q.kind.factKind, text: q.statement)], remove: [], at: date)
        case .corrected:
            if let note = q.note { updateFacts(add: [CoachFact(kind: q.kind.factKind, text: note)], remove: [], at: date) }
        case .open, .rejected: break
        }
    }

    static func mergedQuestions(_ a: [CoachQuestion], _ b: [CoachQuestion]) -> [CoachQuestion] {
        var byID: [UUID: CoachQuestion] = [:]
        for q in a + b {
            guard let old = byID[q.id] else { byID[q.id] = q; continue }
            var keep = old.updated <= q.updated ? q : old
            // A copy that a build from before these fields saved has none: the other copy's stay.
            let other = old.updated <= q.updated ? old : q
            keep.person = keep.person ?? other.person
            keep.personName = keep.personName ?? other.personName
            keep.about = keep.about ?? other.about
            byID[q.id] = keep
        }
        var seen = Set<UUID>()
        return (a + b).compactMap { seen.insert($0.id).inserted ? byID[$0.id] : nil }
    }
}
