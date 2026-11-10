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

    /// Whether each turn starts at or after the one before it, so `current(at:in:)` can be used.
    public static func startsAscend(_ blocks: [TranscriptBlock]) -> Bool {
        zip(blocks, blocks.dropFirst()).allSatisfy { $0.start <= $1.start }
    }

    /// The last turn that starts at or before `time`, for turns in time order. The player asks four times a second,
    /// so this halves its way to the turn; a scan of every turn each time adds up on a long meeting.
    public static func current(at time: TimeInterval, in blocks: [TranscriptBlock]) -> Int? {
        var low = 0, high = blocks.count
        while low < high {
            let mid = (low + high) / 2
            if blocks[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? blocks[low - 1].id : nil
    }

    /// Seconds each speaker talked, longest first.
    public static func talkTime(_ r: CallRecord) -> [(speaker: String, seconds: TimeInterval)] {
        let names = MarkdownWriter.displayNames(r)
        var total: [String: TimeInterval] = [:]
        for u in r.utterances { total[names[u.speakerKey] ?? u.speakerKey, default: 0] += max(0, u.end - u.start) }
        return total.map { ($0.key, $0.value) }.sorted { $0.seconds > $1.seconds || ($0.seconds == $1.seconds && $0.speaker < $1.speaker) }
    }

    /// The `limit` longest talkers, and how many more there are and how long they talked in all.
    public static func talkTime(_ r: CallRecord, limit: Int) -> (top: [(speaker: String, seconds: TimeInterval)], others: (count: Int, seconds: TimeInterval)?) {
        let all = talkTime(r)
        guard all.count > limit else { return (all, nil) }
        let rest = all.dropFirst(limit)
        return (Array(all.prefix(limit)), (rest.count, rest.reduce(0) { $0 + $1.seconds }))
    }

    /// A pause longer than `gap` starts a new block even for the same speaker.
    public static func blocks(_ r: CallRecord, gap: TimeInterval = 30) -> [TranscriptBlock] {
        let names = MarkdownWriter.displayNames(r)
        var result: [TranscriptBlock] = []
        for u in Transcript.interleaved(r.utterances) {
            let line = Line(start: u.start, text: u.text)
            // A marker (a join, a pause) starts a new block, so its line sits between blocks.
            let crossesPart = r.transcriptMarkers.contains { $0.offset > (result.last?.end ?? .infinity) && $0.offset <= u.start }
            if var last = result.last, last.speakerKey == u.speakerKey, u.start - last.end <= gap, !crossesPart {
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
