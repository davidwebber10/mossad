import Foundation

public struct VoiceStats: Equatable, Sendable {
    public var meetings: Int
    public var lastHeard: Date?

    public init(meetings: Int, lastHeard: Date?) {
        self.meetings = meetings
        self.lastHeard = lastHeard
    }
}

public enum VoiceStatistics {
    /// Per person name: the calls where that name is a speaker, and the newest of their start times.
    public static func compute(_ records: [CallRecord]) -> [String: VoiceStats] {
        var stats: [String: VoiceStats] = [:]
        for r in records {
            for name in Set(r.speakerNames.values) {
                var s = stats[name] ?? VoiceStats(meetings: 0, lastHeard: nil)
                s.meetings += 1
                s.lastHeard = max(s.lastHeard ?? r.start, r.start)
                stats[name] = s
            }
        }
        return stats
    }
}
