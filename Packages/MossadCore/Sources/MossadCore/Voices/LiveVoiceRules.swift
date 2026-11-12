import Foundation

/// Who each voice of a call that still records is, for the live transcript. The invite rules are the pipeline's
/// (`InviteVoiceRules`), with more because a live fingerprint is made from less speech and is made again as the
/// speech grows: a name needs enough speech and a clear lead, a name already given is kept with some slack so it
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
    /// An invited name stays while a voice not invited leads it by at most this. That voice could not take the name
    /// with a lead this small, and the scores of two brothers move by about this much between fingerprints.
    public static let uninvitedRivalSlack: Float = 0.03
    /// The early and the late half of one key's speech this far apart (cosine of their fingerprints) are two voices.
    /// The owner's named voices have 10 s pieces that agree at about 0.3 to 0.45 between two pieces at worst; an
    /// average of a half's pieces agrees more, so 0.35 drops only keys whose halves surely differ.
    public static let mixedBelow: Float = 0.35
    /// Each half needs one full piece of speech before the halves are compared.
    public static let mixedHalf: TimeInterval = 10
    /// With this much in each half, two voices stay two voices for the rest of the call.
    public static let mixedSettled: TimeInterval = 15

    public struct Voice: Sendable, Equatable {
        public var key: String
        /// Best first.
        public var scores: [VoiceScore]
        /// The clear speech the fingerprint was made from.
        public var seconds: TimeInterval
        /// The key's early and late speech are two voices.
        public var mixed: Bool
        /// The fingerprint, to tell whether two keys of different sessions are one voice.
        public var vector: [Float]?
        /// No later fingerprint comes: the name needs the full bar, as no slack is needed against a flip.
        public var final: Bool

        public init(key: String, scores: [VoiceScore], seconds: TimeInterval, mixed: Bool = false, vector: [Float]? = nil, final: Bool = false) {
            self.key = key
            self.scores = scores.sorted { $0.score > $1.score }
            self.seconds = seconds
            self.mixed = mixed
            self.vector = vector
            self.final = final
        }
    }

    public struct Outcome: Sendable, Equatable {
        public var names: [String: String]
        /// Counts and scores, never a name.
        public var logLine: String
    }

    /// The session of a key such as "1B": a pause or a new connection starts a session, and its labels start over.
    static func session(of key: String) -> Substring { key.prefix { $0.isNumber } }

    public static func names(_ voices: [Voice], current: [String: String], roster: InviteRoster?, owner: String?,
                             provisional: [String: String] = [:], room: Bool = false, matchThreshold: Float = 0.65) -> [String: String] {
        decide(voices, current: current, roster: roster, owner: owner, provisional: provisional, room: room, matchThreshold: matchThreshold).names
    }

    /// The names of the voices. `current` is what the live transcript shows now: a key with no fingerprint in
    /// `voices` keeps its name while the rules still allow it. `room` allows the owner's name, as one stream then
    /// hears everyone.
    public static func decide(_ voices: [Voice], current: [String: String], roster: InviteRoster?, owner: String?,
                              provisional: [String: String] = [:], room: Bool = false, matchThreshold: Float = 0.65) -> Outcome {
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
            guard !v.final, allowed(name), let score = v.scores.first(where: { $0.name == name })?.score else { return nil }
            let rivals = v.scores.filter { $0.name != name && allowed($0.name) }
            if invited(name) {
                let next = rivals.first { invited($0.name) }?.score ?? 0
                let outsider = rivals.first { !invited($0.name) }?.score ?? 0
                guard score >= matchThreshold - keepScoreSlack, score - next >= lead - keepLeadSlack,
                      outsider - score <= uninvitedRivalSlack else { return nil }
            } else {
                guard score >= InviteVoiceRules.uninvitedScore - keepScoreSlack,
                      score - (rivals.first?.score ?? 0) >= InviteVoiceRules.uninvitedMargin - keepLeadSlack else { return nil }
            }
            return (name, score)
        }

        var claims: [(key: String, name: String, score: Float)] = []
        var newNames = 0, keptInSlack = 0, mixed = 0
        var dropped: [String] = []
        let byKey = Dictionary(voices.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for (key, name) in current where byKey[key] == nil && allowed(name) { claims.append((key, name, .infinity)) }
        for v in voices {
            if v.mixed {
                if current[v.key] != nil { mixed += 1 }
                continue
            }
            // A new name needs the full bar: a name the voice has kept needs less, so it does not flip back and forth.
            if let claim = fresh(v) {
                if claim.0 != current[v.key] { newNames += 1 }
                claims.append((v.key, claim.0, claim.1))
            } else if let name = current[v.key], let claim = kept(name, v) {
                keptInSlack += 1
                claims.append((v.key, claim.0, claim.1))
            } else if current[v.key] != nil, let best = v.scores.first {
                let next = v.scores.dropFirst().first?.score ?? 0
                dropped.append(String(format: "%.2f (lead %.2f)", best.score, best.score - next))
            }
        }
        // One name for one key in a session: the strongest claim has it, and the key that has the name now keeps it
        // unless another leads by `lead`. A key of another session is the same person after a pause or a new
        // connection when the two voices agree, so both keep the name and the earlier lines stay right.
        func agree(_ a: String, _ b: String) -> Bool {
            guard session(of: a) != session(of: b) else { return false }
            guard let x = byKey[a]?.vector, let y = byKey[b]?.vector else { return true }
            return VoiceLibrary.cosine(x, y) >= matchThreshold
        }
        func rank(_ c: (key: String, name: String, score: Float)) -> Float { c.score + (current[c.key] == c.name ? lead : 0) }
        var out: [String: String] = [:]
        var holders: [String: [String]] = [:]
        var lost = 0
        for c in claims.sorted(by: { (rank($0), $1.key) > (rank($1), $0.key) }) {
            guard holders[c.name, default: []].allSatisfy({ agree($0, c.key) }) else {
                lost += 1
                continue
            }
            holders[c.name, default: []].append(c.key)
            out[c.key] = c.name
        }
        var line = "Live names: \(voices.count) voices, \(out.count) named (\(newNames) new, \(keptInSlack) kept within the slack)"
        line += ", \(dropped.count) dropped, \(mixed) mixed, \(lost) lost to a stronger key"
        if !dropped.isEmpty { line += "; dropped: " + dropped.joined(separator: ", ") }
        return Outcome(names: out, logLine: line)
    }

    /// The key's speech in time order, split in two halves, and the cosine of their fingerprints. Nil when either
    /// half is too short to say. `settled` says that the halves are long enough for the result to stand.
    static func halves(_ pieces: [SpeakerIdentifier.PieceVector]) -> (cosine: Float, mixed: Bool, settled: Bool)? {
        let ordered = pieces.sorted { $0.start < $1.start }
        guard ordered.count >= 2 else { return nil }
        let early = Array(ordered.prefix(ordered.count / 2)), late = Array(ordered.dropFirst(ordered.count / 2))
        let a = early.reduce(0) { $0 + $1.seconds }, b = late.reduce(0) { $0 + $1.seconds }
        guard a >= mixedHalf, b >= mixedHalf,
              let x = VoiceLibrary.centroid(early.map(\.vector)), let y = VoiceLibrary.centroid(late.map(\.vector)) else { return nil }
        let cosine = VoiceLibrary.cosine(x, y)
        return (cosine, cosine < mixedBelow, min(a, b) >= mixedSettled)
    }
}
