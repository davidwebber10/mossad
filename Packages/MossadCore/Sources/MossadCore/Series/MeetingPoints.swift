import CryptoKit
import Foundation

/// The one meeting a point is for, when that meeting is not part of a recurring series: what finds it again as an
/// invite of the calendar and as the recording of it. The owner's own note of it: its title and planned times, never
/// its people's addresses, its link, or its text.
public struct NextTimeMeeting: Codable, Equatable, Sendable, Hashable {
    public var title: String
    /// The planned times, as the calendar has them now: a moved invite moves them (`NextTimeBook.followMeetings`).
    public var start: Date
    public var end: Date
    /// A hash of the invite's iCalendar UID, which the Mac's calendar and Google give alike: it finds the invite after
    /// a move. It says nothing to anyone who does not have the calendar.
    public var event: String?
    /// The saved people invited, without the owner, by id and on a sure match: where the owner can move the point.
    public var people: [String]?
    /// The recordings that were this meeting, as the check after it found them.
    public var calls: [String]?

    public init(title: String, start: Date, end: Date, event: String? = nil, people: [String]? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.event = event
        self.people = people
    }

    /// The meeting of an invite. `people` are its saved people (`NextTimeInvite.personIDs`).
    public init(_ u: UpcomingMeeting, people: [String] = []) {
        self.init(title: u.title, start: u.start, end: u.end, event: Self.event(u.uid), people: people.isEmpty ? nil : people)
    }

    /// A start this close is the same start: the two calendars agree within a minute (`CalendarMerge`).
    static let near: TimeInterval = 60

    static func event(_ uid: String?) -> String? {
        guard let uid = uid?.nonBlank else { return nil }
        return SHA256.hash(data: Data(uid.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func key(_ title: String) -> String { PeopleDuplicates.normalized(title) }

    private func at(_ title: String, _ start: Date) -> Bool {
        Self.key(title) == Self.key(self.title) && abs(start.timeIntervalSince(self.start)) < Self.near
    }

    /// The same invite: by its UID when it does not repeat (every meeting of a repeated event has the one UID), else
    /// by the title and the start.
    public func matches(_ u: UpcomingMeeting) -> Bool {
        if let event, !u.repeats, Self.event(u.uid) == event { return true }
        return at(u.title, u.start)
    }

    /// A recording of it: one the check found, or one whose invite has its title and its planned start. A second
    /// record of the same meeting has the same invite.
    public func matches(_ r: CallRecord) -> Bool {
        if calls?.contains(r.id) == true { return true }
        guard let title = r.calendarTitle, let planned = r.plannedStart else { return false }
        return at(title, planned)
    }

    /// The same meeting as another point's.
    func same(_ other: NextTimeMeeting) -> Bool {
        if let event, event == other.event { return true }
        return at(other.title, other.start)
    }

    /// Two copies of one point: the newer copy's meeting, else the other's (an older build left it out), with the
    /// recordings of both.
    static func merged(_ newer: NextTimeMeeting?, _ other: NextTimeMeeting?) -> NextTimeMeeting? {
        guard var out = newer ?? other else { return nil }
        let calls = Array(Set((newer?.calls ?? []) + (other?.calls ?? []))).sorted()
        out.calls = calls.isEmpty ? nil : calls
        return out
    }
}

extension NextTimeBook {
    /// The open points of one meeting with no series, in their order.
    public func points(forMeeting m: NextTimeMeeting) -> [NextTimePoint] {
        visible.filter { $0.isOpen && $0.isForMeeting && $0.meeting?.same(m) == true }.sorted { ($0.rank, $0.created) < ($1.rank, $1.created) }
    }

    /// The open points of an invite that has no series.
    public func points(forMeeting u: UpcomingMeeting) -> [NextTimePoint] {
        visible.filter { $0.isOpen && $0.isForMeeting && $0.meeting?.matches(u) == true }.sorted { ($0.rank, $0.created) < ($1.rank, $1.created) }
    }

    /// The open points that a recorded meeting left with it: its own, not raised, in a meeting that was not a 1:1 with
    /// one sure person. `record` matches by its invite before the check ran; without it, only what the check found.
    public func leftOpen(in callID: String, record: CallRecord? = nil) -> [NextTimePoint] {
        visible.filter { p in
            guard p.isOpen, p.isForMeeting, let m = p.meeting else { return false }
            return m.calls?.contains(callID) == true || record.map(m.matches) == true
        }.sorted { ($0.rank, $0.created) < ($1.rank, $1.created) }
    }

    /// The open points that a meeting moved to a person: not raised in a 1:1.
    public func movedToPerson(from callID: String) -> [NextTimePoint] {
        visible.filter { $0.isOpen && $0.isForPerson && $0.meeting?.calls?.contains(callID) == true }
    }

    /// The open points of meetings that are over with no recording the owner was in: cancelled, skipped, too short to
    /// keep, not recorded, or missed. They stay open until the owner moves or deletes them.
    public func unrecorded(records: [CallRecord], now: Date = Date()) -> [NextTimePoint] {
        let kept = records.filter { $0.moveTo == nil && !NextTimeRules.ownerMissed($0) }
        return visible.filter { p in
            guard p.isOpen, p.isForMeeting, let m = p.meeting, m.end < now else { return false }
            return !kept.contains { m.matches($0) }
        }.sorted { ($0.meeting?.start ?? $0.created, $0.rank) < ($1.meeting?.start ?? $1.created, $1.rank) }
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

    /// Each open point of one meeting follows it: its planned times when the invite moved, and its series once it has
    /// one (a second meeting made one, or the calendar says it repeats), from then on as a series point. Returns
    /// whether anything changed. A move of the times is not the owner's change; joining a series is a change of list.
    @discardableResult
    public mutating func followMeetings(upcoming: [UpcomingMeeting], series all: [MeetingSeries], records: [CallRecord], at date: Date = Date()) -> Bool {
        var changed = false
        for i in points.indices where points[i].isOpen && points[i].isForMeeting {
            guard var m = points[i].meeting else { continue }
            let invite = upcoming.first { m.matches($0) }
            let recorded = records.filter { $0.status == .written && m.matches($0) }
            if let s = invite.flatMap({ SeriesCatalog.series(of: $0, in: all) }) ?? recorded.lazy.compactMap({ SeriesCatalog.series(ofCall: $0.id, in: all) }).first {
                move(points[i].id, to: s, at: date)
                changed = true
            } else if let u = invite, u.start != m.start || u.end != m.end || u.title != m.title {
                m.start = u.start
                m.end = u.end
                m.title = u.title
                points[i].meeting = m
                changed = true
            }
        }
        return changed
    }
}

extension NextTimeRules {
    /// The one other person of a 1:1: everyone invited other than the owner is one entry, and that entry is surely one
    /// saved person (`NextTimeInvite`). Nil for a group, a room, or a person who is not surely saved.
    public static func onlyOther(_ r: CallRecord, owner: String, directory: PersonDirectory, ownerEmails: [String] = [],
                                 people refs: PersonReferences) -> (id: String, name: String)? {
        guard MeetingPrep.invited(r.attendees, owner: owner, directory: directory, ownerEmails: ownerEmails).count == 1 else { return nil }
        let ids = NextTimeInvite.personIDs(r.attendees, people: refs)
        guard ids.count == 1, let name = refs.name(of: ids[0]) else { return nil }
        return (ids[0], name)
    }
}
