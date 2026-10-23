import Foundation

public enum FocusOutcome: String, Codable, Sendable, CaseIterable { case hit, missed, noChance }

/// How one call went on the focus.
public struct FocusResult: Codable, Equatable, Sendable, Hashable {
    public var callID: String
    public var date: Date
    public var outcome: FocusOutcome
    /// One sentence on what happened, with the time when there was a moment.
    public var evidence: String
    public var at: TimeInterval?

    public init(callID: String, date: Date, outcome: FocusOutcome, evidence: String, at: TimeInterval? = nil) {
        self.callID = callID
        self.date = date
        self.outcome = outcome
        self.evidence = evidence
        self.at = at
    }
}

/// A number the app measures, for a focus that has one.
public enum FocusMetric: String, Codable, Sendable, CaseIterable { case talkShare, longestTurn, questions, pace }

/// The one thing the owner works on. The coach proposes it; it counts only once the owner accepts it.
public struct CoachFocus: Codable, Equatable, Sendable, Identifiable, Hashable {
    public enum Status: String, Codable, Sendable { case proposed, active, learned, dismissed }

    public var id = UUID()
    /// An if-then plan: "When someone asks what's next, say your own items first, each with a day."
    public var plan: String
    /// Why this, from the calls, in one sentence.
    public var why: String
    public var metric: FocusMetric?
    public var status = Status.proposed
    public var proposed: Date
    public var accepted: Date?
    public var results: [FocusResult] = []
    /// The last change on any device; the newer copy wins when devices merge.
    public var updated: Date

    public init(plan: String, why: String, metric: FocusMetric?, proposed: Date) {
        self.plan = plan
        self.why = why
        self.metric = metric
        self.proposed = proposed
        updated = proposed
    }

    /// The calls where the focus could show, oldest first.
    public var chances: [FocusResult] { results.filter { $0.outcome != .noChance } }

    static let learnedHits = 5
    static let learnedWindow = 6

    /// 5 hits in the last 6 chances.
    public var isLearned: Bool { chances.suffix(Self.learnedWindow).filter { $0.outcome == .hit }.count >= Self.learnedHits }
}

/// How the coach talks.
public enum CoachVoice: String, Codable, Sendable, CaseIterable, Identifiable {
    case direct, warm, data
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .direct: "Direct peer"
        case .warm: "Warm mentor"
        case .data: "Data only"
        }
    }
}

extension CoachProfile {
    public var activeFocus: CoachFocus? { foci.last { $0.status == .active } }
    public var proposedFocus: CoachFocus? { foci.last { $0.status == .proposed } }

    /// A new proposal replaces any earlier one that was not accepted.
    public mutating func propose(_ focus: CoachFocus, at date: Date) {
        for i in foci.indices where foci[i].status == .proposed {
            foci[i].status = .dismissed
            foci[i].updated = date
        }
        var f = focus
        f.status = .proposed
        f.updated = date
        foci.append(f)
    }

    /// Makes the focus active, with the owner's own wording when they edited it. The previous focus retires.
    public mutating func acceptFocus(_ id: UUID, plan: String?, at date: Date) {
        guard let i = foci.firstIndex(where: { $0.id == id }) else { return }
        for j in foci.indices where j != i && foci[j].status == .active {
            foci[j].status = .dismissed
            foci[j].updated = date
        }
        if let p = plan?.nonBlank { foci[i].plan = p }
        foci[i].status = .active
        foci[i].accepted = date
        foci[i].updated = date
        focus = foci[i].plan
    }

    public mutating func dismissFocus(_ id: UUID, at date: Date) {
        guard let i = foci.firstIndex(where: { $0.id == id }) else { return }
        foci[i].status = .dismissed
        foci[i].updated = date
        if activeFocus == nil { focus = "" }
    }

    /// Saves one call's result on the active focus, once per call, and marks the focus learned when it is.
    public mutating func record(_ result: FocusResult, focus id: UUID) {
        guard let i = foci.firstIndex(where: { $0.id == id && $0.status == .active }) else { return }
        foci[i].results.removeAll { $0.callID == result.callID }
        foci[i].results.append(result)
        foci[i].results.sort { $0.date < $1.date }
        foci[i].updated = max(foci[i].updated, result.date)
        if foci[i].isLearned {
            foci[i].status = .learned
            focus = ""
        }
    }

    /// Each focus from either copy, the newer change winning, with results from both.
    static func mergedFoci(_ a: [CoachFocus], _ b: [CoachFocus]) -> [CoachFocus] {
        var byID: [UUID: CoachFocus] = [:]
        var order: [UUID] = []
        for f in a + b {
            guard let old = byID[f.id] else { byID[f.id] = f; order.append(f.id); continue }
            var keep = f.updated > old.updated ? f : old
            var seen = Set(keep.results.map(\.callID))
            for r in (f.updated > old.updated ? old : f).results where !seen.contains(r.callID) {
                keep.results.append(r)
                seen.insert(r.callID)
            }
            keep.results.sort { $0.date < $1.date }
            byID[f.id] = keep
        }
        return order.compactMap { byID[$0] }
    }
}
