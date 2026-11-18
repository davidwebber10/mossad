import Foundation

/// Whether a meeting is a 1:1 with one person: a person's points belong to a 1:1 with that person, never to a group
/// meeting the person is in. One rule for each state of a meeting. Each gives the person's id of now, or nil when it is
/// not a 1:1 with one sure person or when Mossad does not know.
public enum OneOnOne {
    /// An upcoming invite: exactly one person invited besides the owner, and that person is surely one saved person.
    /// The entries come from `MeetingPrep.invited` (a group address is an entry; a room or a resource is not, as both
    /// calendar reads leave them out); each entry counts by its saved person when the people store surely knows it
    /// (`NextTimeInvite`: an address, a whole name, or an id, through `canonical`), so a person under two addresses is
    /// one, and the owner under an address only the people store knows is left out.
    public static func person(ofInvite attendees: [String], owner: String, directory: PersonDirectory, ownerEmails: [String] = [],
                              people refs: PersonReferences) -> String? {
        var ids: Set<String> = []
        var unknown = 0
        for i in MeetingPrep.invited(attendees, owner: owner, directory: directory, ownerEmails: ownerEmails) {
            guard let id = (refs.id(for: i.written) ?? i.person.flatMap { refs.id(for: $0) }).map(refs.canonical) else {
                unknown += 1
                continue
            }
            if refs.person(id)?.isOwner == true { continue }
            ids.insert(id)
        }
        return unknown == 0 && ids.count == 1 ? ids.first : nil
    }

    /// The call that records now. With an invite: the invite's rule, only when the invite is surely the call's. With
    /// no invite: exactly one other voice is heard, it has a name, and that name is surely one saved person. A voice
    /// with no name may be anyone, so it makes the answer no. `otherVoices` are the call audio's voices with their
    /// names of now (`LiveTranscript.otherVoices`): a name that changes or a second voice that comes changes the answer.
    public static func person(ofLive r: CallRecord, otherVoices: [String?], owner: String, directory: PersonDirectory, ownerEmails: [String] = [],
                              people refs: PersonReferences) -> String? {
        if !r.attendees.isEmpty || r.calendarTitle != nil {
            guard r.inviteNotSure != true else { return nil }
            return person(ofInvite: r.attendees, owner: owner, directory: directory, ownerEmails: ownerEmails, people: refs)
        }
        let ownerKey = PeopleDuplicates.normalized(owner)
        var ids: Set<String> = []
        for voice in otherVoices {
            guard let name = voice else { return nil }
            if PeopleDuplicates.normalized(name) == ownerKey { continue }
            guard let id = refs.id(for: name).map(refs.canonical) else { return nil }
            if refs.person(id)?.isOwner == true { continue }
            ids.insert(id)
        }
        return ids.count == 1 ? ids.first : nil
    }

    /// A recording that ended. With an invite: the rule of the check after the call (`NextTimeRules.onlyOther`). With
    /// no invite (and an invite that is not "not known yet", `inviteUnknown`): exactly one other person among the main
    /// voices (`otherPeople`), who is surely one saved person, and a size by the Meetings filter's rule that is a 1:1
    /// or not known.
    public static func person(ofRecording r: CallRecord, owner: String, directory: PersonDirectory, ownerEmails: [String] = [],
                              people refs: PersonReferences) -> String? {
        if !r.attendees.isEmpty || r.calendarTitle != nil {
            return NextTimeRules.onlyOther(r, owner: owner, directory: directory, ownerEmails: ownerEmails, people: refs)?.id
        }
        guard r.inviteUnknown != true else { return nil }
        let others = otherPeople(r, owner: owner, people: refs)
        guard others.count == 1, let only = others.first, let id = only, id.hasPrefix(savedPrefix) else { return nil }
        let size = MeetingFacts(record: r, owner: owner).size(people: MeetingFilterPeople(directory: directory, owner: owner))
        guard size == .unknown || size == .oneOnOne else { return nil }
        return String(id.dropFirst(savedPrefix.count))
    }

    static let savedPrefix = "id:"

    /// The other people of a recording among its main voices (`MeetingFacts.isMain`: 10 s of speech and 2% of the
    /// talk), each once: a saved person by the id of now ("id:<id>"), another named voice by its name, a voice with no
    /// name as nil (anyone). The owner is left out, and so is a voice of the owner's microphone with no name. Two keys
    /// of one person are one person; a key with a few words is no person.
    static func otherPeople(_ r: CallRecord, owner: String, people refs: PersonReferences) -> [String?] {
        var named: [String] = []
        var unnamed = 0
        for v in MeetingAnalytics.Voices(record: r, owner: owner).speakers
        where !v.isOwner && MeetingFacts.isMain(seconds: v.seconds, share: v.share) {
            if v.isUnknown {
                if !v.id.hasPrefix("me:") { unnamed += 1 }
                continue
            }
            if PeopleDuplicates.normalized(v.name) == PeopleDuplicates.normalized(owner) { continue }
            let id = (r.speakerPeople?[v.id] ?? refs.id(for: v.name)).map(refs.canonical)
            if let id, refs.person(id)?.isOwner == true { continue }
            let key = id.map { savedPrefix + $0 } ?? "name:" + PeopleDuplicates.normalized(v.name)
            if !named.contains(key) { named.append(key) }
        }
        return named.map { Optional($0) } + Array(repeating: nil, count: unnamed)
    }

