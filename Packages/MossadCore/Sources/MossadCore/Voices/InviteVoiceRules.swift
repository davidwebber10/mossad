import Foundation

/// The people a call's invite names, as voice identification reads them. The owner's own entry is left out.
public struct CallInvite: Sendable, Equatable {
    public struct Guest: Sendable, Equatable {
        public var name: String?
        /// Lowercase.
        public var email: String?
        /// The saved person this entry surely is.
        public var personID: String?
        public var declined: Bool

        public init(name: String? = nil, email: String? = nil, personID: String? = nil, declined: Bool = false) {
            self.name = name
            self.email = email.map(EmailIdentity.normalized)
            self.personID = personID
            self.declined = declined
        }
    }

    public var guests: [Guest]

    public init(guests: [Guest]) { self.guests = guests }

    /// Nil when the call has no invite: an ad-hoc call or a room recording keeps the rules of before.
    public init?(record: CallRecord) {
        if let invitees = record.invitees, !invitees.isEmpty {
            guests = invitees.filter { $0.isSelf != true }
                .map { Guest(name: $0.name, email: $0.email, personID: $0.personID, declined: $0.declined) }
        } else if !record.attendees.isEmpty {
            guests = record.attendees.map { $0.contains("@") ? Guest(email: $0) : Guest(name: $0) }
        } else {
            return nil
        }
    }
}

public struct VoiceScore: Sendable, Equatable {
    public var name: String
    public var score: Float

    public init(name: String, score: Float) {
        self.name = name
        self.score = score
    }
}

/// The invite against the voice library: which saved voices were invited, and who was invited with no voice yet.
/// A guest is a saved voice only on a sure match: the person's id, an email, or the whole name in either order.
public struct InviteRoster: Sendable, Equatable {
    public struct Voiceless: Sendable, Equatable {
        public var guest: CallInvite.Guest
        /// The name a voice of this guest gets; nil when no name is sure to be this guest alone.
        public var label: String?
    }

    /// The names of the voice profiles on the invite, the owner's always.
    public var invited: Set<String>
    /// The guests who did not decline and have no saved voice, in invite order.
    public var voiceless: [Voiceless]
    /// The guests other than the owner.
    public var guests: Int

    public init(invite: CallInvite, profiles: [VoiceProfile], people: [Person]) {
        let live = people.filter(\.isLive)
        let ownerPerson = live.first { $0.isOwner }
        func personID(of p: VoiceProfile) -> PersonID? { PeopleStore.id(forVoiceName: p.name, isOwner: p.isOwner, in: live) }
        func emails(of p: VoiceProfile) -> Set<String> {
            var out = Set(p.email.map { [EmailIdentity.normalized($0)] } ?? [])
            if let id = personID(of: p), let person = live.first(where: { $0.id == id }) {
                out.formUnion(person.emails.map { EmailIdentity.normalized($0.address) })
            }
            return out
        }
        let directory = profiles.map { PersonDirectory.Person(name: $0.name, email: $0.email) }
        func profile(for g: CallInvite.Guest) -> VoiceProfile? {
            if let raw = g.personID {
                let id = Self.canonical(PersonID(rawValue: raw), in: people)
                if let hit = profiles.first(where: { personID(of: $0) == id }) { return hit }
            }
            if let email = g.email, let hit = profiles.first(where: { emails(of: $0).contains(email) }) { return hit }
            guard let name = g.name, let hit = PersonDirectory.existing(name: name, email: nil, among: directory) else { return nil }
            return profiles.first { $0.name == hit }
        }
        func isOwner(_ g: CallInvite.Guest, _ p: VoiceProfile?) -> Bool {
            if p?.isOwner == true { return true }
            guard let me = ownerPerson else { return false }
            if let raw = g.personID, Self.canonical(PersonID(rawValue: raw), in: people) == me.id { return true }
            if let email = g.email, me.emails.contains(where: { EmailIdentity.normalized($0.address) == email }) { return true }
            if let name = g.name, me.forms.contains(where: { PersonNames.key($0.text) == PersonNames.key(name) }) { return true }
            return false
        }

        let voiced = profiles.filter { !$0.embeddings.isEmpty }
        var invited = Set(profiles.filter(\.isOwner).map(\.name))
        var voiceless: [Voiceless] = []
        var guests = 0
        for g in invite.guests {
            let p = profile(for: g)
            if isOwner(g, p) { continue }
            guests += 1
            if let p { invited.insert(p.name) }
            guard !g.declined, p?.embeddings.isEmpty ?? true else { continue }
            var label = p?.name ?? Self.label(of: g, among: live)
            // A name read from an address that is the name of another saved voice is not proof of who it is.
            if p == nil, let l = label, voiced.contains(where: { PersonNames.key($0.name) == PersonNames.key(l) }) { label = nil }
            voiceless.append(Voiceless(guest: g, label: label))
        }
        self.invited = invited
        self.voiceless = voiceless
        self.guests = guests
    }

    private static func canonical(_ id: PersonID, in people: [Person]) -> PersonID {
        var current = id
        var seen: Set<PersonID> = []
        while seen.insert(current).inserted, let next = people.first(where: { $0.id == current })?.mergedInto { current = next }
        return current
    }

    /// A saved person's name on a sure match, else the invite's name, else a "first.last" address as a name, else
    /// the address.
    static func label(of g: CallInvite.Guest, among people: [Person]) -> String? {
        if let raw = g.personID, let p = people.first(where: { $0.id == canonical(PersonID(rawValue: raw), in: people) }) { return p.displayName }
        let directory = people.filter { !$0.isOwner }.flatMap { p in
            p.emails.isEmpty ? [PersonDirectory.Person(name: p.displayName, email: nil)]
                : p.emails.map { PersonDirectory.Person(name: p.displayName, email: $0.address) }
        }
        if let hit = PersonDirectory.existing(name: g.name ?? "", email: g.email, among: directory) { return hit }
        if let name = g.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        guard let email = g.email else { return nil }
        return name(fromAddress: email) ?? email
    }

