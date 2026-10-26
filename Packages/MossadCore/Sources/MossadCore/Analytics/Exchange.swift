import Foundation

/// Who said what, and how, in one call: the turn-taking numbers the Analytics and People pages build on.
/// Speakers are their names, or their key ("them:C") until named. Pure.
public struct Exchange: Sendable {
    public struct Line: Sendable {
        public var name: String
        public var start: TimeInterval
        public var end: TimeInterval
        public var text: String
    }

    /// The same rule as the coach: starting a second or more before the other person stops is cutting in.
    static let overlapGrace = DeliveryStats.overlapGrace
    /// A longer pause is a new thought, not an answer.
    static let maxReplyGap: TimeInterval = 10

    public let lines: [Line]

    public init(record r: CallRecord) {
        lines = r.utterances.map { Line(name: r.speakerNames[$0.speakerKey] ?? $0.speakerKey, start: $0.start, end: $0.end, text: $0.text) }
            .sorted { $0.start < $1.start }
    }

    public var names: Set<String> { Set(lines.map(\.name)) }
    public var firstSpeaker: String? { lines.first?.name }

    public func speech(_ name: String) -> TimeInterval {
        lines.filter { $0.name == name }.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }

    public func questions(_ name: String) -> Int {
        lines.filter { $0.name == name && $0.text.contains("?") }.count
    }

    /// Times `name` started while `other` (anyone else when nil) still had the floor, and took it: a line of a
    /// few words that outlasts the other person's. "Yeah" while someone talks is listening, and a line the
    /// other person talks through did not take the floor.
    public func interruptions(by name: String, of other: String? = nil) -> Int {
        lines.filter { $0.name == name && $0.text.split(separator: " ").count >= Self.minimumCutInWords }.filter { u in
            lines.contains { o in
                o.name != name && (other == nil || o.name == other) && o.start < u.start && o.end > u.start + Self.overlapGrace && o.end < u.end
            }
        }.count
    }

    static let minimumCutInWords = 3

    /// Pauses before `from` answered `to`: `from`'s line comes right after `to`'s, without overlap.
    public func replyGaps(to: String, from: String) -> [TimeInterval] {
        zip(lines, lines.dropFirst()).compactMap { a, b in
            guard a.name == to, b.name == from else { return nil }
            let gap = b.start - a.end
            return gap >= 0 && gap <= Self.maxReplyGap ? gap : nil
        }
    }
}

func median(of values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let s = values.sorted()
    return s.count.isMultiple(of: 2) ? (s[s.count / 2 - 1] + s[s.count / 2]) / 2 : s[s.count / 2]
}
