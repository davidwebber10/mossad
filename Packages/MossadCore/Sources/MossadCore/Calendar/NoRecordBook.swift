import Foundation

/// What the owner chose for an upcoming meeting.
public enum RecordingChoice: String, CaseIterable, Sendable {
    case record, skipThisMeeting, skipSeries
}

/// The upcoming meetings the owner does not want recorded, saved so the choice survives a restart.
/// A meeting is its title and call link; a series is every meeting that shares both.
public struct NoRecordBook: Codable, Equatable, Sendable {
    public static let fileName = "no-record.json"
    /// How early someone can join and still be in the meeting; the same half hour the invite match looks ahead.
    static let earlyJoin: TimeInterval = 1800

    struct Rule: Codable, Equatable, Sendable {
        var key: String
        /// Nil for a whole series.
        var start: Date?
        var end: Date?

        func covers(_ time: Date) -> Bool { start.map { abs($0.timeIntervalSince(time)) < 1 } ?? true }
    }

    var rules: [Rule] = []

    public init() {}

    static func key(title: String, link: URL?) -> String? {
        guard let link, let host = link.host else { return nil }
        // The query can change between invites (a Zoom passcode); the path is the meeting.
        return "\(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(host.lowercased())\(link.path.lowercased())"
    }

    public func choice(for meeting: UpcomingMeeting) -> RecordingChoice {
        guard let key = Self.key(title: meeting.title, link: meeting.link) else { return .record }
        if rules.contains(where: { $0.key == key && $0.start == nil }) { return .skipSeries }
        return rules.contains { $0.key == key && $0.covers(meeting.start) } ? .skipThisMeeting : .record
    }

    public mutating func set(_ choice: RecordingChoice, for meeting: UpcomingMeeting) {
        guard let key = Self.key(title: meeting.title, link: meeting.link) else { return }
        rules.removeAll { $0.key == key && $0.covers(meeting.start) }
        switch choice {
        case .record: break
        case .skipThisMeeting: rules.append(Rule(key: key, start: meeting.start, end: meeting.end))
        case .skipSeries: rules.append(Rule(key: key))
        }
    }

    public mutating func removeExpired(now: Date) {
        rules.removeAll { $0.end.map { $0 < now } ?? false }
    }

    /// Whether a call that just started is a meeting the owner does not want recorded. It finds the invite the
    /// same way the call's title does, so a call with no matching invite records as usual.
    public func blocks(platform: Platform, meetingID: String?, at time: Date, events: [CalendarEventInfo]) -> Bool {
        blockingInvite(platform: platform, meetingID: meetingID, at: time, events: events) != nil
    }

    /// The invite of a call that starts now, and its key; nil for a call with no invite.
    static func invite(platform: Platform, meetingID: String?, at time: Date, events: [CalendarEventInfo]) -> (event: CalendarEventInfo, key: String)? {
        guard let event = CalendarMatcher.bestEvent(for: platform, meetingID: meetingID, start: time,
                                                    end: time.addingTimeInterval(Self.earlyJoin), in: events),
              time >= event.start.addingTimeInterval(-Self.earlyJoin), time < event.end,
              let key = Self.key(title: event.title, link: UpcomingMeeting.callLink(in: event.text).1) else { return nil }
        return (event, key)
    }

    func blockingInvite(platform: Platform, meetingID: String?, at time: Date, events: [CalendarEventInfo]) -> (event: CalendarEventInfo, key: String)? {
        guard let invite = Self.invite(platform: platform, meetingID: meetingID, at: time, events: events),
              rules.contains(where: { $0.key == invite.key && $0.covers(invite.event.start) }) else { return nil }
        return invite
    }

