import EventKit
import Foundation

/// One invited person as the calendar gave them: the name, the address, or both.
public struct Invitee: Codable, Equatable, Sendable, Hashable {
    public var name: String?
    /// Lowercase.
    public var email: String?
    /// True for the calendar owner's own entry; nil when it is not.
    public var isSelf: Bool?
    /// The saved person this entry surely is, by the id in `people.json`. Nil when no saved person surely is.
    public var personID: String?
    /// Their answer to the invite as Google gives it: "accepted", "declined", "tentative", or "needsAction". Nil from
    /// a source that does not say.
    public var response: String?

    public init(name: String?, email: String?, isSelf: Bool? = nil, personID: String? = nil, response: String? = nil) {
        self.name = name
        self.email = email
        self.isSelf = isSelf
        self.personID = personID
        self.response = response
    }

    public var declined: Bool { response == "declined" }

    /// From what the calendar gives for a participant. `address` is its URL as text: "mailto:sam@example.com" for
    /// most accounts. An Exchange account can give a directory path there; that is not an address, so the email
    /// is unknown. Nil when neither a name nor an address is known.
    public static func make(name: String?, address: String?, isCurrentUser: Bool) -> Invitee? {
        var name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nonBlank
        var email: String?
        if let address, address.lowercased().hasPrefix("mailto:") {
            let rest = String(address.dropFirst("mailto:".count)).split(separator: "?").first.map(String.init) ?? ""
            email = isAddress(rest.removingPercentEncoding ?? rest)
        }
        // With no display name, the calendar gives the address as the name.
        if let written = name, let asAddress = isAddress(written) {
            email = email ?? asAddress
            name = nil
        }
        guard name != nil || email != nil else { return nil }
        return Invitee(name: name, email: email, isSelf: isCurrentUser ? true : nil)
    }

    /// The text when it is one address and nothing else, in lowercase.
    private static func isAddress(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !text.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "<" }) else { return nil }
        return text
    }

    /// The address the invite gave with each name, by the key of the name. A name with two addresses is left out.
    public static func emails(byName invitees: [Invitee]?) -> [String: String] {
        var out: [String: String?] = [:]
        for i in invitees ?? [] {
            guard let name = i.name, let email = i.email else { continue }
            let key = PersonNames.nameKey(name)
            guard !key.isEmpty else { continue }
            if let known = out[key] { if known != email { out[key] = .some(nil) } } else { out[key] = email }
        }
        return out.compactMapValues { $0 }
    }
}

public struct CalendarEventInfo: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    /// One text for each invited person: the name, or the address when there is no name.
    public var attendees: [String]
    /// The same people with the name and the address apart. Empty from a source that does not give them.
    public var participants: [Invitee]
    /// Location, notes, and URL together, for finding meeting links.
    public var text: String
    public var isAllDay: Bool
    /// Where the event was read. Google gives more: the series, the organizer, each answer, and the attachments.
    public var source: EventSource = .eventKit
    /// The invite's id across calendars: the same meeting in two calendars has one. Nil when the source hides it.
    public var iCalUID: String?
    /// The id of the event in its source (Google's event id).
    public var eventID: String?
    /// The id of the series a repeated event belongs to; nil for a single event or a source that does not say.
    public var seriesID: String?
    public var organizer: Invitee?
    /// The call link the invite names, when the source gives it apart from the text.
    public var meetingLink: URL?
    public var attachments: [EventAttachment] = []
    /// The account of the calendar, such as an email address, to tell a Google calendar on the Mac.
    public var calendarAccount: String?

    public init(title: String, start: Date, end: Date, attendees: [String], text: String, isAllDay: Bool, participants: [Invitee] = []) {
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.participants = participants
        self.text = text
        self.isAllDay = isAllDay
    }

    /// The event's call link: the conference link that the calendar gave apart from the text when it is a call
    /// link, else the first call link in the text. The one rule for the lists, the do-not-record choice, and its gate.
    public var callLink: (platform: Platform?, url: URL?) {
        if let link = meetingLink {
            let found = UpcomingMeeting.callLink(in: link.absoluteString)
            if found.0 != nil { return found }
        }
        return UpcomingMeeting.callLink(in: text)
    }

    /// The first call link in the text, which older builds keyed a do-not-record choice by.
    var textLink: URL? { UpcomingMeeting.callLink(in: text).1 }

    /// The owner's own entry in the invite.
    public var ownEntry: Invitee? { participants.first { $0.isSelf == true } }
    /// True when the owner said no. A source that does not say is not a no.
    public var declinedByOwner: Bool { ownEntry?.declined == true }
}

public enum EventSource: String, Codable, Sendable {
    case eventKit, google
}

/// A file attached to a calendar event, as Google gives it.
public struct EventAttachment: Codable, Equatable, Sendable, Hashable {
    /// The Drive id, which is also the document's id for a Google Doc.
    public var fileID: String?
    public var title: String
    public var mimeType: String?
    public var url: URL?

    public init(fileID: String?, title: String, mimeType: String?, url: URL?) {
        self.fileID = fileID
        self.title = title
        self.mimeType = mimeType
        self.url = url
    }
}

extension CalendarEventInfo {
    func from(eventKit uid: String?, account: String?) -> CalendarEventInfo {
        var e = self
        e.iCalUID = uid?.nonBlank
        e.calendarAccount = account?.nonBlank
        return e
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
    /// The work email the owner gave in setup also marks their calendar.
    public static func defaults(_ calendars: [CalendarInfo], ownerName: String, ownerEmail: String = "") -> Set<String> {
        let email = ownerEmail.trimmingCharacters(in: .whitespaces)
        let own = calendars.filter {
            $0.title.caseInsensitiveCompare(ownerName) == .orderedSame
                || (!email.isEmpty && $0.title.caseInsensitiveCompare(email) == .orderedSame)
                || ($0.title.contains("@") && ($0.title.caseInsensitiveCompare($0.account) == .orderedSame || isOwnersAddress($0.title, ownerName: ownerName)))
        }
        return Set((own.isEmpty ? calendars : own).map(\.id))
    }
}

extension CalendarInfo {
    /// An address whose name part fits the owner: dwebber, david.webber, davidwebber, davidw, or david.
    public static func isOwnersAddress(_ address: String, ownerName: String) -> Bool {
        let local = address.lowercased().split(separator: "@").first.map { $0.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "_", with: "") } ?? ""
        let parts = ownerName.lowercased().split(separator: " ").map(String.init)
        guard let first = parts.first, let last = parts.dropFirst().last, !local.isEmpty else { return false }
        let forms = [first.prefix(1) + last, first + last, first + last.prefix(1), first, last + first.prefix(1)]
        return forms.contains { $0 == local }
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
                isAllDay: e.isAllDay,
                participants: (e.attendees ?? []).compactMap { Invitee.make(name: $0.name, address: $0.url.absoluteString, isCurrentUser: $0.isCurrentUser) })
                .from(eventKit: e.calendarItemExternalIdentifier, account: e.calendar?.source?.title)
        }
    }
}
