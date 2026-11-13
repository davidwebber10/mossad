import Foundation

/// Calendar API v3, read-only: events.list on the primary calendar. Pure: the address of a request and the
/// reading of an answer.
public enum GoogleCalendarAPI {
    public struct Page: Equatable, Sendable {
        /// The primary calendar's name, which is the account's address.
        public var account: String?
        public var events: [CalendarEventInfo]
        /// Every invite id of the answer.
        public var allUIDs: Set<String>
        public var nextPageToken: String?
        /// False when the read stopped at its page limit with more to come: the list is short.
        public var complete = true

        public init(account: String?, events: [CalendarEventInfo], allUIDs: Set<String>, nextPageToken: String?, complete: Bool = true) {
            self.account = account
            self.events = events
            self.allUIDs = allUIDs
            self.nextPageToken = nextPageToken
            self.complete = complete
        }
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
            // Meetings only: no working location, out of office, focus time, or birthday.
            URLQueryItem(name: "eventTypes", value: "default"),
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
    /// The directory's name for an address (`GoogleDirectoryCache.names`), for an invitee given only as an address.
    private let names: @Sendable () -> [String: String]
    /// At most this many pages of 250 events for one read.
    static let maxPages = 8

    public init(session: GoogleSession, names: @escaping @Sendable () -> [String: String] = { [:] }) {
        self.session = session
        self.names = names
    }

    /// Connected with Calendar on: a read is worth trying.
    public var isOn: Bool { session.has(.calendar) }

    public func page(from: Date, to: Date) async -> GoogleCalendarAPI.Page? {
        guard session.has(.calendar) else { return nil }
        var all = GoogleCalendarAPI.Page(account: nil, events: [], allUIDs: [], nextPageToken: nil)
        var token: String?
        for page in 0..<Self.maxPages {
            do {
                let p = try GoogleCalendarAPI.page(try await session.get(GoogleCalendarAPI.eventsURL(from: from, to: to, pageToken: token), scope: .calendar))
                all.account = all.account ?? p.account
                all.events += p.events
                all.allUIDs.formUnion(p.allUIDs)
                token = p.nextPageToken
                if token == nil { break }
                if page == Self.maxPages - 1 {
                    all.complete = false
                    Log.error("Google Calendar: the read stopped at \(Self.maxPages) pages")
                }
            } catch {
                Log.error("Google Calendar: the read failed (\(GoogleError.from(error).logText))")
                return nil
            }
        }
        if let account = all.account { await session.setAccount(account) }
        let known = names()
        if !known.isEmpty {
            all.events = all.events.map { e in
                var e = e
                e.participants = DirectoryMerge.fillNames(e.participants, names: known)
                e.organizer = e.organizer.map { DirectoryMerge.fillNames([$0], names: known)[0] }
                e.attendees = e.participants.map { $0.name ?? $0.email ?? "" }
                return e
            }
        }
        return all
    }
}

/// The calendar that the app and the pipeline read: Google's events where Google has them and the Mac's for every
/// other calendar, each meeting once.
public final class MergedCalendarSource: CalendarSource, @unchecked Sendable {
    private let mac: CalendarSource
    private let google: @Sendable () -> GoogleCalendarSource?
    private let lock = NSLock()
    /// The last Google read, so the 2 s checks and the pipeline do not each ask Google.
    private var cache: (from: Date, to: Date, at: Date, page: GoogleCalendarAPI.Page)?
    /// When the last read failed: the next ones use the Mac alone for a while instead of waiting for the network.
    private var failedAt: Date?
    /// The reads that run now, each with its window, shared by the callers whose window it covers.
    private var inFlight: [(id: UUID, from: Date, to: Date, task: Task<GoogleCalendarAPI.Page?, Never>)] = []
    /// Raised by `forget`: a read that started before does not write the cache.
    private var generation = 0
    static let cacheSeconds: TimeInterval = 120
    static let failedSeconds: TimeInterval = 60
    /// A read waits at most this long for Google; a later answer goes to the cache for the next read. The Mac's
    /// calendars answer at once, and the do-not-record gate waits only 3 s at launch.
    let waitLimit: Duration

    public init(mac: CalendarSource, google: @escaping @Sendable () -> GoogleCalendarSource?, waitLimit: Duration = .seconds(2)) {
        self.mac = mac
        self.google = google
        self.waitLimit = waitLimit
    }

    public func forget() { lock.withLock { cache = nil; failedAt = nil; inFlight = []; generation += 1 } }

