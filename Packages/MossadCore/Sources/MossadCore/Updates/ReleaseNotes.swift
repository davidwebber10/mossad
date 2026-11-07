import Foundation

/// A release's notes as plain lines, read from the appcast's description: the release script writes an HTML
/// `<ul>` with one `<li>` per change, its text escaped.
public struct ReleaseNotes: Equatable, Sendable {
    public let lines: [String]

    public init(lines: [String]) { self.lines = lines }

    public init(html: String?) {
        guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { lines = []; return }
        let items = Self.matches(of: #"<li\b[^>]*>(.*?)</li>"#, in: html)
        let parts = items.isEmpty ? [html] : items
        lines = parts.map(Self.plain).filter { !$0.isEmpty }
    }

    /// The first three lines, and "and N more" when there are more.
    public var preview: (lines: [String], more: String?) {
        let shown = Array(lines.prefix(3))
        let rest = lines.count - shown.count
        return (shown, rest > 0 ? "and \(rest) more" : nil)
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    private static func plain(_ fragment: String) -> String {
        var text = fragment.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
