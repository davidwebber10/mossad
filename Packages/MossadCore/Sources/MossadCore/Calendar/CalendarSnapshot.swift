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
        "participant": ["name", "email", "isSelf", "personID", "response", "kind"],
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
            // The link without its query and fragment: a Zoom link keeps its passcode there. The platform and the
            // meeting's id are in the host and the path.
            link = e.callLink.url.flatMap { url in
                var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
                c?.query = nil
                c?.fragment = nil
                return c?.url?.absoluteString
            }
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

    public struct Access: Codable, Equatable, Sendable {
        public enum Read: String, Codable, Sendable { case yes, no, failed }
        public var mac: Read
        public var google: Read
        public init(mac: Read, google: Read) {
            self.mac = mac
            self.google = google
        }
    }

    public var access: Access?
    public var version = CalendarSnapshot.currentVersion
    /// When the app read the calendar.
    public var saved: Date
    public var events: [Event]

    public init(_ events: [CalendarEventInfo], saved: Date, access: Access? = nil) {
        self.saved = saved
        self.access = access
        // Only what the lists (`UpcomingMeeting.from`) and the series' two names (`SeriesCatalog.aliases`) can use.
        self.events = events.filter(Self.isUseful).map(Event.init)
    }

    static func isUseful(_ e: CalendarEventInfo) -> Bool {
        let listed = !e.isAllDay && !e.declinedByOwner && e.callLink.platform != nil
        let alias = e.source == .google && e.seriesID != nil && e.iCalUID?.nonBlank != nil
        return listed || alias
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
        let url = dir.appendingPathComponent(Self.fileName)
        try JSONEncoder.callRecord.encode(self).write(to: url, options: .atomic)
        // The owner's alone, as their calendar is: no other account of this Mac reads 45 days of invites.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
