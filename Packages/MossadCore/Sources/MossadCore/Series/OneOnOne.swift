import Foundation

/// Whether a meeting is a 1:1 with one person: a person's points belong to a 1:1 with that person, never to a group
/// meeting the person is in. One rule for each state of a meeting. Each gives the person's id of now, or nil when it is
/// not a 1:1 with one sure person or when Mossad does not know.
public enum OneOnOne {
    /// An upcoming invite: exactly one entry invited besides the owner (`MeetingPrep.invited`, which counts a room or
    /// a group address as an entry), and that entry is surely one saved person (`NextTimeInvite`: an address, a whole
    /// name, or an id; a merged person is the one they were merged into).
    public static func person(ofInvite attendees: [String], owner: String, directory: PersonDirectory, ownerEmails: [String] = [],
                              people refs: PersonReferences) -> String? {
        guard MeetingPrep.invited(attendees, owner: owner, directory: directory, ownerEmails: ownerEmails).count == 1 else { return nil }
        let ids = NextTimeInvite.personIDs(attendees, people: refs)
        return ids.count == 1 ? ids[0] : nil
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

    /// A recording that ended: the rule of the check after the call (`NextTimeRules.onlyOther`).
    public static func person(ofRecording r: CallRecord, owner: String, directory: PersonDirectory, ownerEmails: [String] = [],
                              people refs: PersonReferences) -> String? {
        NextTimeRules.onlyOther(r, owner: owner, directory: directory, ownerEmails: ownerEmails, people: refs)?.id
    }
}

extension LiveTranscript {
    /// Each voice of the call audio once, by its key, with its name of now (nil for a voice with no name). A voice
    /// named the owner is left out. A line with no label yet is no voice.
    public func otherVoices(owner: String) -> [String?] {
        let ownerKey = PeopleDuplicates.normalized(owner)
        var seen: Set<String> = []
        var out: [String?] = []
        for line in lines where line.source == .them {
            guard let key = line.speakerKey, seen.insert(key).inserted else { continue }
            let name = names[key]
            if let name, PeopleDuplicates.normalized(name) == ownerKey { continue }
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
        r.map(NextTimeRules.ownerMissed) == false ? "Came up here, for a 1:1" : "Your open points in these notes"
    }

    /// The line under one point.
    public static func still(_ p: NextTimePoint, in r: CallRecord?) -> String {
        guard r.map(NextTimeRules.ownerMissed) == false else { return "Still open. Mossad has only the notes of this meeting" }
        if p.isForPerson { return "Still open for your next 1:1 with \(SeriesNamesCore.first(p.personName ?? "them"))" }
        return "Still open"
    }
}

/// The first name of a saved name, for short words. An address stays whole.
public enum SeriesNamesCore {
    public static func first(_ name: String) -> String { name.contains("@") ? name : String(name.split(separator: " ").first ?? Substring(name)) }
}
