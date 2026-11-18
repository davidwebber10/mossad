import Foundation

/// Where a recording that ended is cut, from its marks and the calendar. Pure. A sure change to another link cuts,
/// except a visit that comes back to the first link with no event for the other link (a breakout room). A change that is
/// not sure (a window title, a link taken during the call) cuts only when another event starts near it and the meeting
/// before it does not come back. No mark, no cut: the calendar alone never cuts.
public enum CutPlan {
    /// Marks this close to the first mark of a change are the same change (a title mark and the sure mark after it).
    public static let sameChange: TimeInterval = 60
    /// The start of another event may be this long before a change that is not sure...
    public static let eventBefore: TimeInterval = 600
    /// ...or this long after it.
    public static let eventAfter: TimeInterval = 900

    /// One change of the call, from the marks that said it.
    struct Change: Equatable {
        var at: TimeInterval
        var time: Date
        var link: String?
        var sure: Bool
        var titleKey: String?
        var platform: Platform
    }

    /// The marks in time order, joined into changes: a mark within `sameChange` of a change's first mark is that change.
    /// The change's time is its earliest, its link the sure mark's (else any mark's), and its title key the title mark's.
    static func changes(_ marks: [CallMark]) -> [Change] {
        var out: [(first: TimeInterval, marks: [CallMark])] = []
        for m in marks.sorted(by: { $0.at < $1.at }) {
            if let last = out.indices.last, m.at - out[last].first <= sameChange { out[last].marks.append(m) } else { out.append((m.at, [m])) }
        }
        return out.map { group in
            let sure = group.marks.first { $0.sure && $0.link != nil }
            let first = group.marks[0]
            return Change(at: first.at, time: first.time, link: sure?.link ?? group.marks.first { $0.link != nil }?.link, sure: sure != nil,
                          titleKey: group.marks.first { $0.titleKey != nil }?.titleKey, platform: sure?.platform ?? first.platform)
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
        // The part that runs before the change being read: its link, its first title, and its event.
        var link = r.meetingID, titleKey = r.firstTitleKey
        var event = events.flatMap { CalendarMatcher.match(for: r.platform, meetingID: r.meetingID, start: r.start, end: changes[0].time, in: $0)?.event }
        // A sure change whose visit is a breakout room: the change back is no change either.
        var skipped: Set<Int> = []

        for (i, c) in changes.enumerated() {
            let at = Int(c.at), later = changes[(i + 1)...]
            if skipped.contains(i) { reasons.append("at \(at) s: back from a breakout room, no cut"); continue }
            var agreeing: CalendarEventInfo?
            if c.sure, let new = c.link {
                guard new != link else { reasons.append("at \(at) s: the same link, no cut"); continue }
                if let first = r.meetingID, link == first, let back = later.firstIndex(where: { $0.sure && $0.link == first }),
                   !holds(new, platform: c.platform, events: events ?? []) {
                    skipped.insert(back)
                    reasons.append("at \(at) s: a sure change that comes back with no event for it, a breakout room, no cut")
                    continue
                }
            } else {
                // Not sure: the calendar must agree, and the part before must not come back.
                guard let events else { reasons.append("at \(at) s: not sure and the calendar could not be read, no cut"); continue }
                if let key = c.titleKey, key == titleKey { reasons.append("at \(at) s: the title of the part before, no cut"); continue }
                if let new = c.link, new == link { reasons.append("at \(at) s: the same link, no cut"); continue }
                let comesBack = later.contains { l in
                    (c.titleKey != nil && titleKey != nil && l.titleKey == titleKey) || (c.link != nil && link != nil && l.link == link)
                }
                if comesBack { reasons.append("at \(at) s: not sure and the meeting before comes back, no cut"); continue }
                let near = events.filter { e in
                    !e.isAllDay && !e.declinedByOwner && e != event
                        && e.start >= c.time.addingTimeInterval(-eventBefore) && e.start <= c.time.addingTimeInterval(eventAfter)
                }
                guard let found = near.min(by: { abs($0.start.timeIntervalSince(c.time)) < abs($1.start.timeIntervalSince(c.time)) }) else {
                    reasons.append("at \(at) s: not sure and no other event starts near it, no cut")
                    continue
                }
                agreeing = found
            }
            let before = cuts.last?.at ?? 0
            guard c.at - before >= minimum, length - c.at >= minimum else {
                reasons.append("at \(at) s: closer than \(Int(minimum)) s to the start, the end, or the cut before, no cut")
                continue
            }
            cuts.append(Cut(at: c.at, link: c.link, titleKey: c.titleKey))
            reasons.append("at \(at) s: \(c.sure ? "a sure change" : agreeing.map { "a change that is not sure, with an event \(minutes($0.start, c.time))" } ?? "a change"), cut")
            link = c.link
            titleKey = c.titleKey
            event = agreeing ?? events.flatMap { e in c.link.flatMap { CalendarMatcher.match(for: c.platform, meetingID: $0, start: c.time, end: r.end, in: e)?.event } }
        }
        return (cuts, reasons)
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
