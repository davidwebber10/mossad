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
        /// The meetings the answer is about, for questions that look for meetings.
        public var meetings: [String] = []
    }

    /// One earlier question and answer in the same chat.
    public struct Turn: Equatable, Sendable {
        public var question: String
        public var answer: String

        public init(question: String, answer: String) {
            self.question = question
            self.answer = answer
        }
    }

    static let maxMeetings = 10
    static let fallbackCount = 15
    static let maxExcerptLines = 40
    /// The best meetings go in with their whole transcript: "what did they agree to" needs every line.
    static let fullTranscripts = 3
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

    /// The people a question names, in the order it names them. A first name, a short form of it ("Jen" for
    /// Jennifer), a last name, or the full name all count.
    public static func people(in question: String, records: [CallRecord], owner: String? = nil) -> [String] {
        let words = question.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 && !stopWords.contains($0) }
        let names = Set(records.flatMap { Array($0.speakerNames.values) + $0.attendees.filter { !$0.contains("@") } })
            .filter { $0 != owner && !$0.hasPrefix("Speaker ") }
        func position(_ name: String) -> Int? {
            let parts = name.lowercased().split(separator: " ").map(String.init)
            if let r = question.lowercased().range(of: name.lowercased()) { return question.distance(from: question.startIndex, to: r.lowerBound) }
            for (i, w) in words.enumerated() {
                if let first = parts.first, first == w || (w.count >= 3 && first.hasPrefix(w)) { return 1_000 + i }
                if parts.count > 1, let last = parts.last, last.count >= 4, last == w { return 1_000 + i }
            }
            return nil
        }
        return names.compactMap { n in position(n).map { (n, $0) } }.sorted { ($0.1, $0.0) < ($1.1, $1.0) }.map(\.0)
    }

    /// The period a question names: today, yesterday, this or last week or month, or a weekday (the latest one).
    static func period(in question: String, now: Date, calendar: Calendar = .current) -> DateInterval? {
        let q = question.lowercased()
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> DateInterval {
            let start = calendar.date(byAdding: .day, value: offset, to: today)!
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        }
        if q.contains("yesterday") { return day(-1) }
        if q.contains("today") || q.contains("this morning") || q.contains("this afternoon") { return day(0) }
        for (unit, word) in [(Calendar.Component.weekOfYear, "week"), (.month, "month")] {
            guard let current = calendar.dateInterval(of: unit, for: now) else { continue }
            if q.contains("this \(word)") { return DateInterval(start: current.start, end: max(now, current.start)) }
            if q.contains("last \(word)") || q.contains("past \(word)") {
                return DateInterval(start: calendar.date(byAdding: unit, value: -1, to: current.start)!, end: current.start)
            }
        }
        for (i, name) in calendar.weekdaySymbols.enumerated() where q.contains(name.lowercased()) {
            for back in 0..<7 {
                let d = day(-back)
                if calendar.component(.weekday, from: d.start) == i + 1 { return d }
            }
        }
        return nil
    }

    /// The meetings a question is about: with the people it names (all of them first, newest first), in the period
    /// it names, or that mention its words most; the latest ones when nothing narrows it. A follow-up with no
    /// people of its own keeps those of the chat's earlier questions.
    public static func relevant(_ records: [CallRecord], question: String, history: [Turn] = [], now: Date = Date(), owner: String? = nil) -> [CallRecord] {
        var written = records.filter { $0.status == .written }
        if let period = period(in: question, now: now) { written = written.filter { period.contains($0.start) } }
        var named = people(in: question, records: written, owner: owner)
        if named.isEmpty, let earlier = history.reversed().lazy.map({ people(in: $0.question, records: written, owner: owner) }).first(where: { !$0.isEmpty }) {
            named = earlier
        }
        if !named.isEmpty {
            func present(_ r: CallRecord) -> Int {
                let here = Set(r.speakerNames.values).union(r.attendees)
                return named.filter { here.contains($0) }.count
            }
            return written.map { ($0, present($0)) }.filter { $0.1 > 0 }
                .sorted { ($0.1, $0.0.start) > ($1.1, $1.0.start) }.prefix(maxMeetings).map(\.0)
        }
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
        for (index, r) in records.enumerated() {
            var block = ["## call_id: \(r.id)", "Title: \(r.title)",
                         "Date: \(r.start.formatted(.dateTime.weekday(.wide).year().month(.abbreviated).day().hour().minute()))"]
            if !r.tags.isEmpty { block.append("Tags: \(r.tags.joined(separator: ", "))") }
            if let s = r.summary { block.append("Summary:\n\(s)") }
            for t in r.topics { block.append("### \(t.title)\n\(t.summary)") }
            if !r.decisions.isEmpty { block.append("Decisions:\n" + r.decisions.map { "- \($0)" }.joined(separator: "\n")) }
            if !r.actionItems.isEmpty { block.append("Action items:\n" + r.actionItems.map { "- \($0.text)" }.joined(separator: "\n")) }
            let lines = MarkdownWriter.transcript(r).split(separator: "\n").map(String.init)
            if index < fullTranscripts {
                let full = "Full transcript:\n" + lines.joined(separator: "\n")
                if size + block.joined(separator: "\n").count + full.count <= maxCharacters {
                    block.append(full)
                    let text = block.joined(separator: "\n")
                    size += text.count
                    out.append(text)
                    continue
                }
            }
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

    public func ask(_ question: String, records all: [CallRecord], history: [Turn] = [], now: Date = Date()) async throws -> Answer {
        let records = Self.relevant(all, question: question, history: history, now: now, owner: ownerName)
        let system = """
        You answer \(ownerName)'s questions about their own meetings, using only the meeting material given. Today \
        is \(now.formatted(.dateTime.weekday(.wide).year().month(.wide).day())). Answer directly in a few sentences \
        or a short "- " list; use **bold** for names, numbers, and dates that matter. Say who said or decided what, \
        and when. If the material does not answer the question, say so plainly and say what it does show. The \
        transcripts come from speech recognition, so names and numbers can be misspelled. Cite each fact with the \
        meeting's call_id and, when it comes from a transcript line, that line's time in seconds ([00:12:40] is 760) \
        and a short quote. Cite at most 6 places. For "what did X agree to" questions, list each commitment with who \
        made it and any deadline, and say plainly when no deadline was set. "Last call" with someone means the most \
        recent meeting they were in. In meetings, list the call_id of each meeting the answer is about, so the \
        person can open it; when the question asks which meetings, list them all. The chat's earlier questions are \
        given for follow-ups such as "was there a deadline?".
        """
        let schema = Schema.object([
            "answer": Schema.string,
            "meetings": Schema.array(Schema.string),
            "citations": Schema.array(Schema.object([
                "call_id": Schema.string, "at_seconds": ["anyOf": [["type": "number"], ["type": "null"]]], "quote": Schema.string,
            ])),
        ])
        let chat = history.suffix(6).map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")
        let context = (history.last?.question ?? "") + " " + question
        let out = try await client.call(system: system,
                                        user: (chat.isEmpty ? "" : "Earlier in this chat:\n\(chat)\n\n")
                                            + "Question: \(question)\n\n\(Self.material(records, question: context))",
                                        schema: schema, as: Output.self)
        let ids = Set(records.map(\.id))
        return Answer(text: out.answer, citations: out.citations.filter { ids.contains($0.call_id) }.map {
            Citation(callID: $0.call_id, at: $0.at_seconds, quote: $0.quote)
        }, meetings: (out.meetings ?? []).filter { ids.contains($0) })
    }

    private struct Output: Decodable {
        let answer: String
        let citations: [Cite]
        let meetings: [String]?
    }

    private struct Cite: Decodable {
        let call_id: String
        let at_seconds: Double?
        let quote: String
    }
}
