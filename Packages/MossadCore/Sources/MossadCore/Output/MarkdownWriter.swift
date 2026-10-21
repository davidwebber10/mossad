import Foundation

/// Renders a call record as the Markdown file agents read.
public enum MarkdownWriter {
    public static func fileName(for r: CallRecord) -> String {
        let title = r.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(format(r.start, "yyyy-MM-dd HHmm")) - \(title).md"
    }

    /// Speaker key → display name. Unknown speakers are lettered "Speaker A", "Speaker B", … by first appearance.
    public static func displayNames(_ r: CallRecord) -> [String: String] {
        var names = r.speakerNames
        var next = 0
        for u in r.utterances where names[u.speakerKey] == nil {
            names[u.speakerKey] = "Speaker \(Character(UnicodeScalar(UInt8(65 + next % 26))))"
            next += 1
        }
        return names
    }

    public static func transcript(_ r: CallRecord) -> String {
        let names = displayNames(r)
        var lines = Transcript.interleaved(r.utterances).map { (start: $0.start, text: "[\(timestamp($0.start))] \(names[$0.speakerKey] ?? $0.speakerKey): \($0.text)") }
        // Where a later recording of a merged meeting begins.
        lines += r.transcriptMarkers.map { (start: $0.offset, text: "[\(timestamp($0.offset))] (\($0.text))") }
        return lines.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element.text)
            .joined(separator: "\n")
    }

    public static func render(_ r: CallRecord) -> String {
        let names = displayNames(r)
        var speakers: [String] = []
        for u in r.utterances {
            if let n = names[u.speakerKey], !speakers.contains(n) { speakers.append(n) }
        }
        var lines = [
            "---",
            "date: \(format(r.start, "yyyy-MM-dd"))",
            "start: \"\(format(r.start, "HH:mm"))\"",
            "end: \"\(format(r.end, "HH:mm"))\"",
            "duration_minutes: \(Int((r.end.timeIntervalSince(r.start) / 60).rounded()))",
            "platform: \(r.platform.displayName)",
            "title: \(quoted(r.title))",
            "attendees: [\(r.attendees.map(quoted).joined(separator: ", "))]",
            "speakers: [\(speakers.map(quoted).joined(separator: ", "))]",
            "audio: ~/Mossad/Audio/\(r.id)",
        ]
        if let kind = r.kind { lines.insert("kind: \(quoted(kind))", at: lines.count - 4) }
        lines += ["---", "# \(r.title)", ""]
        if let summary = r.summary {
            lines += ["## Summary", "", summary, ""]
            for topic in r.topics { lines += ["### \(topic.title)", "", topic.summary, ""] }
            // An update meeting has no outcomes; leave the section out instead of writing "None.".
            if r.hasOutcomes != false || !r.actionItems.isEmpty {
                lines += ["## Action items", ""]
                lines += r.actionItems.isEmpty ? ["None."] : r.actionItems.map { "- [ ] \($0.text)" }
                lines.append("")
            }
            if !r.decisions.isEmpty {
                lines += ["## Decisions", ""] + r.decisions.map { "- \($0)" } + [""]
            }
        }
        lines += ["## Transcript", "", transcript(r), ""]
        return lines.joined(separator: "\n")
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
