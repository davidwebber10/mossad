import CoreGraphics
import Foundation

/// Finds the window that the window server names one way among the windows that Accessibility names another way. A
/// browser adds its own name, the profile, and a state ("Camera and microphone recording") to the title that
/// Accessibility reads. Two different windows never match: with more than one answer, the frame decides, or nothing does.
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

    /// Equal without the browser's additions, or one is the other with more parts after it.
    public static func same(_ a: String, _ b: String) -> Bool {
        let x = core(a), y = core(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || begins(x, with: y) || begins(y, with: x)
    }

    /// Which of `titles` (as Accessibility gives them) is the window that the window server calls `title`, or nil
    /// when none or more than one can be it. An equal title wins over one that only begins the same way. Windows
    /// with the same title are told apart by their frame (2 pt), read only then.
    public static func pick(title: String, frame: CGRect?, among titles: [String], frameOf: (Int) -> CGRect?) -> Int? {
        let own = core(title)
        guard !own.isEmpty else { return nil }
        let equal = titles.indices.filter { core(titles[$0]) == own }
        let matches = equal.isEmpty ? titles.indices.filter { same(title, titles[$0]) } : equal
        if matches.count <= 1 { return matches.first }
        guard let frame else { return nil }
        let there = matches.filter { i in
            guard let f = frameOf(i) else { return false }
            return abs(f.minX - frame.minX) <= 2 && abs(f.minY - frame.minY) <= 2 && abs(f.width - frame.width) <= 2 && abs(f.height - frame.height) <= 2
        }
        return there.count == 1 ? there[0] : nil
    }
}
