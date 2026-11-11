import Foundation

/// Letters for unnamed voices: A to Z, then AA, AB, and so on, so the 27th voice is not "A" again.
public enum SpeakerLetter {
    public static func at(_ index: Int) -> String {
        var n = max(0, index), out = ""
        repeat {
            out = String(Character(UnicodeScalar(UInt8(65 + n % 26)))) + out
            n = n / 26 - 1
        } while n >= 0
        return out
    }
}

/// Renders a call record as the Markdown file agents read.
public enum MarkdownWriter {
    public static func fileName(for r: CallRecord) -> String {
        "\(format(r.start, "yyyy-MM-dd HHmm")) - \(fileTitle(r.title)).md"
    }

    /// A file name is at most 255 bytes; the date, a suffix for a second note of the same minute, and ".md" need room.
    static let maxTitleBytes = 180

    /// The title as part of a file name: one line, no path separators, and short enough for the file system.
    static func fileTitle(_ title: String) -> String {
        var out = oneLine(title).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while out.utf8.count > maxTitleBytes { out.removeLast() }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// A line break in a title would end the YAML value and the heading.
    static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The note for a call. Two calls with the same start minute and title would share one file, and deleting one
    /// meeting would delete the other's note; the second one gets its call ID in the name.
    public static func noteURL(for r: CallRecord, in folder: URL) -> URL {
        let url = folder.appendingPathComponent(fileName(for: r))
        guard url.path != r.markdownPath, FileManager.default.fileExists(atPath: url.path) else { return url }
        // A note of this very call, written before its path was saved (the app stopped in between): use it.
        if isNote(url, of: r.id) { return url }
        return folder.appendingPathComponent(String(fileName(for: r).dropLast(3)) + " (\(r.id)).md")
    }

    /// Speaker key → display name. Unknown speakers are lettered "Speaker A", "Speaker B", … by first appearance.
    public static func displayNames(_ r: CallRecord) -> [String: String] {
        var names = r.speakerNames
        var next = 0
        for u in r.utterances where names[u.speakerKey] == nil {
            names[u.speakerKey] = "Speaker \(SpeakerLetter.at(next))"
            next += 1
        }
        return names
    }

    /// Whether the note names this call in its `audio:` line.
    static func isNote(_ url: URL, of id: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        return head.components(separatedBy: "\n").contains { $0 == "audio: ~/Mossad/Audio/\(id)" }
    }

    /// `screens` false leaves out the lines of shared screens, for a reader that only wants what people said.
    public static func transcript(_ r: CallRecord, screens: Bool = true) -> String {
        let names = displayNames(r)
        var lines = Transcript.interleaved(r.utterances).map { (start: $0.start, text: "[\(timestamp($0.start))] \(names[$0.speakerKey] ?? $0.speakerKey): \($0.text)") }
        // Where a later recording of a merged meeting begins.
        lines += (screens ? r.transcriptMarkers : r.recordingMarkers).map { (start: $0.offset, text: "[\(timestamp($0.offset))] (\($0.lineText))") }
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
            "title: \(quoted(oneLine(r.title)))",
            "attendees: [\(r.attendees.map(quoted).joined(separator: ", "))]",
            "speakers: [\(speakers.map(quoted).joined(separator: ", "))]",
            "audio: ~/Mossad/Audio/\(r.id)",
        ]
        if let kind = r.kind { lines.insert("kind: \(quoted(kind))", at: lines.count - 4) }
        if !r.tags.isEmpty { lines.insert("tags: [\(r.tags.map(quoted).joined(separator: ", "))]", at: lines.count - 4) }
        // A meeting made from its Gemini notes has no audio: the folder holds its record only.
        if let label = r.sourceLabel, let i = lines.firstIndex(where: { $0.hasPrefix("platform: ") }) { lines.insert("source: \(quoted(label))", at: i + 1) }
        if let url = r.gemini?.url { lines.append("gemini_notes: \(quoted(url.absoluteString))") }
        lines += ["---", "# \(oneLine(r.title))", ""]
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
                lines += ["## Decisions", ""] + r.decisions.map { d in d.at.map { "- [\(timestamp($0))] \(d.text)" } ?? "- \(d.text)" } + [""]
            }
        }
        // Gemini's own notes only when there is no transcript to summarize: otherwise Mossad's summary is the summary.
        if r.utterances.isEmpty, let notes = r.gemini?.notes { lines += ["## Notes by Gemini", "", notes, ""] }
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