    public static func load(from dir: URL) -> NoRecordBook {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return NoRecordBook() }
        return (try? JSONDecoder.callRecord.decode(NoRecordBook.self, from: data)) ?? NoRecordBook()
    }

    public func save(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.callRecord.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// The book and the calendar for the detection queue, which cannot wait for the main actor before a call starts.
/// It also remembers a blocked call for its whole session: a meeting that runs past its planned end, or a call that
/// detection starts again (a mic gap, Off then On, a restart), stays off the record.
public final class NoRecordGate: @unchecked Sendable {
    public static let sessionFileName = "no-record-session.json"
    /// A call that starts again in the same app within this time after the blocked call was last seen is the same
    /// meeting, unless the calendar shows a different meeting that begins after the blocked one's planned end.
    static let sameMeetingGap: TimeInterval = 600
    /// The same meeting code, after a blocked call with no end seen, is the same meeting for this long.
    static let sameCodeGap: TimeInterval = 4 * 3600
    /// How often the blocked call's "last seen" time is saved while it goes on, so a restart finds it.
    static let saveEvery: TimeInterval = 60

    struct BlockedCall: Codable, Equatable {
        var bundleID: String
        var meetingID: String?
        var key: String
        var plannedEnd: Date
        var lastSeen: Date
        var ended: Bool
    }

    private let lock = NSCondition()
    private var book = NoRecordBook()
    private var events: [CalendarEventInfo] = []
    private var calendarRead = false
    private var gaveUp = false
    private var session: BlockedCall?
    private var sessionFile: URL?
    private var lastSaved = Date.distantPast

    public init() {}

    /// Keeps the blocked call in a file in this folder, and reads the one a previous run left.
    public func persistSession(in dir: URL) {
        let file = dir.appendingPathComponent(Self.sessionFileName)
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder.callRecord.decode(BlockedCall.self, from: $0) }
        lock.withLock {
            sessionFile = file
            if session == nil { session = saved }
        }
    }

    public func update(book: NoRecordBook) { lock.withLock { self.book = book } }

    public func update(events: [CalendarEventInfo]) {
        lock.withLock {
            self.events = events
            calendarRead = true
            lock.broadcast()
        }
    }

    /// Waits, at most `timeout`, for the first calendar read: at launch the events come a moment after detection
    /// starts, and a call checked against an empty calendar records a meeting the owner marked.
    public func waitForCalendar(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        while !calendarRead, !gaveUp, lock.wait(until: deadline) {}
        // A calendar that never answers delays the first call only.
        if !calendarRead { gaveUp = true }
        lock.unlock()
    }

    public func blocks(platform: Platform, meetingID: String?, at time: Date) -> Bool {
        let (book, events) = lock.withLock { (book, events) }
        return book.blocks(platform: platform, meetingID: meetingID, at: time, events: events)
    }

    /// Whether a call that starts now stays off the record. A block is remembered for the call session.
    public func blocksStart(platform: Platform, bundleID: String, meetingID: String?, at time: Date) -> Bool {
        lock.withLock {
            if var s = session, holds(s, bundleID: bundleID, platform: platform, meetingID: meetingID, at: time) {
                s.lastSeen = time
                s.ended = false
                save(s, at: time)
                return true
            }
            if let invite = book.blockingInvite(platform: platform, meetingID: meetingID, at: time, events: events) {
                save(BlockedCall(bundleID: bundleID, meetingID: meetingID, key: invite.key, plannedEnd: invite.event.end,
                                 lastSeen: time, ended: false), at: time)
                return true
            }
            // A call that records means the blocked one is over.
            if var s = session, !s.ended {
                s.ended = true
                save(s, at: time)
            }
            return false
        }
    }

    /// The current call is still going: called on each tick during a call.
    public func seen(at time: Date) {
        lock.withLock {
            guard var s = session, !s.ended else { return }
            s.lastSeen = time
            session = s
            if time.timeIntervalSince(lastSaved) >= Self.saveEvery { save(s, at: time) }
        }
    }

    /// A call ended. True when it was the blocked call, so there is nothing to stop or show.
    public func callEnded(at time: Date) -> Bool {
        lock.withLock {
            guard var s = session, !s.ended else { return false }
            s.ended = true
            s.lastSeen = time
            save(s, at: time)
            return true
        }
    }

    /// A blocked call is going on now: its mute changes must not reach the recorder or the menu.
    public var isBlockingCall: Bool { lock.withLock { session.map { !$0.ended } ?? false } }

    private func holds(_ s: BlockedCall, bundleID: String, platform: Platform, meetingID: String?, at time: Date) -> Bool {
        guard s.bundleID == bundleID else { return false }
        if let a = s.meetingID, let b = meetingID, a != b { return false }
        // The blocked call was never seen to end (Mossad was off, or it quit), and the same meeting code is back:
        // the same meeting, however long Mossad did not look.
        let sameCode = s.meetingID != nil && s.meetingID == meetingID && !s.ended
        guard time.timeIntervalSince(s.lastSeen) < (sameCode ? Self.sameCodeGap : Self.sameMeetingGap) else { return false }
        // After the blocked call ended, the next meeting on the calendar records as usual.
        if s.ended, let next = NoRecordBook.invite(platform: platform, meetingID: meetingID, at: time, events: events),
           next.key != s.key, next.event.start >= s.plannedEnd {
            return false
        }
        return true
    }

    /// Runs inside the lock.
    private func save(_ s: BlockedCall, at time: Date) {
        session = s
        lastSaved = time
        guard let sessionFile else { return }
        do {
            try FileManager.default.createDirectory(at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.callRecord.encode(s).write(to: sessionFile, options: .atomic)
        } catch {
            Log.error("Saving the blocked call failed: \(error)")
        }
    }
}
