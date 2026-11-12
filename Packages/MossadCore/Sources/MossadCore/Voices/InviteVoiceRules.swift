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
        /// False for a room, a resource, or a group.
        public var person: Bool

        public init(name: String? = nil, email: String? = nil, personID: String? = nil, declined: Bool = false, person: Bool = true) {
            self.name = name
            self.email = email.map(EmailIdentity.normalized)
            self.personID = personID
            self.declined = declined
            self.person = person
        }
    }

    public var guests: [Guest]
    /// The invite is surely the call's: the call's meeting id is in it, or no other event could be the call. Only a
    /// sure invite gives a voice the name of an invited person with no voice.
    public var sure: Bool

    public init(guests: [Guest], sure: Bool = true) {
        self.guests = guests
        self.sure = sure
    }

    /// Nil when the call has no invite: an ad-hoc call keeps the rules of before.
    public init?(record: CallRecord, sure: Bool) {
        if let invitees = record.invitees, !invitees.isEmpty {
            guests = invitees.filter { $0.isSelf != true }
                .map { Guest(name: $0.name, email: $0.email, personID: $0.personID, declined: $0.declined, person: $0.isPerson) }
        } else if !record.attendees.isEmpty {
            guests = record.attendees.map { $0.contains("@") ? Guest(email: $0) : Guest(name: $0) }
        } else {
            return nil
        }
        self.sure = sure
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
/// A guest is a saved voice only on a sure match: the person's id, an email, or the whole name in either order. A
/// guest who only may be the owner or a saved voice is not "invited with no voice": unknown is not false.
public struct InviteRoster: Sendable, Equatable {
    public struct Voiceless: Sendable, Equatable {
        public var guest: CallInvite.Guest
        /// The name a voice of this guest gets; nil when no name is sure to be this guest alone.
        public var label: String?
        /// Where the label came from, for the person that the name makes.
        public var source: SourceKind
        /// Saved voices whose name this guest's name may be a form of, such as "Mira" for Mira Stone.
        public var fits: [String]
    }

    /// The names of the voice profiles on the invite, the owner's always.
    public var invited: Set<String>
    /// The people who did not decline and have no saved voice, in invite order.
    public var voiceless: [Voiceless]
    /// The people on the invite other than the owner.
    public var guests: Int
    /// A guest may be the owner under an address or a name that is not surely theirs.
    public var ownerDoubt: Bool
    public var sure: Bool

    public init(invite: CallInvite, profiles: [VoiceProfile], people: [Person]) {
        let live = people.filter(\.isLive)
        let ownerPerson = live.first { $0.isOwner }
        func personID(of p: VoiceProfile) -> PersonID? { PeopleStore.id(forVoiceName: p.name, isOwner: p.isOwner, in: live) }
        func emails(of p: VoiceProfile) -> Set<String> {
            var out = Set(p.email.map { [EmailIdentity.normalized($0)] } ?? [])
            if let id = personID(of: p), let person = live.first(where: { $0.id == id }) { out.formUnion(Self.addresses(of: person)) }
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
            if let email = g.email, Self.addresses(of: me).contains(email) { return true }
            if let name = g.name, me.forms.contains(where: { PersonNames.key($0.text) == PersonNames.key(name) }) { return true }
            return false
        }
        let ownerNames = Set(profiles.filter(\.isOwner).map(\.name) + (ownerPerson?.forms.map(\.text) ?? []))
        func mayBeOwner(_ g: CallInvite.Guest) -> Bool {
            if let email = g.email, ownerNames.contains(where: { CalendarInfo.isOwnersAddress(email, ownerName: $0) }) { return true }
            guard let written = g.name ?? g.email.flatMap(Self.name(fromAddress:)) else { return false }
            return ownerNames.contains { Self.fits(written, $0) }
        }

        let voiced = profiles.filter { !$0.embeddings.isEmpty && !$0.isOwner }
        var invited = Set(profiles.filter(\.isOwner).map(\.name))
        var voiceless: [Voiceless] = []
        var guests = 0
        var ownerDoubt = false
        for g in invite.guests where g.person {
            let p = profile(for: g)
            if isOwner(g, p) { continue }
            guests += 1
            if let p { invited.insert(p.name) }
            guard !g.declined, p?.embeddings.isEmpty ?? true else { continue }
            if p == nil, mayBeOwner(g) {
                ownerDoubt = true
                continue
            }
            let written = g.name ?? g.email.flatMap(Self.name(fromAddress:))
            let fits = p == nil ? voiced.filter { v in written.map { Self.fits($0, v.name) } ?? false }.map(\.name) : []
            var label = p.map { ($0.name, SourceKind.voiceNaming) } ?? Self.label(of: g, among: live)
            // A name that is the name of another saved voice is not proof of who it is.
            if p == nil, let l = label, voiced.contains(where: { PersonNames.key($0.name) == PersonNames.key(l.0) }) { label = nil }
            voiceless.append(Voiceless(guest: g, label: label?.0, source: label?.1 ?? .calendar, fits: fits))
        }
        self.invited = invited
        self.voiceless = voiceless
        self.guests = guests
        self.ownerDoubt = ownerDoubt
        sure = invite.sure
    }

    /// The addresses that are this person's own: not one the owner rejected, and not one shared with others.
    private static func addresses(of p: Person) -> Set<String> {
        Set(p.emails.filter { $0.state != .rejected && !$0.shared }.map { EmailIdentity.normalized($0.address) })
    }

    private static func canonical(_ id: PersonID, in people: [Person]) -> PersonID {
        var current = id
        var seen: Set<PersonID> = []
        while seen.insert(current).inserted, let next = people.first(where: { $0.id == current })?.mergedInto { current = next }
        return current
    }

    /// Either name may be a form of the other: "Mira" and Mira Stone, "Mike Stone" and Michael Stone.
    static func fits(_ a: String, _ b: String) -> Bool {
        let pa = PersonNames.parse(a), pb = PersonNames.parse(b)
        return [PersonNames.fit(pa, pb), PersonNames.fit(pb, pa)].contains { $0 != .none && $0 != .conflict }
    }

    /// A saved person's name on a sure match, else the invite's name in the order first, family, else a
    /// "first.last" address as a name. Never the address itself: a speaker's name shows in the note and the summary.
    static func label(of g: CallInvite.Guest, among people: [Person]) -> (String, SourceKind)? {
        if let raw = g.personID, let p = people.first(where: { $0.id == canonical(PersonID(rawValue: raw), in: people) }) {
            return (p.displayName, .voiceNaming)
        }
        let directory = people.filter { !$0.isOwner }.flatMap { p in
            let own = addresses(of: p)
            return own.isEmpty ? [PersonDirectory.Person(name: p.displayName, email: nil)]
                : own.sorted().map { PersonDirectory.Person(name: p.displayName, email: $0) }
        }
        if let hit = PersonDirectory.existing(name: g.name ?? "", email: g.email, among: directory) { return (hit, .voiceNaming) }
        if let name = g.name.flatMap(natural) { return (name, .calendar) }
        return g.email.flatMap(name(fromAddress:)).map { ($0, .address) }
    }

    /// "Fenwick, Jo" and "FENWICK Jo" give "Jo Fenwick". Nil for a text that is not a person's name.
    static func natural(_ written: String) -> String? {
        let text = PersonNames.plain(written).trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = PersonNames.parse(text)
        guard parsed.isName else { return nil }
        switch parsed.order {
        case .comma:
            let parts = text.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[1].isEmpty else { return text }
            return "\(parts[1]) \(parts[0])"
        case .capitals:
            let words = text.split(separator: " ").map(String.init)
            let upper = words.filter { $0.count > 1 && $0 == $0.uppercased() && $0 != $0.lowercased() }
            let rest = words.filter { !upper.contains($0) }
            return (rest + upper.map { $0.prefix(1) + $0.dropFirst().lowercased() }).joined(separator: " ")
        case .none:
            return text
        }
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
/// What that teaches is provisional: it names a voice only on a call where that person is invited, and it becomes
/// firm when the owner names the voice, or when another call with that person invited has the voice at
/// `learnThreshold`.
public enum InviteVoiceRules {
    /// The score a voice not on the invite needs.
    public static let uninvitedScore: Float = 0.80
    /// How far a voice not on the invite must lead the next one.
    public static let uninvitedMargin: Float = 0.08
    /// A voice left this near an invited voice may be that person: nothing is inferred.
    public static let inferenceDoubt: Float = 0.55
    /// The clear speech a voice named from the invite needs before it is learned.
    public static let inferenceSpeech: TimeInterval = 20

    public struct Voice: Sendable, Equatable {
        public var key: String
        /// Best first.
        public var scores: [VoiceScore]
        /// False when the speaker had too little clear speech for a fingerprint.
        public var fingerprint: Bool
        /// The clear speech the fingerprint was made from.
        public var seconds: TimeInterval?

        public init(key: String, scores: [VoiceScore], fingerprint: Bool, seconds: TimeInterval? = nil) {
            self.key = key
            self.scores = scores.sorted { $0.score > $1.score }
            self.fingerprint = fingerprint
            self.seconds = seconds
        }
    }

    public enum Verdict: Sendable, Equatable {
        case named(String, score: Float, learn: Bool)
        /// The invited person with no voice, or a provisional voice again on the call that made it. `learn` says
        /// whether the fingerprint is learned, as a provisional sample.
        case inferred(String, learn: Bool)
        /// A voice not on the invite, not sure enough: the voice stays unknown, and this is the closest.
        case withheld(suggestion: VoiceScore)
        case unknown
    }

    public struct Decision: Sendable, Equatable {
        public var verdicts: [String: Verdict]
        /// The guest whom rule 4 named a voice as, with the source of the name.
        public var inferred: InviteRoster.Voiceless?
        /// The speaker keys whose name came from the invite and not yet from the owner or a second call.
        public var fromInvite: Set<String>
        /// Counts and scores, never a name.
        public var logLine: String
    }

    /// `provisional` is each provisional voice with the call that made it; `callID` is this call.
    public static func decide(_ voices: [Voice], roster: InviteRoster?, owner: String?, provisional: [String: String] = [:],
                              callID: String? = nil, matchThreshold: Float = 0.65, learnThreshold: Float = 0.8) -> Decision {
        func enoughSpeech(_ v: Voice) -> Bool { (v.seconds ?? 0) >= inferenceSpeech }
        var verdicts: [String: Verdict] = [:]
        for v in voices {
            guard let best = v.scores.first, best.score >= matchThreshold else {
                verdicts[v.key] = .unknown
                continue
            }
            if let made = provisional[best.name] {
                // Learned from one invite: it is proof of nobody outside an invite that names them.
                guard let roster, roster.invited.contains(best.name) else {
                    verdicts[v.key] = .withheld(suggestion: best)
                    continue
                }
                verdicts[v.key] = made == callID ? .inferred(best.name, learn: enoughSpeech(v))
                    : .named(best.name, score: best.score, learn: best.score >= learnThreshold)
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

        var inferred: InviteRoster.Voiceless?
        if let roster, roster.sure, !roster.ownerDoubt, roster.voiceless.count == 1 {
            let guest = roster.voiceless[0]
            let left = voices.filter { v in
                guard v.key.hasPrefix("them:") else { return false }
                switch verdicts[v.key] {
                case .named, .inferred: return false
                default: return true
                }
            }
            if left.count == 1, let v = left.first, v.fingerprint {
                if !guest.fits.isEmpty {
                    // "Mira" on the invite and a voice close to Mira Stone: the saved person, not a new one.
                    if let best = v.scores.first, guest.fits.contains(best.name), best.score >= matchThreshold {
                        verdicts[v.key] = .named(best.name, score: best.score, learn: false)
                    }
                } else if let label = guest.label,
                          !v.scores.contains(where: { roster.invited.contains($0.name) && $0.score >= inferenceDoubt }) {
                    verdicts[v.key] = .inferred(label, learn: enoughSpeech(v))
                    inferred = guest
                }
            }
        }
        var fromInvite: Set<String> = []
        for (key, verdict) in verdicts {
            switch verdict {
            case .inferred: fromInvite.insert(key)
            case .named(let name, _, let learn) where provisional[name] != nil && !learn: fromInvite.insert(key)
            default: break
            }
        }
        return Decision(verdicts: verdicts, inferred: inferred, fromInvite: fromInvite, logLine: logLine(voices, verdicts, roster))
    }

    private static func logLine(_ voices: [Voice], _ verdicts: [String: Verdict], _ roster: InviteRoster?) -> String {
        var named = 0, learned = 0, unknown = 0, inferred = 0, inferredLearned = 0
        var held: [String] = []
        var strong: [String] = []
        var closest: [String] = []
        for v in voices {
            switch verdicts[v.key] ?? .unknown {
            case .named(let name, let score, let learn):
                named += 1
                if learn { learned += 1 }
                if let roster, !roster.invited.contains(name) { strong.append(String(format: "%.2f", score)) }
            case .inferred(_, let learn):
                inferred += 1
                if learn { inferredLearned += 1 }
                if let s = v.scores.first { closest.append(String(format: "%.2f", s.score)) }
            case .withheld(let s):
                let next = v.scores.dropFirst().first?.score ?? 0
                held.append(String(format: "%.2f (lead %.2f)", s.score, s.score - next))
            case .unknown: unknown += 1
            }
        }
        var line = "Voices: \(voices.count) to name"
        if let roster {
            line += "; invite of \(roster.guests), \(roster.voiceless.count) without a voice\(roster.sure ? "" : ", not sure")"
            if roster.ownerDoubt { line += ", one may be the owner" }
        } else {
            line += "; no invite"
        }
        line += "; \(named) named (\(learned) learned), \(inferred) by the invite (\(inferredLearned) learned), \(held.count) held back, \(unknown) unknown"
        if !strong.isEmpty { line += "; not invited but sure: " + strong.joined(separator: ", ") }
        if !held.isEmpty { line += "; held back: " + held.joined(separator: ", ") }
        if !closest.isEmpty { line += "; by the invite, closest saved voice: " + closest.joined(separator: ", ") }
        return line
    }
}
