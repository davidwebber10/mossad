import Foundation

public struct SpeakerSegment: Equatable, Sendable {
    public var speakerKey: String
    /// The display name, such as "Alex Rivera" or "Speaker A".
    public var speaker: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speakerKey: String, speaker: String, start: TimeInterval, end: TimeInterval) {
        self.speakerKey = speakerKey
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// Who speaks when, for the player's timeline.
public enum SpeakerTimeline {
    /// Joins runs of one speaker whose pauses are shorter than `mergeGap`; longer pauses stay as gaps.
    public static func segments(_ r: CallRecord, mergeGap: TimeInterval = 2) -> [SpeakerSegment] {
        let names = MarkdownWriter.displayNames(r)
        var result: [SpeakerSegment] = []
        for u in r.utterances.sorted(by: { $0.start < $1.start }) {
            if var last = result.last, last.speakerKey == u.speakerKey, u.start - last.end < mergeGap {
                last.end = max(last.end, u.end)
                result[result.count - 1] = last
            } else {
                result.append(SpeakerSegment(speakerKey: u.speakerKey, speaker: names[u.speakerKey] ?? u.speakerKey,
                                             start: u.start, end: u.end))
            }
        }
        return result
    }
}
