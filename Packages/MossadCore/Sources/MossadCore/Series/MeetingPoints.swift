import CryptoKit
import Foundation

/// What only this Mac knows of the one meeting a point is for: its title, its planned times, a hash of the invite's
/// iCalendar UID, the saved people invited, and how many people besides the owner were invited. Kept in
/// `NextTime/meeting-points-local.json` (`MeetingPointsLocal`), never in the synced book: nothing of an upcoming meeting
/// goes to the server. The chat's own request keeps the same words (`ChatActionRequest.meeting`).
public struct MeetingDetail: Codable, Equatable, Sendable, Hashable {
    public var title: String
    /// The planned times, as the calendar has them now: a moved invite moves them (`NextTimeBook.followMeetings`).
    public var start: Date
    public var end: Date
    /// A hash of the invite's iCalendar UID, which the Mac's calendar and Google give alike: it finds the invite after
    /// a move.
    public var event: String?
    /// The saved people invited, without the owner, by id and on a sure match: where the owner can move the point.
    public var people: [String]?
    /// Everyone invited besides the owner, saved or not: a sure 1:1 has one.
    public var invited: Int?

    public init(title: String, start: Date, end: Date, event: String? = nil, people: [String]? = nil, invited: Int? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.event = event
        self.people = people
        self.invited = invited
    }

    /// The meeting of an invite. `people` are its saved people (`NextTimeInvite.personIDs`), `invited` everyone
    /// invited besides the owner (`MeetingPrep.invited`).
    public init(_ u: UpcomingMeeting, people: [String] = [], invited: Int? = nil) {
        self.init(title: u.title, start: u.start, end: u.end, event: NextTimeMeeting.event(u.uid), people: people.isEmpty ? nil : people, invited: invited)
    }

    /// A sure 1:1: one person invited besides the owner, and that person is surely saved.
    public var onlyPerson: String? { invited == 1 && people?.count == 1 ? people?.first : nil }

    func at(_ title: String, _ start: Date) -> Bool {
        abs(start.timeIntervalSince(self.start)) < NextTimeMeeting.near && Self.key(title) == Self.key(self.title)
    }

    static func key(_ title: String) -> String { PeopleDuplicates.normalized(title) }
}

/// The one meeting a point is for, when that meeting is not part of a recurring series. The synced book holds only
/// the recordings the check found (`calls`); the rest is this Mac's `detail`, which is never encoded with the point.
public struct NextTimeMeeting: Codable, Equatable, Sendable, Hashable {
    /// The recordings that were this meeting, as the check after it found them.
    public var calls: [String]?
    /// This Mac's detail of the meeting (`MeetingPointsLocal`). Nil on another device, or when the local file is lost.
    public var detail: MeetingDetail?

    public init(_ detail: MeetingDetail? = nil, calls: [String]? = nil) {
        self.detail = detail
        self.calls = calls
    }

    /// The meeting of an invite, with this Mac's detail of it.
    public init(_ u: UpcomingMeeting, people: [String] = [], invited: Int? = nil) {
        self.init(MeetingDetail(u, people: people, invited: invited))
    }

