import Foundation

/// Calendar API v3, read-only: events.list on the primary calendar. Pure: the address of a request and the
/// reading of an answer.
public enum GoogleCalendarAPI {
    public struct Page: Equatable, Sendable {
        /// The primary calendar's name, which is the account's address.
        public var account: String?
        public var events: [CalendarEventInfo]
        /// Every invite id of the answer, the declined ones too, so the Mac's copy of a declined event goes as well.
        public var allUIDs: Set<String>
        public var nextPageToken: String?
    }

    /// Repeated events come as single instances in time order.
    public static func eventsURL(from: Date, to: Date, max: Int = 250, pageToken: String? = nil) -> URL {
        var c = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        let iso = ISO8601DateFormatter()
        c.queryItems = [
            URLQueryItem(name: "timeMin", value: iso.string(from: from)),
            URLQueryItem(name: "timeMax", value: iso.string(from: to)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: String(max)),
        ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
        return c.url!
    }

    private struct Answer: Decodable {
        var summary: String?
        var nextPageToken: String?
        var items: [Event]?
    }

    struct When: Decodable {
        var dateTime: String?
        var date: String?
    }

    struct Person: Decodable {
        var email: String?
        var displayName: String?
        var responseStatus: String?
        var isSelf: Bool?
        var organizer: Bool?
        var resource: Bool?

        enum CodingKeys: String, CodingKey {
            case email, displayName, responseStatus, organizer, resource
            case isSelf = "self"
        }
    }

    struct Event: Decodable {
        struct Conference: Decodable {
            struct Entry: Decodable {
                var entryPointType: String?
                var uri: String?
            }

            var entryPoints: [Entry]?
        }

        struct Attachment: Decodable {
            var fileId: String?
            var fileUrl: String?
            var title: String?
            var mimeType: String?
        }

        var id: String?
        var iCalUID: String?
        var status: String?
        var summary: String?
        var description: String?
        var location: String?
        var start: When?
        var end: When?
        var attendees: [Person]?
        var organizer: Person?
        var recurringEventId: String?
        var hangoutLink: String?
        var conferenceData: Conference?
        var attachments: [Attachment]?
    }

    public static func page(_ data: Data) throws -> Page {
        guard let a = try? JSONDecoder().decode(Answer.self, from: data) else { throw GoogleError.unexpectedAnswer }
        let live = (a.items ?? []).filter { $0.status != "cancelled" }
        return Page(account: a.summary?.contains("@") == true ? a.summary?.lowercased() : nil,
                    events: live.compactMap { event($0, account: a.summary?.lowercased()) },
                    allUIDs: Set(live.compactMap(\.iCalUID)), nextPageToken: a.nextPageToken)
    }

    static func date(_ w: When?) -> (Date, allDay: Bool)? {
        guard let w else { return nil }
        if let text = w.dateTime {
            let f = ISO8601DateFormatter()
            if let d = f.date(from: text) { return (d, false) }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: text).map { ($0, false) }
        }
        if let text = w.date {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.date(from: text).map { ($0, true) }
        }
        return nil
    }

    static func invitee(_ p: Person) -> Invitee? {
        let email = p.email?.trimmingCharacters(in: .whitespaces).lowercased().nonBlank
        let name = p.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nonBlank
        guard email != nil || name != nil else { return nil }
        return Invitee(name: name, email: email, isSelf: p.isSelf == true ? true : nil, response: p.responseStatus)
    }

    static func event(_ e: Event, account: String?) -> CalendarEventInfo? {
        guard let (start, allDay) = date(e.start), let (end, _) = date(e.end) else { return nil }
        // A room is a resource, not a person.
        let people = (e.attendees ?? []).filter { $0.resource != true }.compactMap(invitee)
        let video = e.conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri ?? e.hangoutLink
        let link = video.flatMap(URL.init(string:))
        var info = CalendarEventInfo(
            title: e.summary?.nonBlank ?? "Untitled", start: start, end: end,
            attendees: people.map { $0.name ?? $0.email ?? "" },
            // The link goes into the text too, so the rules that read links in the text find it.
            text: [e.location, e.description, video].compactMap { $0?.nonBlank }.joined(separator: "\n"),
            isAllDay: allDay, participants: people)
        info.source = .google
        info.iCalUID = e.iCalUID
        info.eventID = e.id
        info.seriesID = e.recurringEventId
        info.organizer = e.organizer.flatMap(invitee)
        info.meetingLink = link
        info.calendarAccount = account
        info.attachments = (e.attachments ?? []).map {
            EventAttachment(fileID: $0.fileId, title: $0.title ?? "", mimeType: $0.mimeType, url: $0.fileUrl.flatMap(URL.init(string:)))
        }
        return info
    }
}

