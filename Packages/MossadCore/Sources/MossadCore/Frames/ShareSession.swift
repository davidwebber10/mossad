import Foundation

/// A run of kept frames from one window with no gap of a minute or more: one time someone shared a screen.
public struct ShareSession: Equatable, Sendable, Identifiable {
    public static let maximumGap: TimeInterval = 60

    public var screens: [SharedScreen]
    /// As the call app showed it; nil when it showed no name.
    public var presenter: String?

    public var id: String { screens.first?.file ?? "" }
    public var start: TimeInterval { screens.first?.offset ?? 0 }
    public var end: TimeInterval { screens.last?.offset ?? 0 }
    public var count: Int { screens.count }

    public static func group(_ screens: [SharedScreen]) -> [ShareSession] {
        var sessions: [ShareSession] = []
        for s in screens.sorted(by: { $0.offset < $1.offset }) {
            if let last = sessions.last?.screens.last, s.offset - last.offset < maximumGap, s.window == last.window {
                sessions[sessions.count - 1].screens.append(s)
                if sessions[sessions.count - 1].presenter == nil { sessions[sessions.count - 1].presenter = s.presenter }
            } else {
                sessions.append(ShareSession(screens: [s], presenter: s.presenter))
            }
        }
        return sessions
    }

    /// True when a frame at `offset` from `window` starts a new session after a frame at `last`.
    public static func startsNew(offset: TimeInterval, window: String?, after last: (offset: TimeInterval, window: String?)?) -> Bool {
        guard let last else { return true }
        return offset - last.offset >= maximumGap || window != last.window
    }

    /// "Sam Carter shared 12:04–12:19 · 9 screens", or "Screen shared · 12:04–12:19 · 9 screens" with no presenter.
    public func heading(time: (TimeInterval) -> String) -> String {
        let from = time(start), to = time(end)
        let span = from == to ? from : "\(from)–\(to)"
        let amount = count == 1 ? "1 screen" : "\(count) screens"
        return presenter.map { "\($0) shared \(span) · \(amount)" } ?? "Screen shared · \(span) · \(amount)"
    }
}

extension SharedScreen {
    /// The transcript row: "Screen shared by Sam Carter · 12:04", or "Screen shared · while Dana Lee was speaking".
    public func rowTitle(time: String, speaker: String?) -> String {
        if let presenter { return "Screen shared by \(presenter) · \(time)" }
        if let speaker { return "Screen shared · while \(speaker) was speaking" }
        return "Screen shared · \(time)"
    }
}