    /// "robin.ash@example.com" gives "Robin Ash". Only two words of letters, each of two letters or more.
    static func name(fromAddress email: String) -> String? {
        guard let local = email.split(separator: "@").first else { return nil }
        let words = local.split(whereSeparator: { ".-_".contains($0) })
        guard words.count == 2, words.allSatisfy({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }) else { return nil }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }
}

/// Who each voice of a call is, from its scores against the saved voices and the call's invite.
///
/// A saved voice on the invite is named as before. One who was not invited needs a strong score and a clear lead
/// over the next voice, and is never learned from: only the owner's word teaches a voice that was not invited.
/// When exactly one invited person has no voice and exactly one voice of the other side is left, that voice is them.
public enum InviteVoiceRules {
    /// The score a voice not on the invite needs.
    public static let uninvitedScore: Float = 0.80
    /// How far a voice not on the invite must lead the next one.
    public static let uninvitedMargin: Float = 0.08
    /// A voice left this near an invited voice that no one was named as may be that person: nothing is inferred.
    public static let inferenceDoubt: Float = 0.55

    public struct Voice: Sendable, Equatable {
        public var key: String
        /// Best first.
        public var scores: [VoiceScore]
        /// False when the speaker had too little clear speech for a fingerprint.
        public var fingerprint: Bool

        public init(key: String, scores: [VoiceScore], fingerprint: Bool) {
            self.key = key
            self.scores = scores.sorted { $0.score > $1.score }
            self.fingerprint = fingerprint
        }
    }

    public enum Verdict: Sendable, Equatable {
        case named(String, score: Float, learn: Bool)
        /// The invited person with no voice.
        case inferred(String)
        /// A voice not on the invite, not sure enough: the voice stays unknown, and this is the closest.
        case withheld(suggestion: VoiceScore)
        case unknown
    }

    public struct Decision: Sendable, Equatable {
        public var verdicts: [String: Verdict]
        /// The guest the inferred voice is.
        public var inferred: CallInvite.Guest?
        /// Counts and scores, never a name.
        public var logLine: String
    }

    public static func decide(_ voices: [Voice], roster: InviteRoster?, owner: String?,
                              matchThreshold: Float = 0.65, learnThreshold: Float = 0.8) -> Decision {
        var verdicts: [String: Verdict] = [:]
        for v in voices {
            guard let best = v.scores.first, best.score >= matchThreshold else {
                verdicts[v.key] = .unknown
                continue
            }
            guard let roster, best.name != owner, !roster.invited.contains(best.name) else {
                verdicts[v.key] = .named(best.name, score: best.score, learn: best.score >= learnThreshold)
                continue
            }
            let next = v.scores.dropFirst().first?.score ?? 0
            verdicts[v.key] = best.score >= uninvitedScore && best.score - next >= uninvitedMargin
                ? .named(best.name, score: best.score, learn: false)
                : .withheld(suggestion: best)
        }

        var inferred: CallInvite.Guest?
        if let roster, roster.voiceless.count == 1, let label = roster.voiceless[0].label {
            let left = voices.filter { v in
                guard v.key.hasPrefix("them:") else { return false }
                if case .named = verdicts[v.key] { return false }
                return true
            }
            let namedNow = Set(verdicts.values.compactMap { if case .named(let n, _, _) = $0 { n } else { nil } })
            if left.count == 1, let v = left.first, v.fingerprint,
               !v.scores.contains(where: { roster.invited.contains($0.name) && !namedNow.contains($0.name) && $0.score >= inferenceDoubt }) {
                verdicts[v.key] = .inferred(label)
                inferred = roster.voiceless[0].guest
            }
        }
        return Decision(verdicts: verdicts, inferred: inferred, logLine: logLine(voices, verdicts, roster))
    }

    private static func logLine(_ voices: [Voice], _ verdicts: [String: Verdict], _ roster: InviteRoster?) -> String {
        var named = 0, learned = 0, unknown = 0, inferred = 0
        var held: [String] = []
        var strong: [String] = []
        var closest: [String] = []
        for v in voices {
            switch verdicts[v.key] ?? .unknown {
            case .named(let name, let score, let learn):
                named += 1
                if learn { learned += 1 }
                if let roster, !roster.invited.contains(name) { strong.append(String(format: "%.2f", score)) }
            case .inferred:
                inferred += 1
                if let s = v.scores.first { closest.append(String(format: "%.2f", s.score)) }
            case .withheld(let s):
                let next = v.scores.dropFirst().first?.score ?? 0
                held.append(String(format: "%.2f (lead %.2f)", s.score, s.score - next))
            case .unknown: unknown += 1
            }
        }
        var line = "Voices: \(voices.count) to name"
        if let roster {
            line += "; invite of \(roster.guests), \(roster.voiceless.count) without a voice"
        } else {
            line += "; no invite"
        }
        line += "; \(named) named (\(learned) learned), \(inferred) by the invite, \(held.count) held back, \(unknown) unknown"
        if !strong.isEmpty { line += "; not invited but sure: " + strong.joined(separator: ", ") }
        if !held.isEmpty { line += "; held back: " + held.joined(separator: ", ") }
        if !closest.isEmpty { line += "; by the invite, closest saved voice: " + closest.joined(separator: ", ") }
        return line
    }
}
