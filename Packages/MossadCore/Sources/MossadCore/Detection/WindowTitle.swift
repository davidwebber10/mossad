import CoreGraphics
import Foundation

/// Finds the window that the window server names one way among the windows that Accessibility names another way. A
/// browser adds its own name, the profile, and a state ("Camera and microphone recording") to the title that
/// Accessibility reads. Two different windows never match: a title alone picks a window only when no other window
/// can be meant; with more than one, the frame decides, or nothing does.
public enum WindowTitle {
    /// A browser's name at the end of a title, with at most one more part (the profile) after it.
    private static let appSuffix = try! NSRegularExpression(
        pattern: #" [-–—] (Google Chrome( Beta| Canary| Dev)?|Chromium|Microsoft Edge( Beta| Dev| Canary)?|Brave( Browser)?)( [-–—] [^–—]*)?$"#)
    /// A title this short matches only itself: it could begin too many others.
    static let minimumPrefix = 8

    /// The title without what the browser adds at its end.
    public static func core(_ title: String) -> String {
        var t = title.replacingOccurrences(of: "\u{200B}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = appSuffix.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let range = Range(match.range, in: t) {
            t = String(t[..<range.lowerBound])
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func begins(_ long: String, with short: String) -> Bool {
        guard short.count >= minimumPrefix, long.count > short.count, long.hasPrefix(short) else { return false }
        let rest = long.dropFirst(short.count)
        return [" - ", " – ", " — "].contains { rest.hasPrefix($0) }
    }

    /// True when `accessibility` can be the title that Accessibility gives the window that the window server calls
    /// `windowServer`: equal without the browser's additions, or the window server's title with more parts after
    /// it. Not the other way: no browser gives Accessibility the shorter title.
    public static func same(_ windowServer: String, _ accessibility: String) -> Bool {
        let x = core(windowServer), y = core(accessibility)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || begins(y, with: x)
    }

    /// Which of `titles` (as Accessibility gives them) is the window that the window server calls `title`, or nil
    /// when none or more than one can be it. One candidate is picked by its title. With two or more, the title
    /// decides nothing, also when one of them is equal: the browser's window that is in a call has the longer title,
    /// and a second window with the same page has the equal one. Then only the frame decides (2 pt), and when it
    /// cannot (no frame, none that agrees, two that agree), the answer is nil and nothing is captured.
    public static func pick(title: String, frame: CGRect?, among titles: [String], frameOf: (Int) -> CGRect?) -> Int? {
        let candidates = titles.indices.filter { same(title, titles[$0]) }
        if candidates.count <= 1 { return candidates.first }
        guard let frame else { return nil }
        let there = candidates.filter { i in
            guard let f = frameOf(i) else { return false }
            return abs(f.minX - frame.minX) <= 2 && abs(f.minY - frame.minY) <= 2 && abs(f.width - frame.width) <= 2 && abs(f.height - frame.height) <= 2
        }
        return there.count == 1 ? there[0] : nil
    }
}
