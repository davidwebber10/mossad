import Foundation

/// Whether a browser call still shows the meeting it started as. It only observes: a change is a mark in the
/// recording, never the end of a call or the start of one. Fed with new tab reads only, never a cached one.
public struct CallLinkWatch: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case none
        /// The call had no link, and one is now sure.
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

    public private(set) var link: String?
    private struct Pending: Equatable, Sendable {
        var link: String
        var first: Date
        var last: Date
        var ownTabOpen: Bool
    }
    private var pending: Pending?

    public init(link: String?) { self.link = link }

    /// The time of the first reading of a change that waits, nil when none waits. A change whose last sure reading
    /// is older than `readingGap` is forgotten.
    public func pendingSince(at time: Date) -> Date? {
        guard let pending, time.timeIntervalSince(pending.last) <= Self.readingGap else { return nil }
        return pending.first
    }

    public func isPending(at time: Date) -> Bool { pendingSince(at: time) != nil }

    /// `tabs` nil is unknown: nothing changes, and a waiting change keeps the time of its last sure reading.
    public mutating func observe(_ tabs: [BrowserTab]?, at time: Date) -> Decision {
        guard let tabs else { return .none }
        let meetings = Self.meetings(in: tabs)
        guard let link else {
            // Only one meeting, with its link, is sure.
            guard meetings.count == 1, let id = meetings[0].id else { return .none }
            self.link = id
            return .adopt(id)
        }
        // The call's own tab is still in its meeting (a next call opened early waits): the same call.
        guard !meetings.contains(where: { $0.id == link }) else { return clear() }
        // A meeting with no link, or two others: which one is the call is not known.
        let others = Set(meetings.compactMap(\.id))
        guard meetings.allSatisfy({ $0.id != nil }), others.count == 1, let next = others.first,
              let platform = meetings.first?.platform else { return clear() }
        let ownTabOpen = tabs.contains { MeetingMatcher.meetingID(forTabURL: $0.url) == link }
        // A waiting change older than the gap is forgotten, so this reading starts a new wait.
        guard pendingSince(at: time) != nil, var waiting = pending, waiting.link == next else {
            pending = Pending(link: next, first: time, last: time, ownTabOpen: ownTabOpen)
            return .none
        }
        waiting.last = time
        waiting.ownTabOpen = waiting.ownTabOpen || ownTabOpen
        pending = waiting
        if waiting.ownTabOpen, time.timeIntervalSince(waiting.first) < Self.ownTabOpenWait { return .none }
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
