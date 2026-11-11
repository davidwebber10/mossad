import Foundation

/// Trait cards in the Findings deck: the owner's answer helps most for a trait just below the threshold (2 calls)
/// and for a trait that shows for the first time. Few: 1 for each call's deck and 3 in a week, within the deck's
/// own limits. A trait with an answer is not asked again. Yes confirms it, no lowers it, "No, never again" blocks
/// that value for that person (`PersonaTraits`).
public enum PersonaFindings {
    public static let perCall = 1
    public static let perWeek = 3

    /// One trait that could be asked about.
    public struct Source: Sendable, Equatable {
        public var trait: String
        public var person: String
        public var personName: String
        public var statement: String
        public var state: PersonaTrait.State
        public var supportCalls: Int
        public var confidence: Double = 0
        /// The moment of each call that supports it.
        public var moments: [String: PersonaPointer]

        public init(trait: String, person: String, personName: String, statement: String, state: PersonaTrait.State, supportCalls: Int,
                    moments: [String: PersonaPointer]) {
            self.trait = trait
            self.person = person
            self.personName = personName
            self.statement = statement
            self.state = state
            self.supportCalls = supportCalls
            self.moments = moments
        }

        public init(_ t: PersonaTrait, name: String) {
            var moments: [String: PersonaPointer] = [:]
            for e in t.support where moments[e.callID] == nil || e.strength == .clear { moments[e.callID] = e.pointer }
            self.init(trait: t.id, person: t.person, personName: name, statement: t.text?.statement ?? "", state: t.state, supportCalls: t.supportCalls,
                      moments: moments)
            confidence = t.confidence
        }

        public init(_ t: ShownTrait, person: String, name: String) {
            self.init(trait: t.id, person: person, personName: name, statement: t.statement, state: t.confirmed ? .confirmed : .shown,
                      supportCalls: t.supportCalls, moments: Dictionary(t.moments.map { ($0.callID, $0) }, uniquingKeysWith: { a, _ in a }))
            confidence = t.confidence
        }

        var isAsked: Bool {
            // Pace is not shown in this version, so it is not asked.
            guard statement.nonBlank != nil, !trait.contains("|\(PersonaDimension.pace.rawValue)|") else { return false }
            // A candidate is at or above the ask bound already; under it, a trait is never asked.
            return state == .candidate || state == .shown
        }
    }

    /// The trait card of each call, by call id: newest calls first, one for each call, and no more than the week
    /// leaves. `calls` are the calls of the deck with their start. `quote` gives the person's words of a moment.
    public static func cards(_ sources: [Source], calls: [(callID: String, date: Date)], profile: CoachProfile, now: Date = Date(),
                             quote: (PersonaPointer, String) -> String? = { _, _ in nil }) -> [String: CoachFinding] {
        let traitAnswers = profile.answers.filter { $0.traitID != nil }
        let answered = Set(traitAnswers.compactMap(\.traitID))
        let thisWeek = traitAnswers.filter { $0.verdict != nil && now.timeIntervalSince($0.date) < 7 * 86_400 }.count
        var room = max(0, perWeek - thisWeek)
        let blocked = Set(traitAnswers.filter { $0.verdict == .never }.compactMap { $0.traitID.map(PersonaTrait.block(of:)) })
        var out: [String: CoachFinding] = [:]
        var used: Set<String> = []
        for call in calls.sorted(by: { $0.date > $1.date }) where room > 0 {
            guard now.timeIntervalSince(call.date) <= FindingRules.expiryDays * 86_400 else { continue }
            let ask = sources.filter { s in
                s.isAsked && !answered.contains(s.trait) && !used.contains(s.trait) && !blocked.contains(PersonaTrait.block(of: s.trait)) && s.moments[call.callID] != nil
            }
            // A trait that shows for the first time before one just below the line; then the one with more calls.
            guard let pick = ask.sorted(by: { ($0.state == .shown ? 0 : 1, -$0.supportCalls, $0.trait) < ($1.state == .shown ? 0 : 1, -$1.supportCalls, $1.trait) }).first,
                  let moment = pick.moments[call.callID] else { continue }
            used.insert(pick.trait)
            room -= 1
            out[call.callID] = CoachFinding(id: "\(call.callID)|\(CoachFinding.Kind.trait.rawValue)|\(pick.trait)", callID: call.callID, date: call.date, kind: .trait,
                                            text: pick.statement, skill: "", detail: "Seen in \(pick.supportCalls) calls", quote: quote(moment, pick.person), at: moment.at,
                                            person: pick.person, personName: pick.personName, trait: pick.trait, confidence: pick.confidence)
        }
        return out
    }
}
