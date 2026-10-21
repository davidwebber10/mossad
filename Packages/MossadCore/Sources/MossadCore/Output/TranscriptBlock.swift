import Foundation

/// Consecutive lines of one speaker, shown together in the transcript view.
public struct TranscriptBlock: Equatable, Sendable, Identifiable {
    public struct Line: Equatable, Sendable {
        public var start: TimeInterval
        public var text: String
    }

    public var id: Int
    public var speaker: String
    public var speakerKey: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var lines: [Line]

    /// Seconds each speaker talked, longest first.
    public static func talkTime(_ r: CallRecord) -> [(speaker: String, seconds: TimeInterval)] {
        let names = MarkdownWriter.displayNames(r)
        var total: [String: TimeInterval] = [:]
        for u in r.utterances { total[names[u.speakerKey] ?? u.speakerKey, default: 0] += max(0, u.end - u.start) }
        return total.map { ($0.key, $0.value) }.sorted { $0.seconds > $1.seconds || ($0.seconds == $1.seconds && $0.speaker < $1.speaker) }
    }

    /// A pause longer than `gap` starts a new block even for the same speaker.
    public static func blocks(_ r: CallRecord, gap: TimeInterval = 30) -> [TranscriptBlock] {
        let names = MarkdownWriter.displayNames(r)
        var result: [TranscriptBlock] = []
        for u in r.utterances {
            let line = Line(start: u.start, text: u.text)
            if var last = result.last, last.speakerKey == u.speakerKey, u.start - last.end <= gap {
                last.lines.append(line)
                last.end = max(last.end, u.end)
                result[result.count - 1] = last
            } else {
                result.append(TranscriptBlock(id: result.count, speaker: names[u.speakerKey] ?? u.speakerKey, speakerKey: u.speakerKey,
                                              start: u.start, end: u.end, lines: [line]))
            }
        }
        return result
    }
}