    public func events(from: Date, to: Date) async -> [CalendarEventInfo] {
        let local = await mac.events(from: from, to: to)
        let on = google()?.isOn == true
        let page = await googlePage(from: from, to: to)
        lock.withLock { googleRead = !on ? .no : page == nil ? .failed : .yes }
        return CalendarMerge.merge(mac: local, google: page)
    }

    /// How the last read of Google went: not connected, read, or failed (the Mac's calendar alone then).
    public var lastGoogleRead: CalendarSnapshot.Access.Read { lock.withLock { googleRead } }
    private var googleRead: CalendarSnapshot.Access.Read = .no

    private func googlePage(from: Date, to: Date) async -> GoogleCalendarAPI.Page? {
        // Not connected is not a failure: nothing to wait for and nothing to mark.
        guard let google = google(), google.isOn else { return nil }
        let now = Date()
        let (cached, failed) = lock.withLock { (cache, failedAt) }
        if let c = cached, c.from <= from, c.to >= to, now.timeIntervalSince(c.at) < Self.cacheSeconds {
            return GoogleCalendarAPI.Page(account: c.page.account, events: c.page.events.filter { $0.end > from && $0.start < to },
                                          allUIDs: c.page.allUIDs, nextPageToken: nil, complete: c.page.complete)
        }
        if let failed, now.timeIntervalSince(failed) < Self.failedSeconds { return nil }
        // A read in flight joins a caller whose window it covers; another window gets its own read. The page is cut
        // to each caller's window.
        let read: Task<GoogleCalendarAPI.Page?, Never> = lock.withLock {
            if let running = inFlight.first(where: { $0.from <= from && $0.to >= to }) { return running.task }
            let started = generation
            let id = UUID()
            let task = Task { [weak self] () -> GoogleCalendarAPI.Page? in
                let page = await google.page(from: from, to: to)
                self?.lock.withLock {
                    self?.inFlight.removeAll { $0.id == id }
                    // A read that `forget` overtook (a new sign-in, other calendars) leaves the cache alone.
                    guard self?.generation == started else { return }
                    if let page { self?.cache = (from, to, now, page); self?.failedAt = nil } else { self?.failedAt = now }
                }
                return page
            }
            inFlight.append((id, from, to, task))
            return task
        }
        // The first of the read and the timer answers; the read goes on in the background and fills the cache.
        let limit = waitLimit
        let once = Once<GoogleCalendarAPI.Page?>()
        return await withCheckedContinuation { c in
            once.set(c)
            Task {
                let page = await read.value
                once.resume(page.map { p in
                    GoogleCalendarAPI.Page(account: p.account, events: p.events.filter { $0.end > from && $0.start < to },
                                           allUIDs: p.allUIDs, nextPageToken: nil, complete: p.complete)
                })
            }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(nil)
            }
        }
    }
}

/// A continuation that the first of several tasks resumes, one time only.
final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var early: T??

    func set(_ c: CheckedContinuation<T, Never>) {
        let value: T?? = lock.withLock {
            if let early { return early }
            continuation = c
            return nil
        }
        if let value { c.resume(returning: value!) }
    }

    func resume(_ value: T) {
        let c: CheckedContinuation<T, Never>? = lock.withLock {
            if let c = continuation {
                continuation = nil
                early = .some(value)
                return c
            }
            if early == nil { early = .some(value) }
            return nil
        }
        c?.resume(returning: value)
    }
}

/// How the two calendars join. Pure.
public enum CalendarMerge {
    /// With no Google read (`google` nil: not connected, the read failed, or it was slow) the Mac's events stay as
    /// they are: unknown is not "no events". With one, each Google event wins over the Mac's copy of the same invite
    /// (the same iCalUID at the same start); every other Mac event stays, from any calendar. A declined meeting
    /// stays in the list, so a call still finds its invite; the lists and the import leave it out.
    public static func merge(mac: [CalendarEventInfo], google: GoogleCalendarAPI.Page?) -> [CalendarEventInfo] {
        guard let google else { return mac }
        var starts: [String: [Date]] = [:]
        for e in google.events { if let uid = e.iCalUID { starts[uid, default: []].append(e.start) } }
        let kept = mac.filter { e in
            guard let uid = e.iCalUID else { return true }
            return !(starts[uid] ?? []).contains { abs($0.timeIntervalSince(e.start)) < 60 }
        }
        return (google.events + kept).sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }
}
