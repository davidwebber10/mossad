import Foundation

/// The points for next time that go with a moved meeting: `points.json` beside `call/` in the copy, listed in the marker
/// by its size and hash only (`MoveMarker.points`). A point carries its words, when it was made, its order, its state in
/// that meeting, and this Mac's detail of the meeting; never an id of the first profile (the point's, a person's, or a
/// series'): the target gives each a new id and makes it a point of its own meeting.
public struct MovedPoints: Codable, Equatable, Sendable {
    public static let fileName = "points.json"
    public static let currentVersion = 1

    public struct Point: Codable, Equatable, Sendable {
        /// The point was done. `inThisCall`: in the moved meeting, with its moment and quote; else by hand, or in a
        /// meeting that stays in the first profile, which the target does not have: no moment, no quote.
        public struct Done: Codable, Equatable, Sendable {
            public var inThisCall: Bool
            public var at: TimeInterval?
            public var quote: String?
            public var date: Date
            public var byOwner: Bool

            public init(inThisCall: Bool, at: TimeInterval?, quote: String?, date: Date, byOwner: Bool) {
                self.inThisCall = inThisCall
                self.at = at
                self.quote = quote
                self.date = date
                self.byOwner = byOwner
            }
        }

        /// The meeting's title, planned times, and the hash of its invite's UID. Not its people: their ids are this
        /// profile's.
        public struct Meeting: Codable, Equatable, Sendable {
            public var title: String
            public var start: Date
            public var end: Date
            public var event: String?

            public init(title: String, start: Date, end: Date, event: String?) {
                self.title = title
                self.start = start
                self.end = end
                self.event = event
            }
        }

        public var text: String
        public var created: Date
        public var rank: Double
        public var done: Done?
        /// The owner took back a "discussed" of this meeting: the target's check never finds it there again.
        public var reopened: Bool?
        public var meeting: Meeting?

        public init(text: String, created: Date, rank: Double, done: Done? = nil, reopened: Bool? = nil, meeting: Meeting? = nil) {
            self.text = text
            self.created = created
            self.rank = rank
            self.done = done
            self.reopened = reopened
            self.meeting = meeting
        }
    }

    public var version = MovedPoints.currentVersion
    /// The first profile's check read the meeting already: the target does not check it again.
    public var checked: Bool
    public var points: [Point]

    public init(checked: Bool, points: [Point]) {
        self.checked = checked
        self.points = points
    }

    /// Nil: no file, a file that does not decode, or one of a newer build.
    public static func read(_ url: URL) -> MovedPoints? {
        guard let data = try? Data(contentsOf: url),
              let v = try? JSONDecoder.move.decode(Versioned.self, from: data), v.version <= currentVersion else { return nil }
        return try? JSONDecoder.move.decode(MovedPoints.self, from: data)
    }

    private struct Versioned: Decodable { var version: Int }

    /// The points as the target's own points of its meeting `callID`, with the ids decided once in its marker.
    func taken(as callID: String, ids: [UUID], at date: Date) -> [NextTimePoint] {
        zip(points, ids).map { m, id in
            var p = NextTimePoint(text: m.text, rank: m.rank, created: m.created)
            p.id = id
            let detail = m.meeting.map { MeetingDetail(title: $0.title, start: $0.start, end: $0.end, event: $0.event) }
            p.meeting = NextTimeMeeting(detail, calls: [callID])
            p.done = m.done.map { d in
                NextTimePoint.Discussed(callID: d.inThisCall ? callID : nil, at: d.at, quote: d.quote, date: d.date, byOwner: d.byOwner)
            }
            if m.reopened == true { p.reopened = [callID] }
            p.updated = date
            return p
        }
    }
}

extension NextTimeBook {
    /// Whether a point goes with the meeting `callID` when it moves to another profile: a point of that one meeting
    /// (by its recordings, or by `record`'s invite only when that invite is sure: a call marked during the call was
    /// never checked, and a guess may be another meeting's slot), a point that the check moved from that meeting to the
    /// person of a 1:1 ("Not raised": the check adds the call to both `meeting.calls` and `carried` as it gives the
    /// point to the person), and a point of the meeting that the owner moved by hand to a person in `gone` (the people
    /// who go with the meeting). A series point, a point the owner made for a person, and one the owner moved by hand
    /// to a person who stays, stay.
    public static func goesWithMove(_ p: NextTimePoint, callID: String, record: CallRecord?, gone: Set<String> = []) -> Bool {
        guard !p.deleted, let m = p.meeting else { return false }
        let found = m.calls?.contains(callID) == true
        let own = ownMeeting(m, callID: callID, record: record)
        if p.isForMeeting { return own }
        guard p.isForPerson else { return false }
        return (found && p.carried?.contains(callID) == true) || (own && p.personID.map(gone.contains) == true)
    }

    /// The point's meeting is the call: by its recordings, or by the record's invite when that invite is sure.
    static func ownMeeting(_ m: NextTimeMeeting, callID: String, record: CallRecord?) -> Bool {
        if m.calls?.contains(callID) == true { return true }
        guard let record, record.inviteNotSure != true else { return false }
        return m.matches(record)
    }

    /// The points that go with the meeting, in their order.
    public func going(callID: String, record: CallRecord?, gone: Set<String> = []) -> [NextTimePoint] {
        visible.filter { Self.goesWithMove($0, callID: callID, record: record, gone: gone) }.sorted { ($0.rank, $0.created) < ($1.rank, $1.created) }
    }

    /// The points that go with the meeting, in their order; nil when none does (then no file goes).
    public func moved(callID: String, record: CallRecord?, gone: Set<String> = []) -> MovedPoints? {
        let going = going(callID: callID, record: record, gone: gone)
        guard !going.isEmpty else { return nil }
        return MovedPoints(checked: checked.contains(callID), points: going.map { p in
            // A point the owner moved to a person who goes arrives as an open point of the meeting, as one the check moved.
            let done = p.isForMeeting || p.carried?.contains(callID) == true ? p.done : nil
            let moved = done.map { d -> MovedPoints.Point.Done in
                let here = d.callID == callID
                return .init(inThisCall: here, at: here ? d.at : nil, quote: here ? d.quote : nil, date: d.date, byOwner: d.byOwner)
            }
            return MovedPoints.Point(text: p.text, created: p.created, rank: p.rank, done: moved,
                                     reopened: p.reopened?.contains(callID) == true ? true : nil,
                                     meeting: p.meeting?.detail.map { .init(title: $0.title, start: $0.start, end: $0.end, event: $0.event) })
        })
    }

    /// Adds the moved points as points of `callID` here. A point whose id is here already is not added again, so a run
    /// after a stop adds nothing twice. True when anything changed.
    @discardableResult
    public mutating func takeIn(_ moved: MovedPoints, as callID: String, ids: [UUID], at date: Date) -> Bool {
        var changed = false
        let have = Set(points.map(\.id))
        for p in moved.taken(as: callID, ids: ids, at: date) where !have.contains(p.id) {
            points.append(p)
            changed = true
        }
        if moved.checked, checked.insert(callID).inserted { changed = true }
        return changed
    }
}
