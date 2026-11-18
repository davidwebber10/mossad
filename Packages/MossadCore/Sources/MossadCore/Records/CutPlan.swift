import Foundation

/// Where a recording that ended is cut, from its marks and the calendar. Pure. A sure change to another link cuts,
/// except a visit that comes back with no event for the other link (a breakout room). A change that is not sure (a
/// window title, a link taken during the call) cuts only when another event with a call link starts near it and the
/// meeting before it does not come back. A change taken back within a minute is no change. No mark, no cut: the calendar
/// alone never cuts.
public enum CutPlan {
    /// A sure mark this soon after a title mark is the same change seen twice.
    public static let sameChange: TimeInterval = 60
    /// The start of another event may be this long before a change that is not sure...
    public static let eventBefore: TimeInterval = 600
    /// ...or this long after it.
    public static let eventAfter: TimeInterval = 900

    /// A recording whose cut is still to be decided: recorded, with marks, never cut, and not decided before.
    public static func waits(_ r: CallRecord) -> Bool {
        r.status == .recorded && r.cutFrom == nil && r.cutChecked != true && !(r.callMarks ?? []).isEmpty
    }

    /// One change of the call, from the marks that said it.
    struct Change: Equatable {
        var at: TimeInterval
        var time: Date
        var link: String?
        var sure: Bool
        var titleKey: String?
        var platform: Platform
        /// The title mark's `CallMark.ownLinkInMeeting`.
        var ownLinkInMeeting: Bool?
    }

    /// The marks in time order, joined into changes. A mark joins the change before it only when it is the same change
    /// seen twice: a sure mark with a link within `sameChange` of a title mark, in a change with no sure mark yet. Two
    /// title marks, or two sure marks, are two changes. The change's time is its earliest, its link the sure mark's (else
    /// any mark's), and its title key the title mark's.
    static func changes(_ marks: [CallMark]) -> [Change] {
        var groups: [[CallMark]] = []
        for m in marks.sorted(by: { $0.at < $1.at }) {
            if let last = groups.last, m.sure, m.link != nil, last.count == 1, last[0].source == .title, !last[0].sure,
               m.at - last[0].at <= sameChange {
                groups[groups.count - 1].append(m)
            } else {
                groups.append([m])
            }
        }
        return groups.map { group in
            let sure = group.first { $0.sure && $0.link != nil }
            let first = group[0], title = group.first { $0.source == .title }
            return Change(at: first.at, time: first.time, link: sure?.link ?? group.first { $0.link != nil }?.link, sure: sure != nil,
                          titleKey: group.first { $0.titleKey != nil }?.titleKey, platform: sure?.platform ?? first.platform,
                          ownLinkInMeeting: title?.ownLinkInMeeting)
        }
    }

