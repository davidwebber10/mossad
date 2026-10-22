import Foundation

/// Answers the owner's reply to a review, and says what to remember from it.
public struct CoachResponder: Sendable {
    public struct Answer: Equatable, Sendable {
        public var reply: String
        public var add: [String]
        public var remove: [String]
        public var addFacts: [CoachFact] = []
        public var removeFacts: [String] = []
    }

    private let llm: any LanguageModel
    private let ownerName: String

    public init(llm: any LanguageModel, ownerName: String) {
        self.llm = llm
        self.ownerName = ownerName
    }

    public func respond(to message: String, review: CoachReview, record: CallRecord, profile: CoachProfile) async throws -> Answer {
        let system = """
        You are \(ownerName)'s communication coach. They are answering your review of one of their calls. Take their \
        view seriously: they know the context, the people, and their intent better than the transcript shows. When \
        they are right, say so plainly and say what you will do differently. When you still think your point holds, \
        say why in one or two sentences, without arguing. Keep the reply short and direct, and address them as "you".
        Then decide what to remember. add_guidance holds standing instructions for future reviews, each one short, \
        specific, and written as a rule (for example "In 1:1s with Mitch, letting him lead is on purpose; do not flag \
        it."). Add one only when the reply tells you something that should change later reviews. remove_guidance \
        holds existing guidance, word for word, that this reply makes wrong. \
        add_facts holds facts about who they are that the reply states: their role, a responsibility, a goal, or a \
        relationship (such as "Mitch Haus is my direct report"). Write each as a short statement in their words. \
        remove_facts holds existing facts, word for word, that the reply makes wrong. When you add or remove \
        anything, say so briefly in the reply. Return empty lists when nothing changes.
        """
        func points(_ list: [CoachPoint], _ label: String) -> [String] {
            list.map { p in
                var line = "- \(label): \(p.title) (\(p.principle)): \(p.observation) Quote: \"\(p.quote)\""
                if let t = p.tryInstead { line += " Try: \(t)" }
                if let f = review.feedback[p.title] { line += " [They rated this \(f.agree ? "right" : "wrong")\(f.note.map { ": \($0)" } ?? "")]" }
                return line
            }
        }
        var user = ["## Your review of \(record.title), \(record.start.formatted(date: .abbreviated, time: .omitted))",
                    review.headline, review.overview]
        user += points(review.strengths, "Strength") + points(review.improvements, "Improve")
        if let v = review.value { user.append("Meeting value: \(v.rating.rawValue), \(v.action.rawValue): \(v.reason)") }
        if !profile.guidance.isEmpty { user.append("\n## Current guidance\n" + profile.guidance.map { "- \($0.text)" }.joined(separator: "\n")) }
        if !profile.facts.isEmpty { user.append("\n## What you know about them\n" + profile.facts.map { "- \($0.kind.rawValue): \($0.text)" }.joined(separator: "\n")) }
        if !review.thread.isEmpty {
            user.append("\n## Earlier in this conversation\n" + review.thread.map { "\($0.role == .user ? ownerName : "You"): \($0.text)" }.joined(separator: "\n"))
        }
        user.append("\n## \(ownerName) says\n\(message)")
        let fact = Schema.object(["kind": Schema.oneOf(CoachFact.Kind.allCases.map(\.rawValue)), "text": Schema.string])
        let schema = Schema.object(["reply": Schema.string, "add_guidance": Schema.array(Schema.string), "remove_guidance": Schema.array(Schema.string),
                                    "add_facts": Schema.array(fact), "remove_facts": Schema.array(Schema.string)])
        let out = try await llm.json(system: system, user: user.joined(separator: "\n"), schema: schema, effort: .medium, purpose: .coach, as: Output.self)
        return Answer(reply: out.reply, add: out.add_guidance, remove: out.remove_guidance, addFacts: out.add_facts ?? [], removeFacts: out.remove_facts ?? [])
    }

    private struct Output: Decodable {
        let reply: String
        let add_guidance: [String]
        let remove_guidance: [String]
        let add_facts: [CoachFact]?
        let remove_facts: [String]?
    }
}
