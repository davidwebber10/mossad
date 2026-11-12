import Foundation

/// Who each voice of a call that still records is, for the live transcript. The invite rules are the pipeline's
/// (`InviteVoiceRules`), with three more because a live fingerprint is made from less speech and is made again as
/// the speech grows: a name needs enough speech and a clear lead, a name already given is kept with some slack so it
/// does not flip, and a speaker key that seems to hold two voices gets no name.
public enum LiveVoiceRules {
    /// Clear speech a voice needs before it is named. A fingerprint is made of pieces of 2 to 10 s; below one full
    /// piece the voice model's answer for one voice moves by more than the gap between two people, and the names the
    /// live transcript got wrong were mostly given at the old 4 s.
    public static let minimumSpeech: TimeInterval = 10
    /// How far a voice must lead the next voice that could have the name. Another try of the same voice with more
    /// speech moves its scores by a few hundredths, so a smaller lead can turn into the other name.
    public static let lead: Float = 0.05
    /// A name already given stays while its score is at most this far under the bar...
    public static let keepScoreSlack: Float = 0.03
    /// ...and its lead at most this far under the lead a new name needs: an invited voice may then trail by 0.01.
    public static let keepLeadSlack: Float = 0.06
    /// The early and the late speech of one key this far apart are two voices. The same floor as the coherence in
    /// `VoiceSample.quality`, where pieces at 0.5 or less do not agree at all.
    public static let mixedBelow: Float = 0.5
    /// Each half of a key's speech needs this much before the two halves are compared.
    public static let mixedHalf: TimeInterval = 4

    public struct Voice: Sendable, Equatable {
        public var key: String
        /// Best first.
        public var scores: [VoiceScore]
        /// The clear speech the fingerprint was made from.
        public var seconds: TimeInterval
        /// The key's early and late speech are two voices.
        public var mixed: Bool

        public init(key: String, scores: [VoiceScore], seconds: TimeInterval, mixed: Bool = false) {
            self.key = key
            self.scores = scores.sorted { $0.score > $1.score }
            self.seconds = seconds
            self.mixed = mixed
        }
    }

    /// The names of the voices. `current` is what the live transcript shows now: a key with no fingerprint in
    /// `voices` keeps its name. `room` allows the owner's name, as one stream then hears everyone.
    public static func names(_ voices: [Voice], current: [String: String], roster: InviteRoster?, owner: String?,
                             provisional: [String: String] = [:], room: Bool = false, matchThreshold: Float = 0.65) -> [String: String] {
        // The pipeline names the one voice left as the one invited person with no voice only when it has heard the
        // whole call; while it records, the one voice heard so far is often not the only one.
        var roster = roster
        roster?.voiceless = []
        let invitedOnly = roster
        func allowed(_ name: String) -> Bool {
            (room || name != owner) && (provisional[name] == nil || invitedOnly?.invited.contains(name) == true)
        }
        func invited(_ name: String) -> Bool { invitedOnly.map { $0.invited.contains(name) } ?? true }

        let ready = voices.filter { $0.seconds >= minimumSpeech && !$0.mixed }
        let decision = InviteVoiceRules.decide(
            ready.map { InviteVoiceRules.Voice(key: $0.key, scores: $0.scores, fingerprint: true, seconds: $0.seconds) },
            roster: roster, owner: owner, provisional: provisional, callID: nil, matchThreshold: matchThreshold)

        func fresh(_ v: Voice) -> (String, Float)? {
            guard case .named(let name, let score, _)? = decision.verdicts[v.key], allowed(name) else { return nil }
            // A voice not on the invite already needed 0.80 and a lead of 0.08 over every voice.
            guard invited(name) else { return (name, score) }
            let next = v.scores.first { $0.name != name && allowed($0.name) && invited($0.name) }?.score ?? 0
            return score - next >= lead ? (name, score) : nil
        }
        func kept(_ name: String, _ v: Voice) -> (String, Float)? {
            guard allowed(name), let score = v.scores.first(where: { $0.name == name })?.score else { return nil }
            let bar = invited(name) ? matchThreshold : InviteVoiceRules.uninvitedScore
            let need = invited(name) ? lead : InviteVoiceRules.uninvitedMargin
            let next = v.scores.first { $0.name != name && allowed($0.name) }?.score ?? 0
            return score >= bar - keepScoreSlack && score - next >= need - keepLeadSlack ? (name, score) : nil
        }

        var claims: [(key: String, name: String, score: Float)] = []
        let fingerprinted = Set(voices.map(\.key))
        for (key, name) in current where !fingerprinted.contains(key) { claims.append((key, name, .infinity)) }
        for v in ready {
            // A new name needs the full bar: a name the voice has kept needs less, so it does not flip back and forth.
            guard let claim = fresh(v) ?? current[v.key].flatMap({ kept($0, v) }) else { continue }
            claims.append((v.key, claim.0, claim.1))
        }
        // One name for one key: the strongest claim has it, the other key stays a letter.
        var out: [String: String] = [:]
        var taken: Set<String> = []
        for c in claims.sorted(by: { ($0.score, $1.key) > ($1.score, $0.key) }) where taken.insert(c.name).inserted {
            out[c.key] = c.name
        }
        return out
    }

    /// The key's speech in time order, split in two halves: when their fingerprints disagree strongly, the key
    /// holds two voices. Nil when either half is too short to say.
    static func mixed(_ pieces: [SpeakerIdentifier.PieceVector]) -> Bool? {
        let ordered = pieces.sorted { $0.start < $1.start }
        guard ordered.count >= 2 else { return nil }
        let early = Array(ordered.prefix(ordered.count / 2)), late = Array(ordered.dropFirst(ordered.count / 2))
        guard early.reduce(0, { $0 + $1.seconds }) >= mixedHalf, late.reduce(0, { $0 + $1.seconds }) >= mixedHalf,
              let a = VoiceLibrary.centroid(early.map(\.vector)), let b = VoiceLibrary.centroid(late.map(\.vector)) else { return nil }
        return VoiceLibrary.cosine(a, b) < mixedBelow
    }
}
