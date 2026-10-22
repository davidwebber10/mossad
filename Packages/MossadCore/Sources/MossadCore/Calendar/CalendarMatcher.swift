import EventKit
import Foundation

public struct CalendarEventInfo: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var attendees: [String]
    /// Location, notes, and URL together, for finding meeting links.
    public var text: String
    public var isAllDay: Bool

    public init(title: String, start: Date, end: Date, attendees: [String], text: String, isAllDay: Bool) {
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.text = text
        self.isAllDay = isAllDay
    }
}

/// One calendar on the Mac, for choosing which ones Mossad reads.
public struct CalendarInfo: Identifiable, Equatable, Sendable, Hashable {
    public var id: String
    public var title: String
    /// The account it belongs to, such as an email address.
    public var account: String

    public init(id: String, title: String, account: String) {
        self.id = id
        self.title = title
        self.account = account
    }

    /// The owner's own calendars: titled with their name, or the account's main calendar (titled with the
    /// account's own address). All of them when there is none, so matching never silently stops.
    public static func defaults(_ calendars: [CalendarInfo], ownerName: String) -> Set<String> {
        let own = calendars.filter {
            $0.title.caseInsensitiveCompare(ownerName) == .orderedSame
                || ($0.title.contains("@") && $0.title.caseInsensitiveCompare($0.account) == .orderedSame)
        }
        return Set((own.isEmpty ? calendars : own).map(\.id))
    }
}

public protocol CalendarSource: Sendable {
    func events(from: Date, to: Date) async -> [CalendarEventInfo]
}

public enum CalendarMatcher {
    static func linkMarkers(_ platform: Platform) -> [String] {
        switch platform {
        case .meet: ["meet.google.com"]
        case .zoom: ["zoom.us/j/", "zoom.us/my/"]
        case .teams: ["teams.microsoft.com", "teams.cloud.microsoft", "teams.live.com"]
        case .inPerson: []
        }
    }

    /// With a meeting ID, the nearby event whose link carries that ID. Without one (the Zoom and Teams apps),
    /// the overlapping event with this platform's link. An event that only shares the time is a different
    /// meeting, so it never matches.
    public static func bestEvent(for platform: Platform, meetingID: String?, start: Date, end: Date,
                                 in events: [CalendarEventInfo]) -> CalendarEventInfo? {
        func overlap(_ e: CalendarEventInfo) -> TimeInterval { min(end, e.end).timeIntervalSince(max(start, e.start)) }
        func text(_ e: CalendarEventInfo) -> String { (e.text.removingPercentEncoding ?? e.text).lowercased() }
        let timed = events.filter { !$0.isAllDay }
        if let meetingID {
            let id = meetingID.lowercased()
            return timed.filter { text($0).contains(id) }.max { overlap($0) < overlap($1) }
        }
        // In a room there is no link to match: the overlapping event without a call link is the meeting.
        if platform == .inPerson {
            let callMarkers = Platform.callApps.flatMap(linkMarkers)
            return timed.filter { e in overlap(e) > 0 && !callMarkers.contains { text(e).contains($0) } }.max { overlap($0) < overlap($1) }
        }
        let markers = linkMarkers(platform)
        return timed.filter { e in overlap(e) > 0 && markers.contains { text(e).contains($0) } }.max { overlap($0) < overlap($1) }
    }
}

/// An event store made before Calendar access was granted can stay blind after the grant
/// (the status says allowed, but it returns no events). This decides when to make a new one.
struct CalendarAccess {
    private var allowed: Bool

    init(allowedAtStart: Bool) { allowed = allowedAtStart }

    mutating func needsNewStore(allowed now: Bool) -> Bool {
        defer { allowed = now }
        return now && !allowed
    }
}

/// Reads events from the Mac's calendars.
public final class EventKitCalendarSource: CalendarSource, @unchecked Sendable {
    private let lock = NSLock()
    private var store = EKEventStore()
    private var access = CalendarAccess(allowedAtStart: EKEventStore.authorizationStatus(for: .event) == .fullAccess)

    public init() {}

    public func requestAccess() async -> Bool {
        (try? await currentStore().requestFullAccessToEvents()) ?? false
    }

    /// The store, replaced once when access was granted after it was made.
    private func currentStore() -> EKEventStore {
        let allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        return lock.withLock {
            if access.needsNewStore(allowed: allowed) { store = EKEventStore() }
            return store
        }
    }

    /// The calendars to read; nil reads every calendar.
    private var chosen: Set<String>?

    public func choose(_ ids: Set<String>?) {
        lock.withLock { chosen = ids }
    }

    public func calendars() -> [CalendarInfo] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        return currentStore().calendars(for: .event).map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "") }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    public func events(from: Date, to: Date) async -> [CalendarEventInfo] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let store = currentStore()
        let ids = lock.withLock { chosen }
        let calendars = ids.map { ids in store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) } }
        if calendars?.isEmpty == true { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        return store.events(matching: predicate).map { e in
            CalendarEventInfo(
                title: e.title ?? "Untitled",
                start: e.startDate,
                end: e.endDate,
                attendees: (e.attendees ?? []).compactMap { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") },
                text: [e.location, e.notes, e.url?.absoluteString].compactMap { $0 }.joined(separator: "\n"),
                isAllDay: e.isAllDay)
        }
    }
}
