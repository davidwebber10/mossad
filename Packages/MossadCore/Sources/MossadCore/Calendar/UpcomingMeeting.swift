import Foundation

/// A calendar event still to come (or running now), for the Upcoming list and the menu bar.
public struct UpcomingMeeting: Identifiable, Equatable, Sendable {
    public var id: String { "upcoming:\(Int(start.timeIntervalSince1970)):\(title)" }
    public var title: String
    public var start: Date
    public var end: Date
    public var attendees: [String]
    /// The call app its link is for; nil for an event with no call link.
    public var platform: Platform?
    public var link: URL?

    public static let days = 7
    public static let limit = 12

    /// `recorded` hides events that are being recorded or were recorded: the call is already happening or done.
    public static func from(_ events: [CalendarEventInfo], now: Date = Date(), days: Int = days, limit: Int = limit,
                            recorded: [CallRecord] = []) -> [UpcomingMeeting] {
        let horizon = now.addingTimeInterval(Double(days) * 86_400)
        func isRecorded(_ e: CalendarEventInfo) -> Bool {
            recorded.contains { r in
                r.calendarTitle?.caseInsensitiveCompare(e.title) == .orderedSame
                    && r.start < e.end && (r.status == .recording ? now : r.end) > e.start
            }
        }
        return events.filter { !$0.isAllDay && $0.end > now && $0.start < horizon && !isRecorded($0) }
            .sorted { $0.start < $1.start }
            .compactMap { e in
                // Only calls: an event without a call link (lunch, a focus block) is not one.
                let (platform, link) = callLink(in: e.text)
                guard platform != nil else { return nil }
                return UpcomingMeeting(title: e.title, start: e.start, end: e.end, attendees: e.attendees, platform: platform, link: link)
            }
            .prefix(limit).map { $0 }
    }

    /// The first URL in the event's location, notes, or URL that points at a call app.
    static func callLink(in text: String) -> (Platform?, URL?) {
        let urls = text.split { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "\"" }
            .map(String.init).filter { $0.hasPrefix("https://") || $0.hasPrefix("http://") }
        for url in urls {
            for platform in Platform.callApps where CalendarMatcher.linkMarkers(platform).contains(where: { url.lowercased().contains($0) }) {
                return (platform, URL(string: url))
            }
        }
        return (nil, nil)
    }

    /// Earlier meetings with the same title, newest first: the series this event belongs to.
    public func earlier(in records: [CallRecord]) -> [CallRecord] {
        records.filter { $0.status == .written && $0.start < start && $0.title.caseInsensitiveCompare(title) == .orderedSame }
            .sorted { $0.start > $1.start }
    }
}
