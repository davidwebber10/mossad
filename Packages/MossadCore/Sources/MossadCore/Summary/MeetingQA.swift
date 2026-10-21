import Foundation

/// Answers a question from the meetings: picks the relevant ones on this Mac, then asks Claude with their
/// summaries and the transcript lines around each match.
public struct MeetingQA: Sendable {
    public struct Citation: Equatable, Sendable, Hashable {
        public var callID: String
        public var at: TimeInterval?
        public var quote: String
    }

    public struct Answer: Equatable, Sendable {
        public var text: String
        public var citations: [Citation]
    }

    static let maxMeetings = 10
    static let fallbackCount = 15
    static let maxExcerptLines = 40
    /// About 50k tokens of material, well inside the context window and cheap enough to ask often.
    static let maxCharacters = 200_000
    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "about", "from", "by", "as",
        "is", "are", "was", "were", "be", "been", "do", "did", "does", "done", "have", "has", "had", "it", "its", "this",
        "that", "these", "those", "what", "when", "where", "who", "whom", "which", "why", "how", "we", "i", "me", "my",
        "you", "your", "our", "they", "them", "their", "he", "she", "his", "her", "any", "all", "there", "here", "so",
        "can", "could", "should", "would", "will", "say", "said", "tell", "talk", "talked", "meeting", "meetings", "call",
        "calls", "recently", "happened", "last", "week", "today", "yesterday", "decide", "decided",
    ]

    private let client: ClaudeJSON
    private let ownerName: String

    public init(apiKey: String, model: String = "claude-opus-5-5", session: URLSession = .shared, ownerName: String, usage: UsageLog? = nil) {
        client = ClaudeJSON(apiKey: apiKey, model: model, session: session, usage: usage, purpose: .question)
        self.ownerName = ownerName
    }

    static func terms(_ question: String) -> [String] {
        question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }

    /// The meetings that mention the question's words most, newest first on a tie; the latest ones when no word matches.
    public static func relevant(_ records: [CallRecord], question: String) -> [CallRecord] {
        let written = records.filter { $0.status == .written }
        let words = terms(question)
        func score(_ r: CallRecord) -> Int {
            let head = ([r.title, r.summary ?? "", r.headline ?? ""] + r.tags + r.topics.map { "\($0.title) \($0.summary)" }).joined(separator: " ").lowercased()
            return words.reduce(0) { total, w in
                total + (head.contains(w) ? 5 : 0) + r.utterances.filter { $0.text.lowercased().contains(w) }.count
            }
        }
        let scored = written.map { ($0, score($0)) }.filter { $0.1 > 0 }
        if scored.isEmpty { return Array(written.sorted { $0.start > $1.start }.prefix(fallbackCount)) }
        return scored.sorted { ($0.1, $0.0.start) > ($1.1, $1.0.start) }.prefix(maxMeetings).map(\.0)
    }

    /// Each meeting's facts and summary, then the matching transcript lines with one line of context.
    static func material(_ records: [CallRecord], question: String) -> String {
        let words = terms(question)
        var out: [String] = []
        var size = 0
        for r in records {
            var block = ["## call_id: \(r.id)", "Title: \(r.title)",
                         "Date: \(r.start.formatted(.dateTime.weekday(.wide).year().month(.abbreviated).day().hour().minute()))"]
            if !r.tags.isEmpty { block.append("Tags: \(r.tags.joined(separator: ", "))") }
            if let s = r.summary { block.append("Summary:\n\(s)") }
            for t in r.topics { block.append("### \(t.title)\n\(t.summary)") }
            if !r.decisions.isEmpty { block.append("Decisions:\n" + r.decisions.map { "- \($0)" }.joined(separator: "\n")) }
            if !r.actionItems.isEmpty { block.append("Action items:\n" + r.actionItems.map { "- \($0.text)" }.joined(separator: "\n")) }
            let lines = MarkdownWriter.transcript(r).split(separator: "\n").map(String.init)
            let hits = lines.indices.filter { i in words.contains { lines[i].lowercased().contains($0) } }
            var keep = Set<Int>()
            for i in hits { keep.formUnion(max(0, i - 1)...min(lines.count - 1, i + 1)) }
            let excerpt = keep.sorted().prefix(maxExcerptLines).map { lines[$0] }
            if !excerpt.isEmpty { block.append("Transcript excerpts:\n" + excerpt.joined(separator: "\n")) }
            let text = block.joined(separator: "\n")
            if size + text.count > maxCharacters { break }
            size += text.count
            out.append(text)
        }
        return out.joined(separator: "\n\n")
    }

    public func ask(_ question: String, records all: [CallRecord], now: Date = Date()) async throws -> Answer {
        let records = Self.relevant(all, question: question)
        let system = """
        You answer \(ownerName)'s questions about their own meetings, using only the meeting material given. Today \
        is \(now.formatted(.dateTime.weekday(.wide).year().month(.wide).day())). Answer directly in a few sentences \
        or a short "- " list; use **bold** for names, numbers, and dates that matter. Say who said or decided what, \
        and when. If the material does not answer the question, say so plainly and say what it does show. The \
        transcripts come from speech recognition, so names and numbers can be misspelled. Cite each fact with the \
        meeting's call_id and, when it comes from a transcript line, that line's time in seconds ([00:12:40] is 760) \
        and a short quote. Cite at most 6 places.
        """
        let schema = Schema.object([
            "answer": Schema.string,
            "citations": Schema.array(Schema.object([
                "call_id": Schema.string, "at_seconds": ["anyOf": [["type": "number"], ["type": "null"]]], "quote": Schema.string,
            ])),
        ])
        let out = try await client.call(system: system, user: "Question: \(question)\n\n\(Self.material(records, question: question))",
                                        schema: schema, as: Output.self)
        let ids = Set(records.map(\.id))
        return Answer(text: out.answer, citations: out.citations.filter { ids.contains($0.call_id) }.map {
            Citation(callID: $0.call_id, at: $0.at_seconds, quote: $0.quote)
        })
    }

    private struct Output: Decodable {
        let answer: String
        let citations: [Cite]
    }

    private struct Cite: Decodable {
        let call_id: String
        let at_seconds: Double?
        let quote: String
    }
}
