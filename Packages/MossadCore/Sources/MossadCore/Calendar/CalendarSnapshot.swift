import Foundation

/// The calendar's events as the app last read them, kept on this Mac for the tools of other AI apps: `Mossad --mcp`
/// has no calendar permission of its own and never holds Google's tokens. Built from a list of allowed fields: the
/// title, the times, the invite list with each answer, the call link, and the series. Never the notes, the
/// attachments, the organizer's other details, or the calendar account. It never syncs.
public struct CalendarSnapshot: Codable, Equatable, Sendable {
    public static let fileName = "upcoming.json"
    public static let currentVersion = 1

    /// The keys each level may have. A test fails when the file has any other key.
    public static let allowedKeys: [String: Set<String>] = [
        "root": ["version", "saved", "events"],
        "event": ["title", "start", "end", "attendees", "participants", "link", "isAllDay", "source", "iCalUID", "seriesID", "isRecurring"],
    ]

    public struct Event: Codable, Equatable, Sendable {
        public var title: String
        public var start: Date
        public var end: Date
        public var attendees: [String]
        public var participants: [Invitee]
        /// The call link alone, never the rest of the event's text.
        public var link: String?
        public var isAllDay: Bool
        public var source: EventSource
        public var iCalUID: String?
        public var seriesID: String?
        public var isRecurring: Bool

        init(_ e: CalendarEventInfo) {
            title = e.title
            start = e.start
            end = e.end
            attendees = e.attendees
            participants = e.participants
            link = e.callLink.url?.absoluteString
            isAllDay = e.isAllDay
            source = e.source
            iCalUID = e.iCalUID
            seriesID = e.seriesID
            isRecurring = e.isRecurring
        }

        /// The event as the lists read it: the call link is its only text.
        var info: CalendarEventInfo {
            var e = CalendarEventInfo(title: title, start: start, end: end, attendees: attendees, text: link ?? "", isAllDay: isAllDay, participants: participants)
            e.source = source
            e.iCalUID = iCalUID
            e.seriesID = seriesID
            e.isRecurring = isRecurring
            return e
        }
    }

    public var version = CalendarSnapshot.currentVersion
    /// When the app read the calendar.
    public var saved: Date
    public var events: [Event]

    public init(_ events: [CalendarEventInfo], saved: Date) {
        self.saved = saved
        self.events = events.map(Event.init)
    }

    /// The events, for `UpcomingMeeting.from` and `SeriesCatalog.aliases`: the same rules as the app's lists.
    public var calendarEvents: [CalendarEventInfo] { events.map(\.info) }

    /// The copy on disk, or nil. A newer or damaged file is only not read.
    public static func load(from dir: URL) -> CalendarSnapshot? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)),
              let s = try? JSONDecoder.callRecord.decode(CalendarSnapshot.self, from: data), s.version <= currentVersion else { return nil }
        return s
    }

    public func save(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.callRecord.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
