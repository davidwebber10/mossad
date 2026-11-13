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

    /// `liveHistory`: some earlier answers of this chat came during the call, from the live transcript.
    static func system(owner: String, tools: ChatTools, now: Date, about callID: String? = nil, liveHistory: Bool = false) -> String {
        var focus = ""
        if let callID, let text = tools.readMeeting(callID) {
            focus = """


            ## This chat is about one meeting
            \(owner) opened this chat from the meeting below. "This meeting", "the call", "they", and "we" refer to it \
            unless they say otherwise. Answer from it first; use the tools for other meetings only when asked or when \
            it helps.
            \(text)
            """
        }
        if liveHistory {
            focus += """


            ## Answers from during the call
            Some earlier answers in this chat were given during the call, from the live transcript: their names and \
            "Speaker" letters were not final and may not match this meeting's note. The note's names and letters are right.
            """
        }
        return base(owner: owner, tools: tools, now: now) + focus
    }

    private static func base(owner: String, tools: ChatTools, now: Date) -> String {
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
        read_coach_review, and coach_profile for them. "What I promised", "what I owe", "my tasks", and "my commitments" mean \
        the commitments tool: those are the owner's own promises, tracked with due dates.

        As a coach, you are expert in executive communication: framing and bottom line up front, active listening, \
        questions, managing up and across, giving and taking feedback, negotiation, running and closing meetings, \
        and reading a room. Give advice that is specific to \(owner), their role, the people involved, and what \
        actually happened, with the moments to look at and the exact words to try. Look across many meetings for \
        patterns when that helps. Respect their coaching preferences. When they tell you something lasting about \
        themselves, their role, responsibilities, goals, relationships, or how they want advice, save it with \
        remember and say so in one line. Their own words and corrections outrank anything you inferred.

        Be brief. \(owner) reads answers on a phone between meetings. Answer in under 100 words unless they ask \
        for detail ("walk me through", "everything", "the full list"). Lead with the answer in the first sentence. \
        Then add only what changes what they do: at most 5 "- " items, one line each. No headings, no sections, no \
        recap of the question or of what you looked up, no closing summary, and no offers of more help. Bold only \
        the key name, date, or number, at most three times. For coaching, give the one thing to do and the exact \
        words to say, not a list of principles. When the answer is "none" or "not found", say so in one sentence. \
        Name who committed to what and any deadline; say plainly when none was set. Give absolute dates (Oct 21), not only \
        relative ones. Link every meeting you mention as [Title, Oct 21](mossad://call/<call_id>) and each moment \
        you quote as [12:40](mossad://call/<call_id>?t=760), where t is the line's time in seconds. When the exact words \
        matter, quote the line on its own as "> [12:40](mossad://call/<call_id>?t=760) Sam: their words". Transcripts come \
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

    /// The tools of the app's own chat: every read, and with `actions` the action tools in place of the MCP's one write.
    static func tools(paths: Paths?, actions: Bool) -> [ToolSpec] {
        guard paths != nil else { return ChatTools.definitions }
        guard actions else { return ChatTools.allDefinitions }
        return ChatTools.allDefinitions.filter { $0.name != "add_next_time_point" } + ChatActions.definitions(live: false)
    }

    /// `onStep` reports each lookup as it starts, for the "Reading Launch sync" line. `actions` makes the chat able
    /// to do what the owner asks (`ChatActions`, from the owner's message); its records go on the answer.
    public func answer(_ question: String, history: [ChatMessage], records: [CallRecord], paths: Paths? = nil, now: Date = Date(),
                       about callID: String? = nil, personaTraits: Bool = true, actions: ChatActionHost? = nil,
                       onStep: @escaping @Sendable (String) -> Void) async throws -> ChatReply {
        let tools = ChatTools(records: records, owner: ownerName, paths: paths, personaTraits: personaTraits)
        let live = history.contains { $0.live == true }
        // While a call records, only the light actions, from any chat.
        let calling = actions?.liveMoment() != nil
        let doer = actions.map { ChatActions(message: question, tools: tools, host: $0, live: calling) }
        let system = Self.system(owner: ownerName, tools: tools, now: now, about: callID, liveHistory: live)
            + (doer == nil ? "" : ChatActions.prompt(owner: ownerName, live: calling))
        let offered = doer == nil ? Self.tools(paths: paths, actions: false)
            : ChatTools.allDefinitions.filter { $0.name != "add_next_time_point" } + ChatActions.definitions(live: calling)
        let text = try await llm.runTools(system: system, history: history, question: question,
                                          tools: paths == nil ? ChatTools.definitions : offered, purpose: .question) { name, input in
            onStep(ChatTools.step(name, input: input) { id in tools.records.first { $0.id == id }?.title })
            if let done = doer?.run(name, input: input) { return done }
            return tools.run(name, input: input)
        }
        return ChatReply(text: text, actions: doer?.records ?? [])
    }
}

/// An answer and what it did or proposes to do.
public struct ChatReply: Sendable {
    public var text: String
    public var actions: [ChatActionRecord]

    public init(text: String, actions: [ChatActionRecord] = []) {
        self.text = text
        self.actions = actions
    }

    /// The answer's message, with its receipts and cards.
    public func message(steps: [String]) -> ChatMessage {
        var m = ChatMessage(role: .assistant, text: text, steps: steps)
        if !actions.isEmpty { m.actions = actions }
        return m
    }
}
