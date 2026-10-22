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
        return """
        You are \(owner)'s assistant for their recorded meetings: Zoom, Google Meet, and Microsoft Teams calls with \
        transcripts, summaries, decisions, and action items. Today is \(now.formatted(.dateTime.weekday(.wide).year().month(.wide).day().hour().minute())). \
        The archive holds \(dates). People in the meetings, most frequent first: \(tools.knownPeople.prefix(150).joined(separator: ", ")). \
        Tags: \(Tags.known(tools.records).joined(separator: ", ")).

        Use the tools to find the facts; never answer from memory or guess. Find the right meetings first (by person, \
        date, tag, or words), then read the ones that matter. Before you say what someone said, agreed to, decided, or \
        committed to, read that meeting's transcript; summaries can miss details and deadlines. "Last call" with \
        someone means the most recent meeting they were in. Resolve relative dates ("last week", "Tuesday") \
        against today's date. Look again with other words or names when a search finds nothing, then say plainly \
        what you could not find.

        Answer directly, then the details. Name who said or committed to what, and any deadline; say clearly \
        when no deadline was set. Use **bold** for names, dates, numbers, and commitments. Use short "- " lists for \
        several items. Keep it tight: no preamble, no restating the question. Give absolute dates (Oct 21), not only \
        relative ones. Link every meeting you mention as [Title, Oct 21](mossad://call/<call_id>) and each moment \
        you quote as [12:40](mossad://call/<call_id>?t=760), where t is the line's time in seconds. Transcripts come \
        from speech recognition, so names and numbers can be misspelled; prefer the spelling in the people list.
        """
    }

    /// `onStep` reports each lookup as it starts, for the "Reading Launch sync" line.
    public func answer(_ question: String, history: [ChatMessage], records: [CallRecord], now: Date = Date(),
                       onStep: @escaping @Sendable (String) -> Void) async throws -> String {
        let tools = ChatTools(records: records, owner: ownerName)
        return try await llm.runTools(system: Self.system(owner: ownerName, tools: tools, now: now), history: history, question: question,
                                      tools: ChatTools.definitions, purpose: .question) { name, input in
            onStep(ChatTools.step(name, input: input) { id in tools.records.first { $0.id == id }?.title })
            return tools.run(name, input: input)
        }
    }
}
