import Foundation

/// Who the names of a meeting are, for the filter's people: the saved people, their durable ids, and the owner
/// (who is in every meeting, so never a choice).
public struct MeetingFilterPeople: Sendable {
    public let directory: PersonDirectory
    /// A saved person's name to their `PersonID`. Empty where there is no people store (a preview, the iPhone):
    /// a saved person is then found by the saved name.
    public let ids: [String: String]
    public let owner: String
    /// Changes when the saved people, their ids, or the owner do: rows made with another one are made again.
    let stamp: Int

    public init(directory: PersonDirectory = PersonDirectory(), ids: [String: String] = [:], owner: String = "") {
        self.directory = directory
        self.ids = ids
        self.owner = owner
        var h = Hasher()
        for p in directory.people {
            h.combine(p.name)
            h.combine(p.email)
        }
        h.combine(ids)
        h.combine(owner)
        stamp = h.finalize()
    }

    /// From the voice library's people. With a people store, each gets the id of its person there.
    public init(profiles: [VoiceProfile], store: PeopleStore?, owner: String) {
        var ids: [String: String] = [:]
        if let store {
            for p in profiles { ids[p.name] = store.id(forVoiceName: p.name, isOwner: p.isOwner)?.rawValue }
        }
        self.init(directory: PersonDirectory(profiles: profiles), ids: ids, owner: owner)
    }

    private func who(saved name: String) -> MeetingFilter.Who { MeetingFilter.Who(id: ids[name], name: name) }

    /// The people of one meeting, the ones who spoke first: each named voice, then each invited person. A named
    /// voice is the saved person of that name. An invited name or address is a saved person only on a sure match
    /// (`PersonDirectory.link`); any other invited name is a person by that name, and an address of nobody saved
    /// is nobody. Unnamed voices and the owner are left out.
    func people(of r: CallRecord) -> [MeetingFilter.Who] {
        let ownerKey = PersonNames.key(owner)
        var out: [MeetingFilter.Who] = [], seen: Set<String> = []
        func add(_ who: MeetingFilter.Who) {
            guard PersonNames.key(who.name) != ownerKey || ownerKey.isEmpty, seen.insert(who.key).inserted else { return }
            out.append(who)
        }
        var spoke: [String] = []
        for u in r.utterances {
            if let name = r.speakerNames[u.speakerKey], !spoke.contains(name) { spoke.append(name) }
        }
        for name in spoke { add(who(saved: name)) }
        guard !r.attendees.isEmpty else { return out }

        let meeting = spoke + r.attendees.filter { !$0.contains("@") }
        let invited = directory.with(invitees: r.invitees)
        let own = (r.invitees ?? []).filter { $0.isSelf == true }
        let ownNames = Set(own.compactMap { $0.name.map(PersonNames.nameKey) }), ownEmails = Set(own.compactMap(\.email))
        for text in r.attendees {
            let written = PersonNames.plain(text)
            if ownNames.contains(PersonNames.nameKey(text)) || ownEmails.contains(text.lowercased()) { continue }
            if let saved = invited.link(for: text, in: meeting) {
                add(who(saved: saved))
            } else if !written.isEmpty, !written.contains("@") {
                add(MeetingFilter.Who(name: written))
            }
        }
        return out
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
    public var people: [MeetingFilter.Who]
    public var tags: [String]
    public var kind: String?
    /// The voices that count, as the Analytics tab counts them; nil with no transcript.
    public var voices: Int?
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
        self.people = people.people(of: r)
        tags = r.tags
        kind = r.kind?.trimmingCharacters(in: .whitespacesAndNewlines).nonBlank
        if r.utterances.isEmpty {
            voices = nil
        } else {
            let lanes = SpeakerLanes.make(r, names: MarkdownWriter.displayNames(r), ownerName: people.owner)
            let speech = lanes.reduce(0) { $0 + $1.seconds }
            voices = lanes.filter { MeetingFacts.isMain(seconds: $0.seconds, share: speech > 0 ? $0.seconds / speech : 0) }.count
        }
        if r.summary != nil {
            actionItems = r.actionItems.count
            decisions = r.decisions.count
        }
        screens = r.screens?.count
        value = rating
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
            let stamp = MeetingAnalytics.stamp(r)
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
