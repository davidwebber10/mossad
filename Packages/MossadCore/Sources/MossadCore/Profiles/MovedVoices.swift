import Foundation

/// The names of a moved meeting's voices in the target, from the fingerprints its record keeps (never the raw tracks,
/// which retention removes), by the rules of a call's own naming (`InviteVoiceRules.decide`, the thresholds of
/// `identify`). A voice the target knows gets the target's name; one it does not know keeps the name it had, and is
/// learned as the owner's naming; a voice with no name stays a letter. No line of the transcript changes.
public enum MovedVoices {
    public enum Learn: Equatable, Sendable { case none, autoMatch(Float), ownerNamed, inviteInference }

    public struct Naming: Equatable, Sendable {
        /// Speaker key to the name in this profile.
        public var names: [String: String]
        public var learn: [String: Learn]
        public var unknown: [String]
        public var fromInvite: [String]
        /// What the summary says now ("Speaker B", "Sam Carter") to the new name.
        public var renamed: [String: String]
        /// The keys that are the owner here: their samples go to this library's own owner voice, whatever its name.
        public var owner: Set<String> = []
        public var changed: Bool { !renamed.isEmpty }
    }

    /// Reads the library and changes nothing. `record` is the record as the first profile wrote it (its ids are gone).
    public static func decide(_ record: CallRecord, ownerKeys: Set<String>, library: VoiceLibrary, ownerName: String,
                              fingerprints: Bool = true) -> Naming {
        var names: [String: String] = [:]
        var learn: [String: Learn] = [:]
        var ownerHere = Set<String>()
        let prints = fingerprints ? record.speakerEmbeddings : [:]
        func seconds(_ key: String) -> TimeInterval? { record.speakerSamples?[key]?.seconds }
        var keys: [String] = []
        for k in record.utterances.map(\.speakerKey) + record.speakerNames.keys.sorted() + record.unknownSpeakers + record.speakerEmbeddings.keys.sorted()
        where !keys.contains(k) { keys.append(k) }

        // 1. The owner's keys of the first profile are the owner here. The owner's voice is learned only on a sure
        // match with this library's own owner voice; it is never made here.
        for k in keys where ownerKeys.contains(k) {
            names[k] = ownerName
            ownerHere.insert(k)
            if let e = prints[k], let owner = library.owner, let c = VoiceLibrary.centroid(owner.embeddings) {
                let s = VoiceLibrary.cosine(e, c)
                learn[k] = s >= SpeakerIdentifier.learnThreshold ? .autoMatch(s) : Learn.none
            } else {
                learn[k] = Learn.none
            }
        }

        // 2. Every other voice with a fingerprint, against this library. The invite came from the first profile's
        // calendar, so it is never sure: nothing is inferred from it.
        var byLibrary = Set<String>()
        let voices = keys.filter { names[$0] == nil && prints[$0] != nil }
            .map { InviteVoiceRules.Voice(key: $0, scores: library.ranked(prints[$0]!), fingerprint: true, seconds: seconds($0)) }
        var decidedFromInvite: Set<String> = []
        if !voices.isEmpty {
            let roster = CallInvite(record: record, sure: false)
                .map { InviteRoster(invite: $0, profiles: library.profiles, people: library.identity?.people.people ?? []) }
            let d = InviteVoiceRules.decide(voices, roster: roster, owner: library.owner?.name, provisional: library.provisional,
                                            matchThreshold: library.matchThreshold, learnThreshold: SpeakerIdentifier.learnThreshold)
            for v in voices {
                guard case .named(let name, let score, let l)? = d.verdicts[v.key] else { continue }
                if name == library.owner?.name { ownerHere.insert(v.key) }
                names[v.key] = name == library.owner?.name ? ownerName : name
                learn[v.key] = l ? .autoMatch(score) : Learn.none
                byLibrary.insert(v.key)
            }
            decidedFromInvite = d.fromInvite.intersection(byLibrary)
        }

        // 3. A voice the library did not name keeps the name it had: the saved person of that whole name or address,
        // else the name itself. An address with no person is no name; the owner's name on a voice that is not the
        // owner's is no name.
        let owner = OwnerIdentity(name: ownerName, also: [library.owner?.name].compactMap { $0 })
        var kept: [String] = []
        var refused: [String] = []
        for k in keys where names[k] == nil {
            guard let was = record.speakerNames[k] else { continue }
            let name: String? = was.contains("@") ? library.name(forEmail: was) : (library.existingName(name: was, email: nil) ?? was)
            guard let name, !(owner.isOwner(name) || owner.isOwner(was)) else {
                refused.append(k)
                continue
            }
            names[k] = name
            kept.append(k)
            if prints[k] == nil {
                learn[k] = Learn.none
            } else if record.fromInvite?.contains(k) == true {
                learn[k] = (seconds(k) ?? 0) >= InviteVoiceRules.inferenceSpeech ? .inviteInference : Learn.none
            } else {
                learn[k] = .ownerNamed
            }
        }
        // Of two voices that keep one name, only the one with more clear speech teaches; a kept name that the library
        // gave to another voice of the meeting teaches nothing.
        let libraryNames = Set(byLibrary.compactMap { names[$0] })
        for name in Set(kept.compactMap { names[$0] }) {
            let same = kept.filter { names[$0] == name }
            let teacher = libraryNames.contains(name) ? nil : same.max { (seconds($0) ?? 0) < (seconds($1) ?? 0) }
            for k in same where k != teacher { learn[k] = Learn.none }
        }

        // 4. The unknown voices: the record's, without the ones named now, and a refused name.
        var unknown = record.unknownSpeakers.filter { names[$0] == nil }
        for k in refused where !unknown.contains(k) { unknown.append(k) }

        // 5. What the words of the summary call each voice now, where that changed.
        let shown = MarkdownWriter.displayNames(record)
        var renamed: [String: String] = [:]
        for (k, name) in names { if let old = shown[k], old != name { renamed[old] = name } }

        let fromInvite = decidedFromInvite.union(kept.filter { record.fromInvite?.contains($0) == true })
        return Naming(names: names, learn: learn, unknown: unknown, fromInvite: fromInvite.sorted(), renamed: renamed, owner: ownerHere)
    }

    /// Puts the names into the record, swaps the changed names in the summary's words, and teaches the library.
    /// `callID` is the id here. No line of the transcript changes.
    public static func apply(_ naming: Naming, to record: inout CallRecord, callID: String, library: VoiceLibrary) throws {
        record.speakerNames = naming.names
        record.unknownSpeakers = naming.unknown
        record.fromInvite = naming.fromInvite.isEmpty ? nil : naming.fromInvite
        record.replaceSpeakerLabels(naming.renamed)
        for (key, how) in naming.learn.sorted(by: { $0.key < $1.key }) {
            guard let e = record.speakerEmbeddings[key], let name = naming.names[key] else { continue }
            let origin: VoiceSample.Origin
            switch how {
            case .none: continue
            case .autoMatch(let s): origin = .autoMatch(s)
            case .ownerNamed: origin = .ownerNamed
            case .inviteInference: origin = .inviteInference
            }
            // The owner's voice is the library's own owner profile; it is never made here.
            let to: String
            if naming.owner.contains(key) {
                guard let owner = library.owner?.name else { continue }
                to = owner
            } else {
                to = name
            }
            let detail = record.speakerSamples?[key]
            try library.add(e, to: to, source: VoiceSampleSource(callID: callID, speakerKey: key, recorded: record.start,
                                                                 seconds: detail?.seconds, quality: detail?.quality, origin: origin))
        }
    }

}
