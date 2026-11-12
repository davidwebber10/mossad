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

/// How much transcript one live question may send. A model with a large context folds late: up to `verbatim`
/// characters after the summary go word for word, and past that the older lines fold until `keep` are left (about
/// two hours of talk, then a summary about once an hour). A model with a small context never folds: it gets only the
/// newest lines that fit.
public struct LiveLimits: Equatable, Sendable {
    public var verbatim: Int
    public var keep: Int
    public var folds = true

    public init(verbatim: Int, keep: Int, folds: Bool = true) {
        self.verbatim = verbatim
        self.keep = keep
        self.folds = folds
    }

    public static let standard = LiveLimits(verbatim: 120_000, keep: 80_000)

    /// For a model of `contextTokens` in all: the rules, the tools, and the reply take about 2,500 tokens, and a token
    /// is about three characters of transcript.
    public static func small(contextTokens: Int) -> LiveLimits {
        let chars = max(2_000, (contextTokens - 2_500) * 3)
        return LiveLimits(verbatim: chars, keep: chars, folds: false)
    }
}

public enum LiveSummaryRules {
    /// A draft line this far behind the newest line will not end any more.
    static let staleDraft: TimeInterval = 30

    /// The lines the chat sends word for word: after the summary, and for a model that does not fold, only the newest
    /// that fit.
    public static func verbatim(_ entries: [LiveEntry], summary: LiveSummary?, limits: LiveLimits = .standard) -> [LiveEntry] {
        let tail = summary.map { s in entries.filter { $0.time >= s.through } } ?? entries
        guard !limits.folds else { return tail }
        var size = 0, cut = tail.count
        while cut > 0, size + tail[cut - 1].line.count + 1 <= limits.verbatim {
            cut -= 1
            size += tail[cut].line.count + 1
        }
        return Array(tail[cut...])
    }

    /// Nil while the words after the summary fit; else the lines to fold in and where the new summary ends. A line
    /// still being spoken, and every line after it, stays out of the summary.
    public static func due(_ entries: [LiveEntry], summary: LiveSummary?, limits: LiveLimits = .standard) -> (through: TimeInterval, fold: [LiveEntry])? {
        guard limits.folds else { return nil }
        let tail = verbatim(entries, summary: summary, limits: limits)
        guard tail.reduce(0, { $0 + $1.line.count + 1 }) > limits.verbatim else { return nil }
        var kept = 0, cut = tail.count
        while cut > 0, kept + tail[cut - 1].line.count + 1 <= limits.keep {
            cut -= 1
            kept += tail[cut].line.count + 1
        }
        let newest = tail.last?.time ?? 0
        if let draft = tail.firstIndex(where: { !$0.isFinal && newest - $0.time < staleDraft }) { cut = min(cut, draft) }
        guard cut > 0, cut < tail.count else { return nil }
        return (tail[cut].time, Array(tail[..<cut]))
    }

    /// The request that folds new lines into the summary so far. The summary may grow with the time it covers: 300
    /// words, and 100 more for each ten minutes, up to 1,200.
    public static func request(old: LiveSummary?, fold: [LiveEntry], owner: String, through: TimeInterval = 0) -> (system: String, user: String) {
        let words = min(1_200, 300 + 100 * Int(through / 600))
        let system = """
        You keep a running summary of a call that is still going on, for \(owner). Fold the new transcript lines into \
        the summary so far and return the whole new summary. Keep who said what, questions asked (and to whom), \
        numbers, dates, decisions, and promises, each with its [mm:ss] time. Keep "Speaker A" labels as they are and \
        never give them a name. Never add anything that was not said. At most \(words) words.
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

    public func summary(for callID: String, entries: [LiveEntry], owner: String, llm: any LanguageModel,
                        limits: LiveLimits = .standard) async -> LiveSummary? {
        if callID != self.callID {
            self.callID = callID
            current = nil
            running = nil
        }
        if let running { _ = await running.value }
        guard self.callID == callID else { return nil }
        guard let step = LiveSummaryRules.due(entries, summary: current, limits: limits) else { return current }
        let request = LiveSummaryRules.request(old: current, fold: step.fold, owner: owner, through: step.through)
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
        // In the same step as the end of the run, so a question that waited sees the new summary.
        running = nil
        if let made { current = made }
        return current
    }

    private struct Output: Decodable { let summary: String }
}
