import Foundation

/// One row per person for the player: when they spoke, and for how long.
public enum SpeakerLanes {
    public struct Lane: Equatable, Sendable {
        public var key: String
        public var name: String
        public var seconds: TimeInterval
        public var segments: [ClosedRange<TimeInterval>]
    }

    /// Pauses shorter than this do not split a segment.
    static let joinGap: TimeInterval = 1

    /// Keys with one name share a lane. The owner's lane is first, then the most talkative.
    public static func make(_ record: CallRecord, names: [String: String], ownerName: String?) -> [Lane] {
        var byName: [String: (key: String, name: String, spans: [(TimeInterval, TimeInterval)], seconds: TimeInterval)] = [:]
        var order: [String] = []
        for u in record.utterances {
            let name = names[u.speakerKey] ?? u.speakerKey
            // Letters repeat after Z, so only named people merge; each unnamed key keeps its own lane.
            let group = record.speakerNames[u.speakerKey] == nil ? "key:" + u.speakerKey : "name:" + name
            if byName[group] == nil { byName[group] = (u.speakerKey, name, [], 0); order.append(group) }
            let end = max(u.start, u.end)
            byName[group]!.spans.append((u.start, end))
            byName[group]!.seconds += end - u.start
        }
        let lanes = order.map { group -> Lane in
            let entry = byName[group]!
            var segments: [ClosedRange<TimeInterval>] = []
            for (s, e) in entry.spans.sorted(by: { $0.0 < $1.0 }) {
                if let last = segments.last, s - last.upperBound < joinGap {
                    segments[segments.count - 1] = last.lowerBound...max(last.upperBound, e)
                } else {
                    segments.append(s...e)
                }
            }
            return Lane(key: entry.key, name: entry.name, seconds: entry.seconds, segments: segments)
        }
        return lanes.sorted { a, b in
            let ao = a.name == ownerName, bo = b.name == ownerName
            if ao != bo { return ao }
            return a.seconds != b.seconds ? a.seconds > b.seconds : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
