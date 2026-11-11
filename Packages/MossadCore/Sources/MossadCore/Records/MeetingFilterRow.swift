import Foundation

/// Who the names of a meeting are, for the filter's people: the saved people, their durable ids, and the owner
/// (who is in every meeting, so never a choice).
public struct MeetingFilterPeople: Sendable {
    public let directory: PersonDirectory
    /// A saved person's name to their `PersonID`. Empty where there is no people store (a preview, the iPhone):
    /// a saved person is then found by the saved name.
    public let ids: [String: String]
    public let owner: String
    /// The keys of every name the owner has or had: the owner's lines in an old meeting can be under an older name.
    let ownerKeys: Set<String>
    /// Changes when the saved people, their ids, or the owner do: rows made with another one are made again.
    let stamp: Int

    public init(directory: PersonDirectory = PersonDirectory(), ids: [String: String] = [:], owner: String = "", ownerNames: [String] = []) {
        self.directory = directory
        self.ids = ids
        self.owner = owner
        ownerKeys = Set(([owner] + ownerNames).map(PersonNames.key).filter { !$0.isEmpty })
        var h = Hasher()
        for p in directory.people {
            h.combine(p.name)
            h.combine(p.email)
        }
        h.combine(ids)
        h.combine(owner)
        h.combine(ownerKeys)
        stamp = h.finalize()
    }

    /// From the voice library's people. With a people store, each gets the id of its person there.
    public init(profiles: [VoiceProfile], store: PeopleStore?, owner: String) {
        var ids: [String: String] = [:]
        if let store {
            for p in profiles { ids[p.name] = store.id(forVoiceName: p.name, isOwner: p.isOwner)?.rawValue }
        }
        self.init(directory: PersonDirectory(profiles: profiles), ids: ids, owner: owner,
                  ownerNames: profiles.filter(\.isOwner).map(\.name) + (store?.ownerNames ?? []))
    }

    private func who(saved name: String) -> MeetingFilter.Who { MeetingFilter.Who(id: ids[name], name: name) }

    /// Who a meeting names besides the owner.
    struct Seen {
        /// Each named voice, in the order they first spoke.
        var spoke: [MeetingFilter.Who] = []
        /// Each invited person on a sure match: a saved person by the address or the whole name.
        var invited: [MeetingFilter.Who] = []
        /// Whether the invite names anyone else at all, sure or not.
        var othersInvited = false
        /// Invited names and addresses that are no saved person: people all the same, each one time.
        var unsureInvited: Set<String> = []

        /// The people of the meeting for the filter: who spoke, then who was invited, each one time.
        var people: [MeetingFilter.Who] {
            var seen: Set<String> = []
            return (spoke + invited).filter { seen.insert($0.key).inserted }
        }
    }

    /// A named voice is the saved person of that name. An invited name or address is a saved person only on a
    /// sure match (`PersonDirectory.link`); an invite does not say more than that, so any other name or address
    /// is nobody. Unnamed voices and the owner are left out.
    func seen(in r: CallRecord) -> Seen {
        var out = Seen()
        func isOwner(_ name: String) -> Bool { ownerKeys.contains(PersonNames.key(name)) }
        for u in r.utterances {
            if let name = r.speakerNames[u.speakerKey], !isOwner(name), !out.spoke.contains(where: { $0.name == name }) { out.spoke.append(who(saved: name)) }
        }
        guard !r.attendees.isEmpty else { return out }

        let meeting = r.utterances.compactMap { r.speakerNames[$0.speakerKey] } + r.attendees.filter { !$0.contains("@") }
        let invited = directory.with(invitees: r.invitees)
        let own = (r.invitees ?? []).filter { $0.isSelf == true }
        let ownNames = Set(own.compactMap { $0.name.map(PersonNames.nameKey) }), ownEmails = Set(own.compactMap(\.email))
        for text in r.attendees {
            if ownNames.contains(PersonNames.nameKey(text)) || ownEmails.contains(text.lowercased()) || isOwner(PersonNames.plain(text)) { continue }
            if let saved = invited.link(for: text, in: meeting) {
                if !isOwner(saved), !out.invited.contains(where: { $0.name == saved }) { out.invited.append(who(saved: saved)) }
            } else if !PersonNames.plain(text).isEmpty {
                out.othersInvited = true
                out.unsureInvited.insert(text.contains("@") ? text.lowercased() : PersonNames.nameKey(text))
            }
        }
        if !out.invited.isEmpty { out.othersInvited = true }
        // A name on the invite that also spoke is that voice, not one more person.
        out.unsureInvited.subtract(out.spoke.map { PersonNames.nameKey($0.name) })
        return out
    }