    /// A recurring series is a 1:1 series with one person when its usual people, besides the owner, are exactly one
    /// person, and that person is surely saved. A usual person who is not saved is still a person.
    public static func person(ofSeries usualPeople: [String], owner: String, people refs: PersonReferences) -> String? {
        var ids: Set<String> = []
        var unknown = 0
        for name in usualPeople where PeopleDuplicates.normalized(name) != PeopleDuplicates.normalized(owner) {
            guard let id = refs.id(for: name).map(refs.canonical) else { unknown += 1; continue }
            if refs.person(id)?.isOwner == true { continue }
            ids.insert(id)
        }
        return unknown == 0 && ids.count == 1 ? ids.first : nil
    }
}

extension CalendarMatcher {
    /// The invited entries of the Mac's calendar without a room or a resource, as the Google read leaves them out: a
    /// booked room is not a person in the meeting. A group address stays: it is many people.
    public static func invitedAttendees(_ entries: [(written: String, kind: String?)]) -> [String] {
        entries.filter { $0.kind != "room" && $0.kind != "resource" }.map(\.written)
    }
}

extension LiveTranscript {
    /// A voice with no name and less speech than this may be a stray label of the stream: it is not another person.
    static let strayVoiceSeconds: TimeInterval = 10

    /// Each voice of the call audio once, by its key, with its name of now (nil for a voice with no name). A voice
    /// named the owner is left out, a line with no label yet is no voice, and a voice with no name and under 10 s of
    /// final speech is no voice either.
    public func otherVoices(owner: String) -> [String?] {
        let ownerKey = PeopleDuplicates.normalized(owner)
        var order: [String] = []
        var speech: [String: TimeInterval] = [:]
        for line in lines where line.source == .them {
            guard let key = line.speakerKey else { continue }
            if !order.contains(key) { order.append(key) }
            guard line.isFinal || line.session < session else { continue }
            if let start = line.audioStart, let end = line.audioEnd {
                speech[key, default: 0] += max(0, end - start)
            } else {
                // No word times: about two and a half words a second.
                speech[key, default: 0] += Double(line.text.split(whereSeparator: \.isWhitespace).count) / 2.5
            }
        }
        var out: [String?] = []
        for key in order {
            let name = names[key]
            if let name, PeopleDuplicates.normalized(name) == ownerKey { continue }
            if name == nil, speech[key, default: 0] < Self.strayVoiceSeconds { continue }
            out.append(name)
        }
        return out
    }
}

extension NextTimeBook {
    /// For each of `people` whose points do not show in this meeting (it is not a 1:1 with them), how many open
    /// points wait for them, in the order of `people`. The prep page says only the count, never a point's words.
    public func personCounts(_ people: [String], oneOnOne: String?, canonical: (String) -> String = { $0 }) -> [(person: String, count: Int)] {
        var seen: Set<String> = []
        var out: [(person: String, count: Int)] = []
        for id in people {
            let wanted = canonical(id)
            guard wanted != oneOnOne.map(canonical), seen.insert(wanted).inserted else { continue }
            let n = points(forPerson: wanted, canonical: canonical).count
            if n > 0 { out.append((wanted, n)) }
        }
        return out
    }
}

extension NextTimePoint.Mention {
    /// "Came up on Nov 12 in Product review": where a point came up that stayed open. A meeting the owner missed keeps
    /// its words of before; a meeting that is gone is "a meeting".
    public func note(meeting r: CallRecord?) -> String {
        let day = "Came up on \(date.formatted(.dateTime.month(.abbreviated).day()))"
        guard let r else { return day + " in a meeting" }
        if NextTimeRules.ownerMissed(r) { return day + ", in a meeting Mossad has only the notes of" }
        return day + " in \(r.title)"
    }
}

/// The words under a written meeting for the open points that came up in it.
public enum MentionWords {
    /// The group's label: a meeting the owner missed holds the owner's points as notes; another meeting held a person's
    /// points that wait for a 1:1.
    public static func label(_ r: CallRecord?) -> String {
        guard let r else { return "Your open points that came up here" }
        return NextTimeRules.ownerMissed(r) ? "Your open points in these notes" : "Came up here, for a 1:1"
    }

    /// The line under one point.
    public static func still(_ p: NextTimePoint, in r: CallRecord?) -> String {
        if let r, NextTimeRules.ownerMissed(r) { return "Still open. Mossad has only the notes of this meeting" }
        if p.isForPerson { return "Still open for your next 1:1 with \(SeriesNamesCore.first(p.personName ?? "them"))" }
        return "Still open"
    }
}

/// The first name of a saved name, for short words. An address stays whole.
public enum SeriesNamesCore {
    public static func first(_ name: String) -> String { name.contains("@") ? name : String(name.split(separator: " ").first ?? Substring(name)) }
}

