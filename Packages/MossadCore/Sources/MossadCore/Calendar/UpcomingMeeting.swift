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
    /// The calendar series it belongs to, when the calendar said (Google).
    public var seriesID: String?
    /// The first call link in the event's text, when it is not `link`: a do-not-record choice that an older build
    /// keyed by it still counts.
    public var textLink: URL?
    /// True when the calendar says that the invite repeats (a Google series id, or an EventKit recurrence rule).
    public var isRecurring = false

    public static let days = 7
    /// How far the calendar is read for the recurring meetings, so a monthly series has its next date. The lists
    /// still show `days`.
    public static let seriesDays = 45
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
        // A meeting the owner declined is not upcoming; the matcher and the do-not-record gate still see it.
        return events.filter { !$0.isAllDay && $0.end > now && $0.start < horizon && !isRecorded($0) && !$0.declinedByOwner }
            .sorted { $0.start < $1.start }
            .compactMap { e in
                // Only calls: an event without a call link (lunch, a focus block) is not one.
                let (platform, link) = e.callLink
                guard platform != nil else { return nil }
                let text = e.textLink
                return UpcomingMeeting(title: e.title, start: e.start, end: e.end, attendees: e.attendees, platform: platform,
                                       link: link, seriesID: e.seriesID, textLink: text == link ? nil : text,
                                       isRecurring: e.isRecurring || e.seriesID != nil)
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

    /// The time until the start, as the meeting's page shows it large: "Now", "in 25 min", "in 3 h 20 min" on the
    /// same day or within 12 hours, "Tomorrow", "in 3 days".
    public func startsIn(now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = start.timeIntervalSince(now)
        if seconds <= 0 { return "Now" }
        if seconds < 3600 { return "in \(max(1, Int(seconds / 60))) min" }
        if calendar.isDate(start, inSameDayAs: now) || seconds < 12 * 3600 { return "in \(AnalyticsFindings.duration(seconds))" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: start)).day ?? 0
        return days <= 1 ? "Tomorrow" : "in \(days) days"
    }
}