/// Reads the owner's primary Google calendar. Nil when Google is not connected or the read failed: then the Mac's
/// calendars alone are the truth, as before.
public final class GoogleCalendarSource: Sendable {
    private let session: GoogleSession
    /// At most this many pages of 250 events for one read.
    static let maxPages = 8

    public init(session: GoogleSession) { self.session = session }

    public func page(from: Date, to: Date) async -> GoogleCalendarAPI.Page? {
        guard session.has(.calendar) else { return nil }
        var all = GoogleCalendarAPI.Page(account: nil, events: [], allUIDs: [], nextPageToken: nil)
        var token: String?
        for _ in 0..<Self.maxPages {
            do {
                let p = try GoogleCalendarAPI.page(try await session.get(GoogleCalendarAPI.eventsURL(from: from, to: to, pageToken: token), scope: .calendar))
                all.account = all.account ?? p.account
                all.events += p.events
                all.allUIDs.formUnion(p.allUIDs)
                token = p.nextPageToken
                if token == nil { break }
            } catch {
                Log.error("Google Calendar: the read failed (\(GoogleError.from(error).logText))")
                return nil
            }
        }
        if let account = all.account { await session.setAccount(account) }
        return all
    }
}

/// The calendar that the app and the pipeline read: Google's events for the Google calendar and the Mac's for
/// every other account, each meeting once.
public final class MergedCalendarSource: CalendarSource, @unchecked Sendable {
    private let mac: CalendarSource
    private let google: @Sendable () -> GoogleCalendarSource?
    private let lock = NSLock()
    /// The last Google read, so the 2 s checks and the pipeline do not each ask Google.
    private var cache: (from: Date, to: Date, at: Date, page: GoogleCalendarAPI.Page)?
    static let cacheSeconds: TimeInterval = 120

    public init(mac: CalendarSource, google: @escaping @Sendable () -> GoogleCalendarSource?) {
        self.mac = mac
        self.google = google
    }

    public func forget() { lock.withLock { cache = nil } }

    public func events(from: Date, to: Date) async -> [CalendarEventInfo] {
        let local = await mac.events(from: from, to: to)
        return CalendarMerge.merge(mac: local, google: await googlePage(from: from, to: to))
    }

    private func googlePage(from: Date, to: Date) async -> GoogleCalendarAPI.Page? {
        guard let google = google() else { return nil }
        let now = Date()
        if let c = lock.withLock({ cache }), c.from <= from, c.to >= to, now.timeIntervalSince(c.at) < Self.cacheSeconds {
            return GoogleCalendarAPI.Page(account: c.page.account, events: c.page.events.filter { $0.end > from && $0.start < to },
                                          allUIDs: c.page.allUIDs, nextPageToken: nil)
        }
        guard let page = await google.page(from: from, to: to) else { return nil }
        lock.withLock { cache = (from, to, now, page) }
        return page
    }
}

/// How the two calendars join. Pure.
public enum CalendarMerge {
    /// With no Google read (`google` nil: not connected, or the read failed) the Mac's events stay as they are:
    /// unknown is not "no events". With one, each Google event wins over the Mac's copy of the same invite (the same
    /// iCalUID at the same start), the Mac's events of the Google account itself go, and a meeting the owner declined
    /// is left out.
    public static func merge(mac: [CalendarEventInfo], google: GoogleCalendarAPI.Page?) -> [CalendarEventInfo] {
        guard let google else { return mac }
        let account = google.account?.lowercased()
        var starts: [String: [Date]] = [:]
        for e in google.events { if let uid = e.iCalUID { starts[uid, default: []].append(e.start) } }
        let kept = mac.filter { e in
            if let account, e.calendarAccount?.lowercased() == account { return false }
            guard let uid = e.iCalUID else { return true }
            // A declined event is in the answer's ids but not in its events: the Mac's copy goes too.
            if google.allUIDs.contains(uid), starts[uid] == nil { return false }
            return !(starts[uid] ?? []).contains { abs($0.timeIntervalSince(e.start)) < 60 }
        }
        let accepted = google.events.filter { !$0.declinedByOwner }
        return (accepted + kept).sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }
}
