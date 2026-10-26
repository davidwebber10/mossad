import Foundation

/// A conclusion the coach drew and asks the owner to confirm, such as "Mitch reports to you." The answer
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

    public init(statement: String, kind: Kind, evidence: String, callID: String?, at: TimeInterval?, asked: Date) {
        self.statement = statement
        self.kind = kind
        self.evidence = evidence
        self.callID = callID
        self.at = at
        self.asked = asked
        updated = asked
    }

    /// "Mitch reports to you." and "mitch reports to you" are the same question.
    var key: String {
        statement.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }
}

extension CoachProfile {
    /// More would turn a few good questions into homework.
    public static let openQuestionLimit = 5

    public var openQuestions: [CoachQuestion] { questions.filter { $0.status == .open } }

    /// Adds the coach's new questions, skipping any asked before in any form and any past the limit.
    public mutating func ask(_ new: [CoachQuestion]) {
        for q in new where q.statement.nonBlank != nil {
            guard openQuestions.count < Self.openQuestionLimit, !questions.contains(where: { $0.key == q.key }),
                  !facts.contains(where: { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) == q.key }) else { continue }
            questions.append(q)
        }
    }

    public mutating func answer(_ id: UUID, _ status: CoachQuestion.Status, note: String?, at date: Date) {
        guard let i = questions.firstIndex(where: { $0.id == id }) else { return }
        questions[i].status = status
        questions[i].note = note?.nonBlank
        questions[i].updated = date
        let q = questions[i]
        switch status {
        case .confirmed: updateFacts(add: [CoachFact(kind: q.kind.factKind, text: q.statement)], remove: [], at: date)
        case .corrected:
            if let note = q.note { updateFacts(add: [CoachFact(kind: q.kind.factKind, text: note)], remove: [], at: date) }
        case .open, .rejected: break
        }
    }

    static func mergedQuestions(_ a: [CoachQuestion], _ b: [CoachQuestion]) -> [CoachQuestion] {
        var byID: [UUID: CoachQuestion] = [:]
        for q in a + b where (byID[q.id]?.updated ?? .distantPast) <= q.updated { byID[q.id] = q }
        var seen = Set<UUID>()
        return (a + b).compactMap { seen.insert($0.id).inserted ? byID[$0.id] : nil }
    }
}
