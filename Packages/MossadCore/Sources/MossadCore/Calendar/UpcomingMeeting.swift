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

    /// How far ahead the calendar is read, and what the calendar, the prep pages, and the recurring meetings show, so
    /// a monthly series has its next date. The Meetings list shows the next two work days of it (`listPart`).
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

    /// The end of the Meetings list's window of invites: the end of the second work day, with today the first when
    /// it is a work day. Work days are the calendar's (its locale's weekend, not a fixed Saturday and Sunday): on a
    /// Friday that is Friday and Monday, on a weekend Monday and Tuesday. The calendar shows the rest.
    public static func listWindowEnd(now: Date, calendar: Calendar = .current) -> Date {
        var day = calendar.startOfDay(for: now)
        var found = 0
        // A calendar with no work day at all would never stop: a week is the most there can be to look through.
        for _ in 0..<14 {
            if !calendar.isDateInWeekend(day) {
                found += 1
                if found == 2 { break }
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
        return calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
    }

    /// What the Meetings list shows of the invites. With no search: the ones that start before the window's end
    /// (a weekend meeting inside it too), and how many more the read holds, with the first day after the window.
    /// With a search: every invite of the read that the words find, by title or by person, as a search asks for
    /// more than the list shows by default.
    public struct ListPart: Equatable, Sendable {
        public var meetings: [UpcomingMeeting]
        /// The invites of the read after the window; 0 while a search is on.
        public var more: Int
        /// The start of the first day after the window.
        public var after: Date
    }

    public static func listPart(_ meetings: [UpcomingMeeting], query: String = "", now: Date, calendar: Calendar = .current) -> ListPart {
        let end = listWindowEnd(now: now, calendar: calendar)
        let search = ListSearch(query)
        if !search.isEmpty {
            let found = meetings.filter { search.match(title: $0.title, fields: [ListField("People", $0.attendees.joined(separator: ", "))]) != nil }
            return ListPart(meetings: found, more: 0, after: end)
        }
        let shown = meetings.filter { $0.start < end }
        return ListPart(meetings: shown, more: meetings.count - shown.count, after: end)
    }

    /// "12 more in the next 45 days".
    public static func moreText(_ n: Int) -> String { "\(n) more in the next \(days) days" }

    /// "Today", "Tomorrow", then the weekday with the date ("Tuesday, Nov 17"), so an upcoming day never reads like
    /// a past day's header ("Tuesday").
    public static func dayTitle(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let ahead = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if ahead <= 0 { return "Today" }
        if ahead == 1 { return "Tomorrow" }
        let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        return date.formatted(style.weekday(.wide).month(.abbreviated).day())
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
