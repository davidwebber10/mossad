import Foundation

/// Once, when questions arrive: reads the last 30 days of calls and asks the owner up to 10 first questions,
/// so the coach does not wait weeks to learn who is who.
public struct CoachQuestionPass: Sendable {
    public static let limit = 10
    static let days = 30
    /// Enough of each summary to show who decides and what the call is for.
    static let summaryCharacters = 700

    private let llm: any LanguageModel
    private let ownerName: String

    public init(llm: any LanguageModel, ownerName: String) {
        self.llm = llm
        self.ownerName = ownerName
    }

    public func questions(records: [CallRecord], profile: CoachProfile, now: Date = Date()) async throws -> [CoachQuestion] {
        let since = now.addingTimeInterval(-Double(Self.days) * 86_400)
        let recent = records.filter { $0.status == .written && $0.start >= since && $0.start <= now }.sorted { $0.start < $1.start }
        guard !recent.isEmpty else { return [] }
        let ids = Set(recent.map(\.id))
        let out = try await llm.json(system: system, user: user(recent, profile: profile), schema: Self.schema, effort: .medium,
                                     purpose: .coach, as: Output.self)
        return out.questions.filter { ids.contains($0.call_id) }.prefix(Self.limit).map {
            CoachQuestion(statement: $0.statement, kind: $0.kind, evidence: $0.evidence, callID: $0.call_id, at: $0.at_seconds, asked: now)
        }
    }

    private var system: String {
        """
        You are \(ownerName)'s communication coach. You are about to coach their calls, and first you want to check \
        what you think you know about their world. From the calls below, write up to \(Self.limit) short claims for \
        \(ownerName) to confirm or deny: who reports to whom, who decides, what each recurring meeting is for, what \
        \(ownerName) is responsible for, and anything in a call that would change how you judge it ("You held back a \
        date in the budget call on purpose."). Only claims that would change your coaching. Each is a plain statement \
        of at most 15 words, addressed to \(ownerName) as "you". kind is relationship, role, meeting_purpose, \
        preference, or this_call. evidence is a short quote or summary line that led you there. call_id is the call \
        it came from, exactly as listed. Never repeat what is already known or marked not true. Fewer, sharper \
        claims beat many.
        """
    }

    private func user(_ recent: [CallRecord], profile: CoachProfile) -> String {
        var parts: [String] = []
        let known = profile.facts.map { "- \($0.text)" }
        if !known.isEmpty { parts.append("## Already known\n" + known.joined(separator: "\n")) }
        let asked = CoachPrompt.questionsText(profile)
        if !asked.isEmpty { parts.append("## Already asked\n" + asked) }
        parts.append("## Calls in the last \(Self.days) days\n" + recent.map { r in
            let people = Set(r.speakerNames.values).subtracting([ownerName]).sorted().joined(separator: ", ")
            var line = "call_id: \(r.id) | \(r.start.formatted(.dateTime.month(.abbreviated).day().hour().minute())) | \(r.title)"
            if !people.isEmpty { line += " | with: \(people)" }
            if let h = r.headline { line += "\n\(h)" }
            if let s = r.summary { line += "\n" + String(s.prefix(Self.summaryCharacters)) }
            return line
        }.joined(separator: "\n\n"))
        return parts.joined(separator: "\n\n")
    }

    static var schema: [String: Any] {
        Schema.object(["questions": Schema.array(Schema.object([
            "statement": Schema.string, "kind": Schema.oneOf(CoachQuestion.Kind.allCases.map(\.rawValue)),
            "evidence": Schema.string, "call_id": Schema.string, "at_seconds": Schema.nullableNumber,
        ]))])
    }

    private struct Output: Decodable {
        let questions: [Question]
    }

    private struct Question: Decodable {
        let statement, evidence, call_id: String
        let kind: CoachQuestion.Kind
        let at_seconds: Double?
    }
}