    enum CodingKeys: String, CodingKey { case calls }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calls = try c.decodeIfPresent([String].self, forKey: .calls)
    }

    /// Only the recordings: the title, the times, the hash, and the people stay on this Mac.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(calls, forKey: .calls)
    }

    /// A start this close is the same start: the two calendars agree within a minute (`CalendarMerge`).
    static let near: TimeInterval = 60
    /// After the planned end, this long is still the meeting's: a call that starts late is not "not recorded".
    public static let grace: TimeInterval = 1800

    static func event(_ uid: String?) -> String? {
        guard let uid = uid?.nonBlank else { return nil }
        return SHA256.hash(data: Data(uid.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The same invite: by its UID when it does not repeat (every meeting of a repeated event has the one UID), else
    /// by the title and the start. Without this Mac's detail, no invite is known to be it.
    public func matches(_ u: UpcomingMeeting) -> Bool {
        guard let d = detail else { return false }
        if let event = d.event, !u.repeats, Self.event(u.uid) == event { return true }
        return d.at(u.title, u.start)
    }

    /// A recording of it: one the check found, or one whose invite has its title and its planned start. A second
    /// record of the same meeting has the same invite.
    public func matches(_ r: CallRecord) -> Bool {
        if calls?.contains(r.id) == true { return true }
        guard let d = detail, let title = r.calendarTitle, let planned = r.plannedStart else { return false }
        return d.at(title, planned)
    }

    /// The same meeting as another point's.
    func same(_ other: NextTimeMeeting) -> Bool {
        guard let a = detail, let b = other.detail else { return false }
        if let event = a.event, event == b.event { return true }
        return a.at(b.title, b.start)
    }

    /// Two copies of one point: the newer copy's meeting, else the other's (an older build left it out), with the
    /// recordings of both and this Mac's detail from either.
    static func merged(_ newer: NextTimeMeeting?, _ other: NextTimeMeeting?) -> NextTimeMeeting? {
        guard var out = newer ?? other else { return nil }
        let calls = Array(Set((newer?.calls ?? []) + (other?.calls ?? []))).sorted()
        out.calls = calls.isEmpty ? nil : calls
        out.detail = newer?.detail ?? other?.detail
        return out
    }
}

/// This Mac's detail of each meeting point, by point id: `NextTime/meeting-points-local.json`, in the profile's data
/// folder. Never synced, never in the digest or a shared payload. A newer file is read and never saved; one that does
/// not decode is set aside.
public struct MeetingPointsLocal: Codable, Equatable, Sendable {
    public static let fileName = "meeting-points-local.json"
    public static let currentVersion = 1
    public var version = MeetingPointsLocal.currentVersion
    public var points: [String: MeetingDetail] = [:]

    public init(points: [String: MeetingDetail] = [:]) { self.points = points }

    enum CodingKeys: String, CodingKey { case version, points }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        points = try c.decodeIfPresent([String: MeetingDetail].self, forKey: .points) ?? [:]
    }

    static func url(_ dir: URL) -> URL { dir.appendingPathComponent(fileName) }

    /// For a page that only reads: no file, or one that does not read, is no detail.
    static func peek(in dir: URL) -> MeetingPointsLocal? {
        (try? Data(contentsOf: url(dir))).flatMap { try? JSONDecoder.coach.decode(MeetingPointsLocal.self, from: $0) }
    }

    /// For a change: a file that does not decode is set aside and the book goes on without the detail.
    static func load(in dir: URL) -> MeetingPointsLocal? {
        (try? StoredFile.load(MeetingPointsLocal.self, from: url(dir), decoder: .coach)) ?? nil
    }

    /// The detail of each live point that has some. Nil when there is none and no file to clear.
    static func of(_ book: NextTimeBook) -> MeetingPointsLocal {
        var out = MeetingPointsLocal()
        for p in book.points where !p.deleted { if let d = p.meeting?.detail { out.points[p.id.uuidString] = d } }
        return out
    }

    func save(in dir: URL) throws {
        let file = Self.url(dir)
        guard !points.isEmpty || FileManager.default.fileExists(atPath: file.path) else { return }
        try JSONEncoder.coach.encode(self).write(to: file, options: .atomic)
    }
}

extension NextTimeBook {
    /// Gives each meeting point this Mac's detail.
    mutating func attach(_ local: MeetingPointsLocal?) {
        guard let local, !local.points.isEmpty else { return }
        for i in points.indices where points[i].meeting != nil {
            if let d = local.points[points[i].id.uuidString] { points[i].meeting?.detail = d }
        }
    }
}

extension NextTimeBook {
    private static func ordered(_ a: NextTimePoint, _ b: NextTimePoint) -> Bool { (a.rank, a.created) < (b.rank, b.created) }

    /// The open points of one meeting with no series, in their order.
    public func points(forMeeting m: NextTimeMeeting) -> [NextTimePoint] {
        visible.filter { $0.isOpen && $0.isForMeeting && $0.meeting?.same(m) == true }.sorted(by: Self.ordered)
    }

    /// The open points of an invite that has no series.
    public func points(forMeeting u: UpcomingMeeting) -> [NextTimePoint] {
        visible.filter { $0.isOpen && $0.isForMeeting && $0.meeting?.matches(u) == true }.sorted(by: Self.ordered)
    }

    /// The open points that a recorded meeting left with it: its own, not raised, in a meeting that was not a 1:1 with
    /// one sure person. `record` matches by its invite before the check ran; without it, only what the check found. A
    /// meeting the owner missed holds none: its points wait as not recorded.
    public func leftOpen(in callID: String, record: CallRecord? = nil) -> [NextTimePoint] {
        if let record, NextTimeRules.ownerMissed(record) { return [] }
        return visible.filter { p in
            guard p.isOpen, p.isForMeeting, let m = p.meeting else { return false }
            return m.calls?.contains(callID) == true || record.map(m.matches) == true
        }.sorted(by: Self.ordered)
    }

    /// The open points of meetings that are over with no recording the owner was in (cancelled, skipped, too short to
    /// keep, not recorded, or missed), and the points whose meeting this Mac does not know (another Mac, a lost file),
    /// so no point is in no list. A meeting that moves to another profile holds its points while it waits.
    public func unrecorded(records: [CallRecord], now: Date = Date()) -> [NextTimePoint] {
        let candidates = visible.filter { $0.isOpen && $0.isForMeeting }
        guard !candidates.isEmpty else { return [] }
        let held = records.filter { !NextTimeRules.ownerMissed($0) }
        return candidates.filter { p in
            guard let m = p.meeting else { return false }
            guard let d = m.detail else { return m.calls?.isEmpty != false }
            return d.end.addingTimeInterval(NextTimeMeeting.grace) < now && !held.contains { m.matches($0) }
        }.sorted { ($0.meeting?.detail?.start ?? $0.created, $0.rank) < ($1.meeting?.detail?.start ?? $1.created, $1.rank) }
    }

    /// The waiting points of an earlier meeting with this invite's title, when this invite is the next one with it.
    public func waiting(for u: UpcomingMeeting, upcoming: [UpcomingMeeting], waiting: [NextTimePoint]) -> [NextTimePoint] {
        let key = MeetingDetail.key(u.title)
        guard upcoming.filter({ MeetingDetail.key($0.title) == key }).min(by: { $0.start < $1.start })?.id == u.id else { return [] }
        return waiting.filter { p in p.meeting?.detail.map { MeetingDetail.key($0.title) == key && $0.start < u.start } == true }
    }

    /// The owner gives a waiting point to this invite.
    public mutating func give(_ id: UUID, to detail: MeetingDetail, at date: Date = Date()) {
        update(id, at: date) { p in p.meeting = NextTimeMeeting(detail) }
    }

    /// The owner moves a point to the next time they see a person.
    public mutating func move(_ id: UUID, toPerson personID: String, name: String, at date: Date = Date()) {
        update(id, at: date) { p in
            p.seriesID = nil
            p.seriesKeys = nil
            p.seriesTitle = nil
            p.personID = personID
            p.personName = name
        }
    }

    /// The owner moves a point to the next meeting of a series.
    public mutating func move(_ id: UUID, to s: MeetingSeries, at date: Date = Date()) {
        update(id, at: date) { p in
            p.seriesID = s.id
            p.seriesKeys = s.savedKeys
            p.seriesTitle = s.title
            p.personID = nil
            p.personName = nil
        }
    }

    /// Each open point of one meeting follows its invite: its planned times when the invite moved, and its series once
    /// the invite has one (the calendar says it repeats, or the catalog joined it to earlier meetings), from then on as
    /// a series point. Only through an invite still to come: a meeting that happened keeps its points under its
    /// Summary, and in a 1:1 the check moves them to the person. A meeting that is over with no recording the owner
    /// was in, whose invite was a sure 1:1 (`MeetingDetail.onlyPerson`), gives its points to that person when `name`
    /// knows them. Returns whether anything changed. A move of the times is not the owner's change.
    @discardableResult
    public mutating func followMeetings(upcoming: [UpcomingMeeting], series all: [MeetingSeries], records: [CallRecord], at date: Date = Date(),
                                        name: (String) -> String? = { _ in nil }) -> Bool {
        guard points.contains(where: { $0.isOpen && $0.isForMeeting }) else { return false }
        let waiting = Set(unrecorded(records: records, now: date).map(\.id))
        var changed = false
        for i in points.indices where points[i].isOpen && points[i].isForMeeting {
            guard var m = points[i].meeting, let d = m.detail else { continue }
            let invite = upcoming.first { m.matches($0) }
            if let s = invite.flatMap({ SeriesCatalog.series(of: $0, in: all) }) {
                move(points[i].id, to: s, at: date)
                changed = true
            } else if let u = invite, u.start != d.start || u.end != d.end || u.title != d.title {
                m.detail?.start = u.start
                m.detail?.end = u.end
                m.detail?.title = u.title
                points[i].meeting = m
                changed = true
            } else if waiting.contains(points[i].id), m.calls?.isEmpty != false, let id = d.onlyPerson, let who = name(id) {
                move(points[i].id, toPerson: id, name: who, at: date)
                changed = true
            }
        }
        return changed
    }
}

extension NextTimeRules {
    /// The one other person of a 1:1: everyone invited other than the owner is one entry, and that entry is surely one
    /// saved person (`NextTimeInvite`). Nil for a group, a room, or a person who is not surely saved, and nil when the
    /// call says otherwise: an invite that was not surely the call's, more than one other person among the main voices
    /// (`OneOnOne.otherPeople`), or a size of the meeting that is known and not a 1:1 (`MeetingFacts.size`, the Meetings filter's rule).
    /// A size that is not known, with one other voice or none, leaves it to the invite.
    public static func onlyOther(_ r: CallRecord, owner: String, directory: PersonDirectory, ownerEmails: [String] = [],
                                 people refs: PersonReferences) -> (id: String, name: String)? {
        guard r.inviteNotSure != true,
              MeetingPrep.invited(r.attendees, owner: owner, directory: directory, ownerEmails: ownerEmails).count == 1 else { return nil }
        let ids = NextTimeInvite.personIDs(r.attendees, people: refs)
        guard ids.count == 1, let name = refs.name(of: ids[0]) else { return nil }
        // People, not keys: two keys of one person are one, and a voice with a few words is none (`OneOnOne.otherPeople`).
        guard OneOnOne.otherPeople(r, owner: owner, people: refs).count <= 1 else { return nil }
        let size = MeetingFacts(record: r, owner: owner).size(people: MeetingFilterPeople(directory: directory, owner: owner))
        guard size == .unknown || size == .oneOnOne else { return nil }
        return (ids[0], name)
    }
}
