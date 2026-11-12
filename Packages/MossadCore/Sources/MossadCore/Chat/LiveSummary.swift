import Foundation

/// A short summary of the older part of a long call: every line before `through` seconds.
public struct LiveSummary: Equatable, Sendable {
    public var through: TimeInterval
    public var text: String

    public init(through: TimeInterval, text: String) {
        self.through = through
        self.text = text
    }
}

/// When the live chat sends a summary instead of the words. Up to `verbatimLimit` characters after the summary go
/// as they are; past that, the older lines fold into the summary until `keepVerbatim` are left, so a summary is made
/// about once for each 20,000 new characters (some 20 minutes of talk), never on each question.
public enum LiveSummaryRules {
    public static let verbatimLimit = 40_000
    public static let keepVerbatim = 20_000

    /// The lines the chat sends word for word.
    public static func verbatim(_ entries: [LiveEntry], summary: LiveSummary?) -> [LiveEntry] {
        guard let summary else { return entries }
        return entries.filter { $0.time >= summary.through }
    }

    /// Nil while the words after the summary fit; else the lines to fold in and where the new summary ends. A line
    /// still being spoken, and every line after it, stays out of the summary.
    public static func due(_ entries: [LiveEntry], summary: LiveSummary?) -> (through: TimeInterval, fold: [LiveEntry])? {
        let tail = verbatim(entries, summary: summary)
        guard tail.reduce(0, { $0 + $1.line.count + 1 }) > verbatimLimit else { return nil }
        var kept = 0, cut = tail.count
        while cut > 0, kept + tail[cut - 1].line.count + 1 <= keepVerbatim {
            cut -= 1
            kept += tail[cut].line.count + 1
        }
        if let draft = tail.firstIndex(where: { !$0.isFinal }) { cut = min(cut, draft) }
        guard cut > 0, cut < tail.count else { return nil }
        return (tail[cut].time, Array(tail[..<cut]))
    }

    /// The request that folds new lines into the summary so far.
    public static func request(old: LiveSummary?, fold: [LiveEntry], owner: String) -> (system: String, user: String) {
        let system = """
        You keep a running summary of a call that is still going on, for \(owner). Fold the new transcript lines into \
        the summary so far and return the whole new summary. Keep who said what, questions asked (and to whom), \
        numbers, dates, decisions, and promises, each with its [mm:ss] time. Keep "Speaker A" labels as they are. \
        Never add anything that was not said. At most 300 words.
        """
        var user = ""
        if let old, !old.text.isEmpty { user += "Summary so far (up to \(LiveEntry.stamp(old.through))):\n\(old.text)\n\n" }
        user += "New lines:\n" + fold.map(\.line).joined(separator: "\n")
        return (system, user)
    }
}

/// The summary of one call's older part, kept in memory while the call records and made again only when the rules
/// say. Nothing is written to disk. One request at a time; a question that comes meanwhile waits for it.
public actor LiveSummaryCache {
    private var callID: String?
    private var current: LiveSummary?
    private var running: Task<LiveSummary?, Never>?

    public init() {}

    public func summary(for callID: String, entries: [LiveEntry], owner: String, llm: any LanguageModel) async -> LiveSummary? {
        if callID != self.callID {
            self.callID = callID
            current = nil
            running = nil
        }
        if let running { _ = await running.value }
        guard self.callID == callID else { return nil }
        guard let step = LiveSummaryRules.due(entries, summary: current) else { return current }
        let request = LiveSummaryRules.request(old: current, fold: step.fold, owner: owner)
        let task = Task { () -> LiveSummary? in
            do {
                let out = try await llm.json(system: request.system, user: request.user, schema: Schema.object(["summary": Schema.string]),
                                             effort: .low, purpose: .question, as: Output.self)
                return LiveSummary(through: step.through, text: out.summary.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                Log.error("Live chat: the summary of the older part failed: \(error)")
                return nil
            }
        }
        running = task
        let made = await task.value
        guard self.callID == callID else { return nil }
        running = nil
        if let made { current = made }
        return current
    }

    private struct Output: Decodable { let summary: String }
}