    /// How many people were in the meeting. The owner is there (Mossad recorded it on their Mac), each voice that
    /// counts is one more, and each sure invitee who did not speak may be one more: an unnamed voice can be that
    /// person, and an invite does not prove that they came. A size is given only when the fewest and the most
    /// people agree on it. "Just me" also needs the owner to speak with no other voice and nobody else invited;
    /// "1:1" needs the owner to speak, as the Analytics tab's partner does. A talk where the owner only listens
    /// can have any number of silent listeners.
    func size(of r: CallRecord, seen: Seen, lanes: [SpeakerLanes.Lane]) -> MeetingFilter.Size {
        let speech = lanes.reduce(0) { $0 + $1.seconds }
        let main = lanes.filter { MeetingFacts.isMain(seconds: $0.seconds, share: speech > 0 ? $0.seconds / speech : 0) }
        guard !main.isEmpty else { return .unknown }
        func named(_ lane: SpeakerLanes.Lane) -> Bool { r.speakerNames[lane.key] != nil }
        func isOwner(_ lane: SpeakerLanes.Lane) -> Bool { named(lane) && ownerKeys.contains(PersonNames.key(lane.name)) }
        let others = main.filter { !isOwner($0) }
        let spoke = Set(others.filter(named).map { who(saved: $0.name).key })
        let unnamed = others.filter { !named($0) }.count
        // An invited person with no saved record may also have been there, so they widen the most, as a sure one does.
        let silent = Set(seen.invited.map(\.key)).subtracting(spoke).count + seen.unsureInvited.count
        let fewest = 1 + spoke.count + unnamed, most = 1 + spoke.count + max(unnamed, silent)
        let size = MeetingFilter.Size(people: fewest)
        guard MeetingFilter.Size(people: most) == size else { return .unknown }
        let ownerSpoke = main.contains(where: isOwner)
        switch size {
        case .alone: return ownerSpoke && lanes.count == 1 && !seen.othersInvited ? .alone : .unknown
        case .oneOnOne: return ownerSpoke ? .oneOnOne : .unknown
        default: return size
        }
    }
}

/// What the filter reads of one meeting: small, so every meeting's row stays in memory and a change of the
/// filter never reads a transcript. A number that the meeting cannot give is nil, never 0.
public struct MeetingFilterRow: Sendable, Equatable {
    public var id: String
    public var start: Date
    /// The recorded length; for a joined meeting the length of its audio, without the time between its parts.
    public var seconds: TimeInterval
    public var platform: Platform
    /// Who spoke or was invited (on a sure match).
    public var people: [MeetingFilter.Who]
    public var tags: [String]
    public var kind: String?
    /// The voices that count, as the Analytics tab counts them; nil with no transcript.
    public var voices: Int?
    /// How many people were in it; `.unknown` when the meeting cannot say.
    public var size: MeetingFilter.Size
    /// Nil without a summary.
    public var actionItems: Int?
    public var decisions: Int?
    /// Nil for a call with no screen capture.
    public var screens: Int?
    /// The coach's rating; nil when the coach gave none.
    public var value: MeetingValue.Rating?

    /// Nil for the call that records now: it has no length, people, or summary yet, and the list shows it apart.
    public init?(record r: CallRecord, people: MeetingFilterPeople, rating: MeetingValue.Rating?) {
        guard r.status != .recording else { return nil }
        id = r.id
        start = r.start
        seconds = r.parts.last.map { $0.offset + max(0, $0.end.timeIntervalSince($0.start)) } ?? max(0, r.end.timeIntervalSince(r.start))
        platform = r.platform
        let seen = people.seen(in: r)
        self.people = seen.people
        tags = r.tags
        kind = r.kind?.trimmingCharacters(in: .whitespacesAndNewlines).nonBlank
        if r.utterances.isEmpty {
            voices = nil
            size = .unknown
        } else {
            let lanes = SpeakerLanes.make(r, names: MarkdownWriter.displayNames(r), ownerName: people.owner)
            let speech = lanes.reduce(0) { $0 + $1.seconds }
            voices = lanes.filter { MeetingFacts.isMain(seconds: $0.seconds, share: speech > 0 ? $0.seconds / speech : 0) }.count
            size = people.size(of: r, seen: seen, lanes: lanes)
        }
        if r.summary != nil {
            actionItems = r.actionItems.count
            decisions = r.decisions.count
        }
        screens = r.screens?.count
        value = rating
    }

