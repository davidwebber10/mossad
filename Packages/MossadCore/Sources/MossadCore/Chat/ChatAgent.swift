import Foundation

/// A link in an answer to a meeting, and to a moment in it: `mossad://call/<call_id>?t=<seconds>`.
public struct ChatLink: Equatable, Sendable {
    public var callID: String
    public var at: TimeInterval?

    public static func parse(_ url: URL) -> ChatLink? {
        guard url.scheme == "mossad", url.host == "call" else { return nil }
        let id = url.pathComponents.dropFirst().first ?? ""
        guard !id.isEmpty else { return nil }
        let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "t" }?.value.flatMap(Double.init)
        return ChatLink(callID: id, at: t)
    }
}

/// Answers one chat message with Claude and the meeting tools: Claude decides what to look up, Mossad runs each
/// lookup on this Mac, and the loop ends when Claude answers. Earlier turns go in as plain text.
public struct ChatAgent: Sendable {
    private let llm: any LanguageModel
    private let ownerName: String

    public init(llm: any LanguageModel, ownerName: String) {
        self.llm = llm
        self.ownerName = ownerName
    }

    public init(apiKey: String, model: String = "claude-opus-5-5", session: URLSession = .shared, ownerName: String, usage: UsageLog? = nil) {
        self.init(llm: AnthropicModel(apiKey: apiKey, model: model, session: session, usage: usage), ownerName: ownerName)
    }

    static func system(owner: String, tools: ChatTools, now: Date) -> String {
        let dates = tools.records.isEmpty ? "none yet"
            : "\(tools.records.count) meetings from \(tools.records.last!.start.formatted(date: .abbreviated, time: .omitted)) to \(tools.records.first!.start.formatted(date: .abbreviated, time: .omitted))"
        var memory = ""
        if tools.paths != nil {
            memory = "\n\n## What you know about \(owner)\n\(tools.coachProfileText())"
            let recent = tools.chats.filter { $0.summary != nil }.prefix(15)
            if !recent.isEmpty {
                memory += "\n\n## Your recent conversations (read_chat for the full text)\n" + recent.map {
                    "- \($0.updated.formatted(.dateTime.month(.abbreviated).day())) \($0.title): \($0.summary!) [chat_id \($0.id.uuidString)]"
                }.joined(separator: "\n")
            }
        }
        return """
        You are \(owner)'s chief of staff and communication coach. You know their recorded meetings (Zoom, Google \
        Meet, and Microsoft Teams calls with transcripts, summaries, decisions, and action items), the coach's \
        reviews of how they communicated, what they have told you about themselves, and your earlier \
        conversations. Today is \(now.formatted(.dateTime.weekday(.wide).year().month(.wide).day().hour().minute())). \
        The archive holds \(dates). People in the meetings, most frequent first: \(tools.knownPeople.prefix(150).joined(separator: ", ")). \
        Tags: \(Tags.known(tools.records).joined(separator: ", ")).

        Use the tools to find the facts; never answer from memory or guess. Find the right meetings first (by person, \
        date, tag, or words), then read the ones that matter. Before you say what someone said, agreed to, decided, or \
        committed to, read that meeting's transcript; summaries can miss details and deadlines. "Last call" with \
        someone means the most recent meeting they were in. Resolve relative dates ("last week", "Tuesday") \
        against today's date. Look again with other words or names when a search finds nothing, then say plainly \
        what you could not find. "The coach" and "feedback" mean the coach's reviews: use coach_reviews, \
        read_coach_review, and coach_profile for them.

        As a coach, you are expert in executive communication: framing and bottom line up front, active listening, \
        questions, managing up and across, giving and taking feedback, negotiation, running and closing meetings, \
        and reading a room. Give advice that is specific to \(owner), their role, the people involved, and what \
        actually happened, with the moments to look at and the exact words to try. Look across many meetings for \
        patterns when that helps. Respect their coaching preferences. When they tell you something lasting about \
        themselves, their role, responsibilities, goals, relationships, or how they want advice, save it with \
        remember and say so in one line. Their own words and corrections outrank anything you inferred.

        Answer directly, then the details. Name who said or committed to what, and any deadline; say clearly \
        when no deadline was set. Use **bold** for names, dates, numbers, and commitments. Use short "- " lists for \
        several items. Keep it tight: no preamble, no restating the question. Give absolute dates (Oct 21), not only \
        relative ones. Link every meeting you mention as [Title, Oct 21](mossad://call/<call_id>) and each moment \
        you quote as [12:40](mossad://call/<call_id>?t=760), where t is the line's time in seconds. Transcripts come \
        from speech recognition, so names and numbers can be misspelled; prefer the spelling in the people list.\(memory)
        """
    }

    /// One or two sentences for later chats to recall: what the owner wanted, decided, or said about themselves.
    public func summarize(_ chat: Chat) async throws -> String {
        let text = chat.messages.suffix(20).map { "\($0.role == .user ? ownerName : "Assistant"): \($0.text.prefix(1_500))" }.joined(separator: "\n\n")
        let out = try await llm.json(system: """
            Summarize this conversation in at most 2 sentences (under 300 characters) so a later conversation can recall \
            it. \(ownerName)'s own words matter most: what they asked for, decided, corrected, or said about themselves \
            and their preferences. Never make anything sound further along than it was.
            """, user: text, schema: Schema.object(["summary": Schema.string]), effort: .low, purpose: .question, as: SummaryOutput.self)
        return out.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct SummaryOutput: Decodable { let summary: String }

    /// `onStep` reports each lookup as it starts, for the "Reading Launch sync" line.
    public func answer(_ question: String, history: [ChatMessage], records: [CallRecord], paths: Paths? = nil, now: Date = Date(),
                       onStep: @escaping @Sendable (String) -> Void) async throws -> String {
        let tools = ChatTools(records: records, owner: ownerName, paths: paths)
        return try await llm.runTools(system: Self.system(owner: ownerName, tools: tools, now: now), history: history, question: question,
                                      tools: paths == nil ? ChatTools.definitions : ChatTools.allDefinitions, purpose: .question) { name, input in
            onStep(ChatTools.step(name, input: input) { id in tools.records.first { $0.id == id }?.title })
            return tools.run(name, input: input)
        }
    }
}
