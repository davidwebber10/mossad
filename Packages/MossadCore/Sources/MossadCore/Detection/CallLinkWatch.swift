import Foundation

/// Whether a browser call still shows the meeting it started as. It only observes: a change is a mark in the
/// recording, never the end of a call or the start of one. Fed with new tab reads only, never a cached one.
public struct CallLinkWatch: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case none
        /// The call had no link, and the one meeting tab showed the same link on two readings within `readingGap`.
        case adopt(String)
        /// The call's own link left its meeting and this one is in a meeting, on two sure readings.
        case newCall(String, Platform)
    }

    /// Two sure readings of the same change must be this close: two stray answers minutes apart, with only unknown
    /// readings between them, are not one change (the rule of `CallDetector.Config.goneReadingGap`).
    public static let readingGap: TimeInterval = CallDetector.Config().goneReadingGap
    /// While the call's own tab is still open on its address and only its title left the meeting, a reload or a lost
    /// connection looks the same for some seconds: the change must last this long (the end rule's grace for a meeting
    /// missing while the mic is in use, `goneWithMicGrace`), with sure readings no more than `readingGap` apart.
    public static let ownTabOpenWait: TimeInterval = CallDetector.Config().goneWithMicGrace

    /// A wait of the same change that starts again this soon after the last sure reading keeps the earlier time for
    /// its mark (the decision still needs its own readings).
    public static let markTimeKept: TimeInterval = 60

    public private(set) var link: String?
    /// The link was taken during the call, not read from the call's own tab at its start: its marks are not sure.
    public private(set) var isAdopted = false
    private struct Pending: Equatable, Sendable {
        var link: String
        var first: Date
        var last: Date
        var ownTabOpen: Bool
        /// The time the mark gets: the first reading of this change, also of an earlier wait of it.
        var origin: Date
    }
    private var pending: Pending?
    private var adopting: (link: String, at: Date)?
    /// After a change: the link before it, so a wrong change is taken back when that link is in its meeting again.
    private var previous: String?
    /// The first and last sure readings of the way back.
    private var returning: (first: Date, last: Date)?

    public init(link: String?) { self.link = link }

    public static func == (a: Self, b: Self) -> Bool {
        a.link == b.link && a.isAdopted == b.isAdopted && a.pending == b.pending
            && a.adopting?.link == b.adopting?.link && a.adopting?.at == b.adopting?.at
            && a.previous == b.previous && a.returning?.first == b.returning?.first && a.returning?.last == b.returning?.last
    }

    /// The time of the first reading of a change that waits (the time its mark gets), nil when none waits. A change
    /// whose last sure reading is older than `readingGap` is forgotten. A link that waits to be taken counts too.
    public func pendingSince(at time: Date) -> Date? {
        if let returning, time.timeIntervalSince(returning.last) <= Self.readingGap { return returning.first }
        if let pending, time.timeIntervalSince(pending.last) <= Self.readingGap { return pending.origin }
        if let adopting, time.timeIntervalSince(adopting.at) <= Self.readingGap { return adopting.at }
        return nil
    }

    public func isPending(at time: Date) -> Bool { pendingSince(at: time) != nil }

    /// `tabs` nil is unknown: nothing changes, and a waiting change keeps the time of its last sure reading.
    public mutating func observe(_ tabs: [BrowserTab]?, at time: Date) -> Decision {
        guard let tabs else { return .none }
        let meetings = Self.meetings(in: tabs)
        guard let link else {
            // Only one meeting, with its link, on two readings: one reading can be a pinned tab while the call's own
            // tab shows no meeting title.
            guard meetings.count == 1, let id = meetings[0].id else {
                adopting = nil
                return .none
            }
            guard let waiting = adopting, waiting.link == id, time.timeIntervalSince(waiting.at) <= Self.readingGap else {
                adopting = (id, time)
                return .none
            }
            adopting = nil
            self.link = id
            isAdopted = true
            return .adopt(id)
        }
        // The link before the last change is in its meeting again, on two sure readings within the gap, whatever the
        // new link shows: that change was wrong (a tab closed by accident while the next meeting's page was open).
        if let back = previous {
            if let platform = meetings.first(where: { $0.id == back })?.platform {
                guard let r = returning, time.timeIntervalSince(r.last) <= Self.readingGap else {
                    returning = (time, time)
                    return clear()
                }
                self.link = back
                previous = nil
                returning = nil
                return clear(.newCall(back, platform))
            }
            returning = nil
        }
        // The call's own tab is still in its meeting (a next call opened early waits): the same call.
        guard !meetings.contains(where: { $0.id == link }) else { return clear() }
        // A meeting with no link, or two others: which one is the call is not known.
        let others = Set(meetings.compactMap(\.id))
        guard meetings.allSatisfy({ $0.id != nil }), others.count == 1, let next = others.first,
              let platform = meetings.first?.platform else { return clear() }
        let ownTabOpen = tabs.contains { MeetingMatcher.meetingID(forTabURL: $0.url) == link }
        // A waiting change older than the gap is forgotten, so this reading starts a new wait.
        guard let current = pending, time.timeIntervalSince(current.last) <= Self.readingGap, current.link == next else {
            let kept = pending.flatMap { $0.link == next && time.timeIntervalSince($0.last) <= Self.markTimeKept ? $0.origin : nil }
            pending = Pending(link: next, first: time, last: time, ownTabOpen: ownTabOpen, origin: kept ?? time)
            return .none
        }
        var waiting = current
        waiting.last = time
        waiting.ownTabOpen = waiting.ownTabOpen || ownTabOpen
        pending = waiting
        if waiting.ownTabOpen, time.timeIntervalSince(waiting.first) < Self.ownTabOpenWait { return .none }
        previous = link
        self.link = next
        return clear(.newCall(next, platform))
    }

    private mutating func clear(_ decision: Decision = .none) -> Decision {
        pending = nil
        return decision
    }

    /// The tabs in a meeting: a meeting platform's page, and for Meet a title that shows the meeting.
    static func meetings(in tabs: [BrowserTab]) -> [(id: String?, platform: Platform)] {
        tabs.compactMap { tab in
            guard let platform = MeetingMatcher.platform(forTabURL: tab.url) else { return nil }
            if platform == .meet, MeetingMatcher.meetTabLeftMeeting(title: tab.title) { return nil }
            return (MeetingMatcher.meetingID(forTabURL: tab.url), platform)
        }
    }
}
