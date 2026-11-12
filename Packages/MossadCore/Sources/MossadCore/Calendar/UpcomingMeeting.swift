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

    /// How far ahead the calendar is read, and what every list of upcoming meetings shows: the Meetings list, the
    /// calendar, the prep pages, and the recurring meetings, so a monthly series has its next date.
    public static let days = 45
    /// The menu bar's short count.
    public static let limit = 12

    /// `recorded` hides events that are being recorded or were recorded: the call is already happening or done.
    public static func from(_ events: [CalendarEventInfo], now: Date = Date(), days: Int = days, limit: Int = limit,
                            recorded: [CallRecord] = []) -> [UpcomingMeeting] {
        let horizon = now.addingTimeInterval(Double(days) * 86_400)
        // A meeting the owner declined is not upcoming; the matcher and the do-not-record gate still see it.
        let open = events.filter { !$0.isAllDay && $0.end > now && $0.start < horizon && !$0.declinedByOwner }
        // Only a recording that ends after the first open invite starts can hide one: weeks of invites are checked
        // against the few latest records, not against every meeting ever recorded.
        let earliest = open.map(\.start).min() ?? now
        let recent = recorded.filter { $0.calendarTitle != nil && ($0.status == .recording ? now : $0.end) > earliest }
        func isRecorded(_ e: CalendarEventInfo) -> Bool {
            recent.contains { r in
                r.start < e.end && (r.status == .recording ? now : r.end) > e.start
                    && r.calendarTitle?.caseInsensitiveCompare(e.title) == .orderedSame
            }
        }
        return open.filter { !isRecorded($0) }
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

    /// One day of the Upcoming list.
    public struct Day: Equatable, Sendable {
        /// The start of the day.
        public var date: Date
        public var title: String
        public var meetings: [UpcomingMeeting]
    }

    /// The Upcoming list's days: the latest day on top and the latest meeting first in each, so time runs one way
    /// down the whole list and the next meeting sits just above the ones that happened.
    public static func byDay(_ meetings: [UpcomingMeeting], now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        let buckets = Dictionary(grouping: meetings) { calendar.startOfDay(for: max($0.start, now)) }
        return buckets.keys.sorted(by: >).map { day in
            Day(date: day, title: dayTitle(day, now: now, calendar: calendar),
                meetings: buckets[day, default: []].sorted { $0.start > $1.start })
        }
    }

    /// "Today", "Tomorrow", the weekday within the next days, else the date ("Thu, Feb 4").
    public static func dayTitle(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let ahead = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if ahead <= 0 { return "Today" }
        if ahead == 1 { return "Tomorrow" }
        let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        return ahead < 7 ? date.formatted(style.weekday(.wide)) : date.formatted(style.weekday(.abbreviated).month(.abbreviated).day())
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
