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
        guard let event = CalendarMatcher.bestEvent(for: platform, meetingID: meetingID, start: time,
                                                    end: time.addingTimeInterval(Self.earlyJoin), in: events),
              time >= event.start.addingTimeInterval(-Self.earlyJoin), time < event.end,
              let key = Self.key(title: event.title, link: UpcomingMeeting.callLink(in: event.text).1) else { return false }
        return rules.contains { $0.key == key && $0.covers(event.start) }
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
public final class NoRecordGate: @unchecked Sendable {
    private let lock = NSLock()
    private var book = NoRecordBook()
    private var events: [CalendarEventInfo] = []

    public init() {}

    public func update(book: NoRecordBook) { lock.withLock { self.book = book } }
    public func update(events: [CalendarEventInfo]) { lock.withLock { self.events = events } }

    public func blocks(platform: Platform, meetingID: String?, at time: Date) -> Bool {
        let (book, events) = lock.withLock { (book, events) }
        return book.blocks(platform: platform, meetingID: meetingID, at: time, events: events)
    }
}
