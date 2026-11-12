import Foundation

/// One line of the live transcript as the chat reads it: who said it, by name where Mossad knows the voice.
public struct LiveEntry: Equatable, Sendable {
    public var time: TimeInterval
    public var who: String
    public var text: String
    public var isFinal: Bool
    /// The owner's own line: the mic, or the owner's voice in a room.
    public var mine: Bool

    public init(time: TimeInterval, who: String, text: String, isFinal: Bool, mine: Bool) {
        self.time = time
        self.who = who
        self.text = text
        self.isFinal = isFinal
        self.mine = mine
    }

    /// "[01:05] Speaker A: text", as `current_call` gives it.
    public var line: String { "\(Self.stamp(time)) \(who): \(text)" + (isFinal ? "" : " (still speaking)") }

    static func stamp(_ time: TimeInterval) -> String {
        let t = Int(max(0, time))
        return String(format: "[%02d:%02d]", t / 60, t % 60)
    }
}

/// What the chat knows of the call besides its words.
public struct LiveCallFacts: Equatable, Sendable {
    public var callID: String
    public var title: String
    public var platform: String
    public var start: Date
    /// The invite's people, by name where the invite has one.
    public var invited: [String]
    public var owner: String

    public init(callID: String, title: String, platform: String, start: Date, invited: [String], owner: String) {
        self.callID = callID
        self.title = title
        self.platform = platform
        self.start = start
        self.invited = invited
        self.owner = owner
    }
}

/// Questions that other people asked the owner and that the owner did not answer yet. A question is the owner's
/// when it names them, or when only one other voice is in the call. A reply is an owner line of two words or more
/// within a minute after it. A question is open only after the owner had some seconds to answer.
public enum LiveQuestions {
    static let replyWindow: TimeInterval = 60
    static let timeToAnswer: TimeInterval = 20
    static let limit = 5

    /// `now` is seconds into the call.
    public static func forOwner(_ entries: [LiveEntry], owner: String, now: TimeInterval) -> [LiveEntry] {
        let first = LiveTranscript.words(owner).first ?? ""
        let others = Set(entries.filter { !$0.mine }.map(\.who))
        let oneToOne = others.count == 1
        let replies = entries.filter { $0.mine && LiveTranscript.words($0.text).count >= 2 }
        let open = entries.filter { e in
            guard !e.mine, e.isFinal, e.text.contains("?"), now - e.time >= timeToAnswer else { return false }
            guard oneToOne || (!first.isEmpty && LiveTranscript.words(e.text).contains(first)) else { return false }
            return !replies.contains { $0.time > e.time && $0.time <= e.time + replyWindow }
        }
        return Array(open.suffix(limit))
    }
}

/// A quick question over the field: its short label and the question it sends.
public struct LiveChip: Equatable, Sendable, Identifiable {
    public var label: String
    public var question: String
    public var id: String { label }
}

/// The quick questions on the live call. None before anyone speaks; the last speaker's only when someone other than
/// the owner spoke; "Questions for me" only when some look unanswered.
public enum LiveChips {
    public static func chips(_ entries: [LiveEntry], owner: String, openQuestions: Int) -> [LiveChip] {
        guard !entries.isEmpty else { return [] }
        var out = [
            LiveChip(label: "What did I miss?", question: "What did I miss? Catch me up on the last few minutes."),
            LiveChip(label: "Summarize so far", question: "Summarize the call so far."),
            LiveChip(label: "Action items so far", question: "What action items came up so far, and who owns each?"),
        ]
        if let last = entries.last(where: { !$0.mine }) {
            let short = last.who.hasPrefix("Speaker ") || last.who == "Others" ? last.who : String(last.who.split(separator: " ").first ?? "")
            out.append(LiveChip(label: last.who == "Others" ? "What did they just say?" : "What did \(short) just say?",
                                question: last.who == "Others" ? "What did they just say?" : "What did \(last.who) just say?"))
        }
        if openQuestions > 0 {
            out.append(LiveChip(label: "Questions for me", question: "Which questions did people ask me that I have not answered yet?"))
        }
        return out
    }
}