    /// Equal, and each person under the same name. `Who` is equal on its key alone, so a new name of a saved
    /// person is no change to `==`; the flyout and the chips must still show it.
    public static func same(_ a: [MeetingFilterRow], _ b: [MeetingFilterRow]) -> Bool {
        a == b && a.map { $0.people.map(\.name) } == b.map { $0.people.map(\.name) }
    }

    /// Changes when anything the row reads changes: the Analytics stamp has no screens and no platform.
    static func stamp(_ r: CallRecord) -> Int {
        var h = Hasher()
        h.combine(MeetingAnalytics.stamp(r))
        h.combine(r.screens?.count)
        h.combine(r.platform)
        return h.finalize()
    }
}

/// Every meeting's row, kept between changes of the list. A row is made again only when its record or the saved
/// people changed, so a new or edited meeting costs one meeting's work. Call it off the main thread: the first
/// call reads every meeting.
public final class MeetingFilterRows: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (stamp: Int, row: MeetingFilterRow)] = [:]
    private var people = 0
    private var reads = 0
    /// How many records were read for their rows so far, for tests.
    var readCount: Int { lock.withLock { reads } }

    public init() {}

    /// The rows of `records` in their order, each with its rating; the call that records now has none.
    public func rows(for records: [CallRecord], people: MeetingFilterPeople, ratings: [String: MeetingValue.Rating]) -> [MeetingFilterRow] {
        let known: [String: (stamp: Int, row: MeetingFilterRow)] = lock.withLock { self.people == people.stamp ? entries : [:] }
        var kept: [String: (stamp: Int, row: MeetingFilterRow)] = [:]
        var out: [MeetingFilterRow] = []
        var read = 0
        for r in records where r.status != .recording {
            let stamp = MeetingFilterRow.stamp(r)
            var row: MeetingFilterRow
            if let hit = known[r.id], hit.stamp == stamp {
                row = hit.row
            } else if let made = MeetingFilterRow(record: r, people: people, rating: nil) {
                row = made
                read += 1
            } else {
                continue
            }
            row.value = ratings[r.id]
            kept[r.id] = (stamp, row)
            out.append(row)
        }
        lock.withLock {
            entries = kept
            self.people = people.stamp
            reads += read
        }
        return out
    }
}

/// The coach's rating of each meeting that has one, read from the review files. A file is decoded only when it
/// changed since the last read. Call it off the main thread.
public final class MeetingRatings: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (stamp: String, rating: MeetingValue.Rating?)] = [:]
    private var decodes = 0
    /// How many review files were decoded so far, for tests.
    var decodeCount: Int { lock.withLock { decodes } }

    public init() {}

    public func read(ids: [String], directory: (String) -> URL) -> [String: MeetingValue.Rating] {
        let known = lock.withLock { entries }
        var kept: [String: (stamp: String, rating: MeetingValue.Rating?)] = [:]
        var out: [String: MeetingValue.Rating] = [:]
        var decoded = 0
        for id in ids {
            let dir = directory(id)
            guard let a = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(CoachReview.fileName).path) else { continue }
            let stamp = "\(a[.size] as? Int ?? 0)|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(a[.systemFileNumber] as? Int ?? 0)"
            let entry: (stamp: String, rating: MeetingValue.Rating?)
            if let hit = known[id], hit.stamp == stamp {
                entry = hit
            } else {
                entry = (stamp, CoachReview.load(in: dir)?.value?.rating)
                decoded += 1
            }
            kept[id] = entry
            if let rating = entry.rating { out[id] = rating }
        }
        lock.withLock {
            entries = kept
            decodes += decoded
        }
        return out
    }
}
