import Foundation

/// One place in the main window, enough to show it again: the sidebar's section and its page, the item that is
/// open (a meeting, a person, a series, a share, a chat, a task), the page's tab, and the view state worth keeping
/// (the list's search text, the Meetings filter, the moment a meeting was opened at). No scroll offsets.
public struct NavigationPlace: Codable, Equatable, Sendable {
    public var section: String
    /// A page inside the section, such as Coach › Goals or a page of Settings.
    public var page: String?
    public var item: String?
    public var tab: String?
    public var search: String?
    public var filter: MeetingFilter?
    /// Seconds into the meeting, when it was opened at a moment.
    public var time: TimeInterval?

    public init(section: String, page: String? = nil, item: String? = nil, tab: String? = nil, search: String? = nil,
                filter: MeetingFilter? = nil, time: TimeInterval? = nil) {
        self.section = section
        self.page = page
        self.item = item
        self.tab = tab
        self.search = search
        self.filter = filter
        self.time = time
    }

    /// The same view of the window: the section, its page, and the tab. Only the selection or the view state differ.
    /// A place with nothing open has no tab to show, so a first item that opens is the same view.
    public func sameView(as other: NavigationPlace) -> Bool {
        section == other.section && page == other.page && (tab == other.tab || item == nil || other.item == nil)
    }
}

/// The main window's Back and Forward, as a browser has them: the places behind, the current one, and the places
/// ahead. For the app's life only.
public struct NavigationHistory: Equatable, Sendable {
    /// At most this many places, with the current one; the oldest goes first.
    public static let cap = 100

    public enum Step: Equatable, Sendable {
        /// A move the owner made to somewhere: a sidebar click, a link, a search result, a tab. Always a step.
        case jump
        /// A change inside the view that shows: another row of the same list, the search text, the filter. It
        /// replaces the current place, so a walk down a list is not fifty steps back.
        case refine
    }

    private var behind: [NavigationPlace] = []
    public private(set) var current: NavigationPlace?
    private var ahead: [NavigationPlace] = []

    public init() {}

    /// The places behind, the nearest first.
    public var backPlaces: [NavigationPlace] { behind.reversed() }
    /// The places ahead, the nearest first.
    public var forwardPlaces: [NavigationPlace] { ahead.reversed() }
    public var canGoBack: Bool { !behind.isEmpty }
    public var canGoForward: Bool { !ahead.isEmpty }

    /// Whether any place behind is still there.
    public func canGoBack(resolve: (NavigationPlace) -> NavigationPlace?) -> Bool { behind.contains { resolve($0) != nil } }
    public func canGoForward(resolve: (NavigationPlace) -> NavigationPlace?) -> Bool { ahead.contains { resolve($0) != nil } }

    public mutating func visit(_ place: NavigationPlace, _ step: Step = .jump) {
        guard let now = current else {
            current = place
            return
        }
        guard place != now else { return }
        if step == .refine, place.sameView(as: now) {
            current = place
            return
        }
        behind.append(now)
        if behind.count >= Self.cap { behind.removeFirst(behind.count - Self.cap + 1) }
        current = place
        ahead.removeAll()
    }

    /// The current place as the window shows it now, with no step.
    public mutating func replaceCurrent(_ place: NavigationPlace) { current = place }

    /// Goes back `steps` live places. `resolve` gives a place as it is now (a merged person's id of now) or nil when
    /// it is gone; a gone place is dropped. Nil, and nothing moves, when no live place is far enough behind.
    public mutating func goBack(steps: Int = 1, resolve: (NavigationPlace) -> NavigationPlace?) -> NavigationPlace? {
        guard let now = current, let moved = Self.move(steps, now: now, from: behind, to: ahead, resolve: resolve) else {
            behind = behind.filter { resolve($0) != nil }
            return nil
        }
        (behind, ahead, current) = (moved.from, moved.to, moved.place)
        return moved.place
    }

    public mutating func goForward(steps: Int = 1, resolve: (NavigationPlace) -> NavigationPlace?) -> NavigationPlace? {
        guard let now = current, let moved = Self.move(steps, now: now, from: ahead, to: behind, resolve: resolve) else {
            ahead = ahead.filter { resolve($0) != nil }
            return nil
        }
        (ahead, behind, current) = (moved.from, moved.to, moved.place)
        return moved.place
    }

    private static func move(_ steps: Int, now: NavigationPlace, from: [NavigationPlace], to: [NavigationPlace],
                             resolve: (NavigationPlace) -> NavigationPlace?) -> (place: NavigationPlace, from: [NavigationPlace], to: [NavigationPlace])? {
        guard steps > 0 else { return nil }
        var from = from, to = to, passed = [now], left = steps
        while let next = from.popLast() {
            guard let live = resolve(next) else { continue }
            left -= 1
            if left == 0 {
                to.append(contentsOf: passed)
                return (live, from, to)
            }
            passed.append(live)
        }
        return nil
    }
}

/// Turns the window's changes into steps. The app takes each change a moment later as one place and passes it here
/// with the time.
///
/// - A jump mark (a link, a click on a row, the sidebar) waits until the place changes, as a page can take its new
///   item a moment later; a mark that nothing took ends after `jumpLife`.
/// - Within `settle` after a jump, the late parts of the same move (the tab a link asked for) join the jump's step.
/// - After Back or Forward, nothing is a step until the window shows the place. A place that does not come within
///   `restoreLife` gives way to what the window shows, in the same entry.
public struct NavigationRecorder: Equatable, Sendable {
    public static let jumpLife: TimeInterval = 1.5
    public static let settle: TimeInterval = 0.5
    public static let restoreLife: TimeInterval = 1

    public private(set) var history = NavigationHistory()
    /// The place that Back or Forward shows, until the window shows it.
    public private(set) var pending: NavigationPlace?
    private var pendingSince = Date.distantPast
    private var jumpSince: Date?
    private var settleUntil: Date?

    public init() {}

    public mutating func markJump(at now: Date) { jumpSince = now }

    public mutating func record(_ place: NavigationPlace, at now: Date) {
        if let target = pending {
            if place == target {
                pending = nil
                return
            }
            guard now.timeIntervalSince(pendingSince) > Self.restoreLife else { return }
            pending = nil
            history.replaceCurrent(place)
            return
        }
        if let since = jumpSince {
            if now.timeIntervalSince(since) <= Self.jumpLife {
                guard place != history.current else { return }
                jumpSince = nil
                history.visit(place, .jump)
                settleUntil = now.addingTimeInterval(Self.settle)
                return
            }
            jumpSince = nil
        }
        if let until = settleUntil, now <= until, place.section == history.current?.section {
            history.replaceCurrent(place)
            return
        }
        settleUntil = nil
        history.visit(place, .refine)
    }

    /// Ends a Back or Forward that the window never showed.
    public mutating func expire(at now: Date) {
        if pending != nil, now.timeIntervalSince(pendingSince) > Self.restoreLife { pending = nil }
    }

    public mutating func back(steps: Int = 1, at now: Date, resolve: (NavigationPlace) -> NavigationPlace?) -> NavigationPlace? {
        restored(history.goBack(steps: steps, resolve: resolve), at: now)
    }

    public mutating func forward(steps: Int = 1, at now: Date, resolve: (NavigationPlace) -> NavigationPlace?) -> NavigationPlace? {
        restored(history.goForward(steps: steps, resolve: resolve), at: now)
    }

    private mutating func restored(_ place: NavigationPlace?, at now: Date) -> NavigationPlace? {
        guard let place else { return nil }
        pending = place
        pendingSince = now
        jumpSince = nil
        settleUntil = nil
        return place
    }
}