/// The instructions and the call for one live question: the transcript so far word for word (after the summary of
/// the older part on a long call), the invite, and the questions that look unanswered.
public enum LiveChatPrompt {
    public static func system(facts: LiveCallFacts, entries: [LiveEntry], summary: LiveSummary?, openQuestions: [LiveEntry], now: Date) -> String {
        let owner = facts.owner
        let elapsed = max(0, now.timeIntervalSince(facts.start))
        var call = "\(facts.title) | \(facts.platform) | started \(facts.start.formatted(date: .omitted, time: .shortened)) | \(Int(elapsed / 60)) min so far"
        if !facts.invited.isEmpty { call += "\nInvited: \(facts.invited.joined(separator: ", "))" }
        var parts = ["""
        You help \(owner) during a call that is happening now. \(owner) asks you about it while it goes on. Today is \
        \(now.formatted(.dateTime.weekday(.wide).year().month(.wide).day().hour().minute())).

        Answer from the live transcript below. Say only what was said so far: never invent words, names, numbers, \
        promises, or decisions, and never guess what someone will say. When the transcript does not hold the answer, \
        say in one sentence that it has not come up so far. A line marked "(still speaking)" is not finished. The \
        live transcript comes from speech recognition, so words and names can be wrong; prefer the spelling of the \
        invite. Lines use a name where Mossad knows the voice and "Speaker A", "Speaker B" otherwise; keep those \
        labels, and when the invite and the words make a name likely, say "probably Sam" and not more. "\(owner)" \
        is the owner; "I" and "me" in a question mean \(owner). "What did I miss" means the last five minutes unless \
        they say otherwise.

        For earlier meetings ("what did Sam promise last time?"), use the tools to find and read them, and link each \
        as [Title, Oct 21](mossad://call/<call_id>).

        Be brief: \(owner) is reading this during the call. Lead with the answer. At most 80 words unless they ask \
        for everything, and at most 5 "- " items of one line each. No headings and no closing lines. Cite each moment \
        you use as [12:04](mossad://call/\(facts.callID)?t=724), where t is the line's time in seconds. When the exact \
        words matter, quote the line on its own as "> [12:04](mossad://call/\(facts.callID)?t=724) Sam: their words".

        ## The call
        \(call)
        """]
        if let summary, !summary.text.isEmpty {
            parts.append("## Earlier in the call (a summary up to \(LiveEntry.stamp(summary.through)))\n\(summary.text)")
        }
        let lines = LiveSummaryRules.verbatim(entries, summary: summary)
        parts.append("## Transcript so far (minutes:seconds into the call)\n"
                     + (entries.isEmpty ? "Nobody has said anything yet." : lines.map(\.line).joined(separator: "\n")))
        if !openQuestions.isEmpty {
            parts.append("## Questions to \(owner) that look unanswered (found by a simple rule; check the transcript)\n"
                         + openQuestions.map { "- " + $0.line }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}

/// Answers a question about the call that records now, from its live transcript, with the meeting tools for the
/// owner's history. The answer streams when the provider can.
public struct LiveChatAgent: Sendable {
    private let llm: any LanguageModel
    private let ownerName: String

    public init(llm: any LanguageModel, ownerName: String) {
        self.llm = llm
        self.ownerName = ownerName
    }

    /// The history lookups. No current_call (the transcript is in the prompt) and nothing that writes.
    static var tools: [ToolSpec] {
        ChatTools.definitions.filter { $0.name != "current_call" }
            + ChatTools.coachDefinitions.filter { ["people", "commitments"].contains($0.name) }
    }

    public func answer(_ question: String, history: [ChatMessage], facts: LiveCallFacts, entries: [LiveEntry], summary: LiveSummary?,
                       records: [CallRecord], paths: Paths? = nil, now: Date = Date(), personaTraits: Bool = true,
                       onStep: @escaping @Sendable (String) -> Void, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        let open = LiveQuestions.forOwner(entries, owner: ownerName, now: now.timeIntervalSince(facts.start))
        let system = LiveChatPrompt.system(facts: facts, entries: entries, summary: summary, openQuestions: open, now: now)
        let tools = ChatTools(records: records, owner: ownerName, paths: paths, personaTraits: personaTraits)
        return try await llm.streamTools(system: system, history: history, question: question, tools: Self.tools, purpose: .question,
                                         execute: { name, input in
            onStep(ChatTools.step(name, input: input) { id in tools.records.first { $0.id == id }?.title })
            return tools.run(name, input: input)
        }, onText: onText)
    }
}