    /// The cuts of `r` (taken in time order) and the reasons for each change, in counts and kinds only: never a title or
    /// a link. `events`: the calendar from `start - 10 min` to `end + 10 min`; nil when it could not be read. `length`: the
    /// recording's length in seconds of its own timeline.
    public static func decide(_ r: CallRecord, events: [CalendarEventInfo]?, length: TimeInterval) -> (cuts: [Cut], reasons: [String]) {
        let changes = changes(r.callMarks ?? [])
        guard !changes.isEmpty else { return ([], ["no mark"]) }
        let minimum = ProcessingQueue.minimumCallDuration
        var cuts: [Cut] = [], reasons: [String] = []
        // The part that runs before the change being read: its link, its first title, and its own event.
        var link = r.meetingID, titleKey = r.firstTitleKey
        var event = ownEvent(r, until: changes[0].time, events: events)
        var skipped: Set<Int> = []
        // Links judged a breakout room of the part that runs: a later visit to one is no change either.
        var rooms: Set<String> = []

        /// The change goes back to the part that runs: its title, or its link.
        func returns(_ m: Change) -> Bool {
            (m.titleKey != nil && m.titleKey == titleKey) || (m.link != nil && m.link == link)
        }

        for (i, c) in changes.enumerated() {
            let at = Int(c.at), later = changes[(i + 1)...]
            if skipped.contains(i) { reasons.append("at \(at) s: back within \(Int(minimum)) s, no cut"); continue }
            // Taken back by the next change within the minimum (a look at another page, a short visit): neither cuts.
            if let next = later.first, next.at - c.at < minimum, returns(next), !returns(c) {
                skipped.insert(i + 1)
                reasons.append("at \(at) s: taken back \(Int(next.at - c.at)) s later, no cut")
                continue
            }
            var agreeing: CalendarEventInfo?
            if c.sure, let new = c.link {
                guard new != link else { reasons.append("at \(at) s: the same link, no cut"); continue }
                if rooms.contains(new) { reasons.append("at \(at) s: a breakout room again, no cut"); continue }
                if let current = link, later.contains(where: { $0.sure && $0.link == current }), !holds(new, platform: c.platform, events: events ?? []) {
                    rooms.insert(new)
                    reasons.append("at \(at) s: a sure change that comes back with no event for it\(events == nil ? " (the calendar could not be read)" : ""), a breakout room, no cut")
                    continue
                }
            } else {
                // Not sure: the calendar must agree, and the part before must not come back.
                guard let events else { reasons.append("at \(at) s: not sure and the calendar could not be read, no cut"); continue }
                if c.ownLinkInMeeting == true { reasons.append("at \(at) s: a title while the call's own tab was in its meeting, no cut"); continue }
                if returns(c) { reasons.append("at \(at) s: the title or the link of the part before, no cut"); continue }
                if let new = c.link, let own = event, holds(new, platform: c.platform, events: [own]) {
                    reasons.append("at \(at) s: the link of the part's own event, no cut")
                    continue
                }
                // A sure change follows with no return between: the same move, seen early. Only the sure change cuts.
                if let j = later.firstIndex(where: { $0.sure && $0.link != nil && $0.link != link }),
                   !changes[(i + 1)..<j].contains(where: returns) {
                    reasons.append("at \(at) s: not sure and a sure change of the same move follows, no cut")
                    continue
                }
                if later.contains(where: returns) { reasons.append("at \(at) s: not sure and the meeting before comes back, no cut"); continue }
                let near = events.filter { e in
                    !e.isAllDay && !e.declinedByOwner && CalendarMatcher.hasCallLink(e, platform: c.platform) && !same(e, event)
                        && e.start >= c.time.addingTimeInterval(-eventBefore) && e.start <= c.time.addingTimeInterval(eventAfter)
                }
                guard let found = near.min(by: { abs($0.start.timeIntervalSince(c.time)) < abs($1.start.timeIntervalSince(c.time)) }) else {
                    reasons.append("at \(at) s: not sure and no other event with a call link starts near it, no cut")
                    continue
                }
                agreeing = found
            }
            let before = cuts.last?.at ?? 0
            guard c.at - before >= minimum, length - c.at >= minimum else {
                reasons.append("at \(at) s: closer than \(Int(minimum)) s to the start, the end, or the cut before, no cut")
                // A sure change still moved the call: the part runs on its link from here.
                if c.sure { link = c.link }
                continue
            }
            cuts.append(Cut(at: c.at, link: c.link, titleKey: c.titleKey))
            reasons.append("at \(at) s: \(c.sure ? "a sure change" : agreeing.map { "a change that is not sure, with an event \(minutes($0.start, c.time))" } ?? "a change"), cut")
            link = c.link
            titleKey = c.titleKey
            rooms = []
            event = agreeing ?? events.flatMap { e in c.link.flatMap { CalendarMatcher.match(for: c.platform, meetingID: $0, start: c.time, end: r.end, in: e)?.event } }
        }
        return (cuts, reasons)
    }

    /// The first part's own event, by the matcher. With no link, only an event that overlaps at least half of the part or
    /// half of itself: an event that only begins near the end of the part is the next call's.
    static func ownEvent(_ r: CallRecord, until end: Date, events: [CalendarEventInfo]?) -> CalendarEventInfo? {
        guard let events, let e = CalendarMatcher.match(for: r.platform, meetingID: r.meetingID, start: r.start, end: end, in: events)?.event else {
            return nil
        }
        guard r.meetingID == nil else { return e }
        let overlap = min(end, e.end).timeIntervalSince(max(r.start, e.start))
        return overlap >= end.timeIntervalSince(r.start) / 2 || overlap >= e.end.timeIntervalSince(e.start) / 2 ? e : nil
    }

    /// `e` is the part's own event or another copy of it: the same invite id, the same call link, or the same title and start.
    static func same(_ e: CalendarEventInfo, _ own: CalendarEventInfo?) -> Bool {
        guard let own else { return false }
        if e == own { return true }
        if let a = e.iCalUID, a == own.iCalUID { return true }
        if let a = e.callLink.url.flatMap({ MeetingMatcher.meetingID(forTabURL: $0.absoluteString) }),
           a == own.callLink.url.flatMap({ MeetingMatcher.meetingID(forTabURL: $0.absoluteString) }) { return true }
        return e.title == own.title && e.start == own.start
    }

    /// A calendar event holds the link: the matcher finds an event by it, as it finds a call's invite by its meeting id.
    static func holds(_ link: String, platform: Platform, events: [CalendarEventInfo]) -> Bool {
        CalendarMatcher.match(for: platform, meetingID: link, start: .distantPast, end: .distantFuture, in: events) != nil
    }

    private static func minutes(_ start: Date, _ change: Date) -> String {
        let m = Int((start.timeIntervalSince(change) / 60).rounded())
        return m == 0 ? "that starts at it" : m < 0 ? "that starts \(-m) min before" : "that starts \(m) min after"
    }
}
