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
    /// The file was there and did not decode. The rules are unknown, so every call that matches an invite is
    /// blocked (the owner's "do not record" wins over a recording) until the owner sets a choice or resets the list.
    /// The app says so at each blocked call; see `NoRecordGate.currentBlock`.
    public private(set) var unreadable = false

    private enum CodingKeys: String, CodingKey { case rules }

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

    /// A choice made now starts a list the app can read, so the block for the damaged one ends at once.
    public mutating func set(_ choice: RecordingChoice, for meeting: UpcomingMeeting) {
        unreadable = false
        guard let key = Self.key(title: meeting.title, link: meeting.link) else { return }
        rules.removeAll { $0.key == key && $0.covers(meeting.start) }
        switch choice {
        case .record: break
        case .skipThisMeeting: rules.append(Rule(key: key, start: meeting.start, end: meeting.end))
        case .skipSeries: rules.append(Rule(key: key))
        }
    }

    /// "Reset do-not-record list": an empty list that records every call again.
    public mutating func reset() {
        rules = []
        unreadable = false
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

    func blocks(_ invite: (event: CalendarEventInfo, key: String)) -> Bool {
        unreadable || blocksByChoice(invite)
    }

    func blocksByChoice(_ invite: (event: CalendarEventInfo, key: String)) -> Bool {
        rules.contains { $0.key == invite.key && $0.covers(invite.event.start) }
    }

    func blockingInvite(platform: Platform, meetingID: String?, at time: Date, events: [CalendarEventInfo]) -> (event: CalendarEventInfo, key: String)? {
        guard let invite = Self.invite(platform: platform, meetingID: meetingID, at: time, events: events),
              blocks(invite) else { return nil }
        return invite
    }

    /// Fails closed: a file that is there but cannot be read gives a book that blocks every call with an invite.
    /// The file is moved aside, so the book stays closed on later launches too, until the owner sets a choice
    /// again and a new file is saved.
    public static func load(from dir: URL) -> NoRecordBook {
        var book = NoRecordBook()
        do {
            book = try loadChecked(from: dir)
            let file = dir.appendingPathComponent(fileName)
            guard !FileManager.default.fileExists(atPath: file.path),
                  ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).contains(where: StoredFile.isQuarantined) else { return book }
        } catch {
            Log.error("The do-not-record list could not be read; calls with an invite are not recorded until it is set again: \(error)")
        }
        book.unreadable = true
        return book
    }

    /// Nil-free: a missing file is an empty book. A file that does not decode is moved aside and throws.
    public static func loadChecked(from dir: URL) throws -> NoRecordBook {
        try StoredFile.load(NoRecordBook.self, from: dir.appendingPathComponent(fileName), decoder: .callRecord) ?? NoRecordBook()
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
    /// The same meeting code that starts again within this time after the blocked call ended is the same meeting.
    static let sameMeetingGap: TimeInterval = 600
    /// An app with no meeting code stays blocked this long after the blocked meeting's planned end, for a meeting
    /// that runs late.
    static let noCodeGrace: TimeInterval = 900
    /// The same meeting code, after a blocked call with no end seen, is the same meeting for this long.
    static let sameCodeGap: TimeInterval = 4 * 3600
    /// How often the blocked call's "last seen" time is saved while it goes on, so a restart finds it.
    static let saveEvery: TimeInterval = 60

    struct BlockedCall: Codable, Equatable {
        var bundleID: String
        var meetingID: String?
        var key: String
        var plannedStart: Date
        var plannedEnd: Date
        var lastSeen: Date
        var ended: Bool
        /// The invite's title, for the notice of a call that was not recorded.
        var title: String?
        /// True when no choice of the owner blocked this call: the list could not be read.
        var listUnreadable: Bool?
    }

    /// The call that is kept off the record now.
    public struct Block: Equatable, Sendable {
        public var title: String
        /// The owner did not choose this: the do-not-record list could not be read. The app must say so.
        public var listUnreadable: Bool
    }

    /// The block of the call that is going on, or nil when that call records.
    public var currentBlock: Block? {
        lock.withLock {
            guard let s = session, !s.ended else { return nil }
            return Block(title: s.title ?? "", listUnreadable: s.listUnreadable == true)
        }
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
        var saved: BlockedCall?
        if let data = try? Data(contentsOf: file) {
            do { saved = try JSONDecoder.callRecord.decode(BlockedCall.self, from: data) } catch {
                Log.error("The saved no-record call could not be read, so it is not kept: \(error)")
            }
        }
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
        let late = !calendarRead && !gaveUp
        if !calendarRead { gaveUp = true }
        lock.unlock()
        if late { Log.error("The calendar did not answer in \(Int(timeout)) s; this call is checked without it") }
    }

    public func blocks(platform: Platform, meetingID: String?, at time: Date) -> Bool {
        let (book, events) = lock.withLock { (book, events) }
        return book.blocks(platform: platform, meetingID: meetingID, at: time, events: events)
    }

    /// Whether a call that starts now stays off the record. A block is remembered for the call session, but it
    /// never spreads: only a start of the same meeting renews it.
    /// - An invite that matches now decides by the book, whatever was blocked before.
    /// - With no invite now (the meeting runs late), the same meeting code stays blocked; an app with no meeting
    ///   code stays blocked until the planned end plus `noCodeGrace`, and no later.
    /// - `forced` is the owner's Record on a warning, which always records.
    public func blocksStart(platform: Platform, bundleID: String, meetingID: String?, at time: Date, forced: Bool = false) -> Bool {
        lock.withLock {
            if forced { return record(at: time) }
            guard let s = session, s.bundleID == bundleID else { return decide(nil, platform, bundleID, meetingID, time) }
            func isOwn(_ e: CalendarEventInfo) -> Bool {
                e.start == s.plannedStart && NoRecordBook.key(title: e.title, link: UpcomingMeeting.callLink(in: e.text).1) == s.key
            }
            if let a = s.meetingID, let b = meetingID {
                guard a == b else { return decide(nil, platform, bundleID, meetingID, time) }
                if let invite = NoRecordBook.invite(platform: platform, meetingID: meetingID, at: time, events: events) {
                    return decide(invite, platform, bundleID, meetingID, time)
                }
                // Past the planned end. An end that was not seen (Mossad was off) allows a longer gap.
                guard time.timeIntervalSince(s.lastSeen) < (s.ended ? Self.sameMeetingGap : Self.sameCodeGap) else { return record(at: time) }
                return hold(s, at: time)
            }
            // No meeting code. A later invite that fits now is a different meeting, also when it overlaps.
            if let other = NoRecordBook.invite(platform: platform, meetingID: meetingID, at: time, events: events.filter { !isOwn($0) }),
               other.event.start > s.plannedStart {
                return decide(other, platform, bundleID, meetingID, time)
            }
            if let invite = NoRecordBook.invite(platform: platform, meetingID: meetingID, at: time, events: events) {
                return decide(invite, platform, bundleID, meetingID, time)
            }
            guard time < s.plannedEnd.addingTimeInterval(Self.noCodeGrace) else { return record(at: time) }
            return hold(s, at: time)
        }
    }

    /// The book decides for the invite that fits now (found here when not given). Runs inside the lock.
    private func decide(_ given: (event: CalendarEventInfo, key: String)?, _ platform: Platform, _ bundleID: String,
                        _ meetingID: String?, _ time: Date) -> Bool {
        guard let invite = given ?? NoRecordBook.invite(platform: platform, meetingID: meetingID, at: time, events: events),
              book.blocks(invite) else { return record(at: time) }
        save(BlockedCall(bundleID: bundleID, meetingID: meetingID, key: invite.key, plannedStart: invite.event.start,
                         plannedEnd: invite.event.end, lastSeen: time, ended: false, title: invite.event.title,
                         listUnreadable: !book.blocksByChoice(invite)), at: time)
        return true
    }

    /// The same blocked meeting goes on. Runs inside the lock.
    private func hold(_ s: BlockedCall, at time: Date) -> Bool {
        // Blocked only because the list could not be read, and the owner has a list again: that block is over.
        if s.listUnreadable == true, !book.unreadable { return record(at: time) }
        var s = s
        s.lastSeen = time
        s.ended = false
        save(s, at: time)
        return true
    }

    /// This call records, so the blocked one is over. Runs inside the lock.
    private func record(at time: Date) -> Bool {
        if var s = session, !s.ended {
            s.ended = true
            save(s, at: time)
        }
        return false
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
