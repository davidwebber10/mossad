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

    /// The lane's segments as drawn at one width: segments closer than `mergeGap` points join, and each block is
    /// at least `minWidth` points wide, grown around its center and kept inside the meeting. A long meeting then
    /// reads as a few readable blocks per speaker rather than hundreds of one-point slivers.
    public static func blocks(_ segments: [ClosedRange<TimeInterval>], duration: TimeInterval, width: Double,
                              mergeGap: Double, minWidth: Double) -> [ClosedRange<TimeInterval>] {
        guard width > 0, duration > 0, !segments.isEmpty else { return segments }
        let perPoint = duration / width
        let gap = mergeGap * perPoint, least = min(minWidth * perPoint, duration)
        var out: [ClosedRange<TimeInterval>] = []
        func add(_ r: ClosedRange<TimeInterval>) {
            if let last = out.last, r.lowerBound - last.upperBound <= gap {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        for s in segments.sorted(by: { $0.lowerBound < $1.lowerBound }) { add(s) }
        let merged = out
        out = []
        for b in merged {
            guard b.upperBound - b.lowerBound < least else { add(b); continue }
            let mid = (b.lowerBound + b.upperBound) / 2
            let lower = min(max(0, mid - least / 2), duration - least)
            add(lower...(lower + least))
        }
        return out
    }
}
