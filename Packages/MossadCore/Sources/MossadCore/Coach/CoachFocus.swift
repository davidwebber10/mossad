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
    /// The owner's own words that show it, found in the transcript by code. Without them the result counts
    /// for the focus but is not a line.
    public var quote: String?

    public init(callID: String, date: Date, outcome: FocusOutcome, evidence: String, at: TimeInterval? = nil, quote: String? = nil) {
        self.callID = callID
        self.date = date
        self.outcome = outcome
        self.evidence = evidence
        self.at = at
        self.quote = quote
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
    /// The raw name of `measure`. Text, so a measure from a later build is no measure here and the memory
    /// still reads.
    public var measureName: String?

    /// The id of the skill this focus is about (`CoachSkill.id`). Nil for a focus from before the skill list.
    public var skill: String?

    /// The number the app measures for this focus, with its baseline and target: a goal. Nil for a focus that
    /// the model judges call by call, and for one from before goals.
    public var goal: CoachGoal?

    /// The number the app counts for this focus, when it is not one of the call's own numbers in `metric`.
    public var measure: CoachMeasure? { measureName.flatMap(CoachMeasure.init(rawValue:)) ?? CoachSkill(id: skillID)?.measure }

    /// The skill's id; for a focus from before the skill list, the one that its plan's words give.
    public var skillID: String { skill ?? CoachSkill.seedID(plan) }

    public init(plan: String, why: String, metric: FocusMetric?, proposed: Date, skill: String? = nil) {
        self.plan = plan
        self.why = why
        self.metric = metric
        self.proposed = proposed
        updated = proposed
        self.skill = skill
        measureName = skill.flatMap { CoachSkill(id: $0)?.measure?.rawValue }
    }

    /// The calls where the focus could show, oldest first.
    public var chances: [FocusResult] { results.filter { $0.outcome != .noChance } }

    static let learnedHits = 5
    static let learnedWindow = 6

    /// 5 hits in the last 6 chances. A goal is never learned this way: its progress is its number, and the owner
    /// says when it is learned.
    public var isLearned: Bool {
        goal == nil && chances.suffix(Self.learnedWindow).filter { $0.outcome == .hit }.count >= Self.learnedHits
    }
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

    /// How the reviews sound in this voice, for the menu's row.
    public var detail: String {
        switch self {
        case .direct: "Plain, short, and specific, like a candid peer."
        case .warm: "Encouraging and specific, like a mentor with high standards."
        case .data: "Facts and numbers only, with no encouragement."
        }
    }
}

/// The goals for the Coach page: the one of now (active, or offered and waiting), the ones the owner did not
/// take, and the ones the owner learned. The newest first.
public struct GoalHistory: Equatable, Sendable {
    public var current: CoachFocus?
    /// Offered, and the owner did not take it.
    public var offered: [CoachFocus]
    /// Taken, then ended by the owner or replaced by another goal before it was learned.
    public var ended: [CoachFocus]
    public var finished: [CoachFocus]
}

extension CoachProfile {
    public var goalHistory: GoalHistory {
        GoalHistory(current: activeFocus ?? proposedFocus,
                    offered: foci.filter { $0.status == .dismissed && $0.accepted == nil }.sorted { $0.updated > $1.updated },
                    ended: foci.filter { $0.status == .dismissed && $0.accepted != nil }.sorted { $0.updated > $1.updated },
                    finished: foci.filter { $0.status == .learned }.sorted { $0.updated > $1.updated })
    }

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

    /// "Take it up again": an ended or learned goal is the active one again, with its date and its numbers. Only
    /// while no other goal is active.
    public mutating func resumeFocus(_ id: UUID, at date: Date) {
        guard activeFocus == nil, let i = foci.firstIndex(where: { $0.id == id && $0.accepted != nil && ($0.status == .dismissed || $0.status == .learned) }) else { return }
        foci[i].status = .active
        foci[i].updated = date
        focus = foci[i].plan
    }

    /// The owner says the goal is learned. Only the active one.
    public mutating func learnFocus(_ id: UUID, at date: Date) {
        guard let i = foci.firstIndex(where: { $0.id == id && $0.status == .active }) else { return }
        foci[i].status = .learned
        foci[i].updated = date
        focus = ""
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
        // `updated` is the owner's last change: a result must not win a merge over "End this goal" on another device.
        // The results merge as a union, so they need no date of their own.
        if foci[i].isLearned {
            foci[i].updated = max(foci[i].updated, result.date)
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
            // A copy that a build from before these fields saved has none: the other copy's stay.
            let other = f.updated > old.updated ? old : f
            keep.skill = keep.skill ?? other.skill
            keep.measureName = keep.measureName ?? other.measureName
            keep.goal = keep.goal ?? other.goal
            byID[f.id] = keep
        }
        return order.compactMap { byID[$0] }
    }
}

extension CoachFocus {
    enum CodingKeys: String, CodingKey { case id, plan, why, metric, status, proposed, accepted, results, updated, measureName, skill, goal }

    /// As the synthesized decoder, but a goal in a shape from a later build is no goal: one focus must not make the
    /// whole memory unreadable on an older build.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        plan = try c.decode(String.self, forKey: .plan)
        why = try c.decode(String.self, forKey: .why)
        metric = try c.decodeIfPresent(FocusMetric.self, forKey: .metric)
        status = try c.decode(Status.self, forKey: .status)
        proposed = try c.decode(Date.self, forKey: .proposed)
        accepted = try c.decodeIfPresent(Date.self, forKey: .accepted)
        results = try c.decode([FocusResult].self, forKey: .results)
        updated = try c.decode(Date.self, forKey: .updated)
        measureName = try c.decodeIfPresent(String.self, forKey: .measureName)
        skill = try c.decodeIfPresent(String.self, forKey: .skill)
        goal = (try? c.decodeIfPresent(CoachGoal.self, forKey: .goal)) ?? nil
    }
}
