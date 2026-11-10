import Foundation

/// One time someone shared a screen: the kept frames from one window with no pause of the capture in between. The
/// capture numbers the sessions. A slide that stays for minutes does not end one.
public struct ShareSession: Equatable, Sendable, Identifiable {
    /// For records from before sessions were numbered: frames this far apart are two sessions.
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
            if let last = sessions.last?.screens.last, same(last, s) {
                sessions[sessions.count - 1].screens.append(s)
            } else {
                sessions.append(ShareSession(screens: [s], presenter: s.presenter))
            }
        }
        return sessions
    }

    /// Two frames in a row belong to one session when the capture gave them one number. A name is never carried
    /// from one presenter's frames to another's, so a change of the name also ends a session.
    static func same(_ a: SharedScreen, _ b: SharedScreen) -> Bool {
        guard a.window == b.window, a.presenter == b.presenter else { return false }
        if let x = a.session, let y = b.session { return x == y }
        return b.offset - a.offset < maximumGap
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

/// Which frames of the viewer's filmstrip get a picture. Every frame has a mark on the line; a picture is drawn
/// (and decoded) only where there is room for one.
public enum FilmstripLayout {
    /// The open frame, and others whose place is at least `spacing` from each one already chosen, in time order.
    /// `span` is the line's length; a frame's place is its offset's part of `duration`.
    public static func pictured(_ offsets: [TimeInterval], open: Int, duration: TimeInterval, span: Double, spacing: Double) -> [Int] {
        guard duration > 0, offsets.indices.contains(open) else { return [] }
        func x(_ i: Int) -> Double { span * min(1, offsets[i] / duration) }
        var chosen = [open]
        for i in offsets.indices where chosen.allSatisfy({ abs(x($0) - x(i)) >= spacing }) { chosen.append(i) }
        return chosen.sorted()
    }
}
