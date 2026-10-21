import Foundation

/// One meeting a person spoke in, with their talk time.
public struct PersonMeeting: Equatable, Sendable {
    public var id: String
    public var title: String
    public var platform: Platform
    public var start: Date
    public var talk: TimeInterval
    /// Their part of all speech in the meeting; nil when the meeting has no speech.
    public var share: Double?
}

public struct PersonActionItem: Equatable, Sendable {
    public var meetingID: String
    public var meetingTitle: String
    public var start: Date
    public var item: ActionItem
}

public struct CoSpeaker: Equatable, Sendable {
    public var name: String
    public var meetings: Int

    public init(name: String, meetings: Int) {
        self.name = name
        self.meetings = meetings
    }
}

public struct PersonStats: Equatable, Sendable {
    /// Newest first.
    public var meetings: [PersonMeeting] = []
    public var actionItems: [PersonActionItem] = []
    /// Most shared meetings first, then by name.
    public var oftenWith: [CoSpeaker] = []

    public init() {}

    public var totalTalk: TimeInterval { meetings.reduce(0) { $0 + $1.talk } }
    public var firstHeard: Date? { meetings.last?.start }
    public var lastHeard: Date? { meetings.first?.start }

    public var averageShare: Double? {
        let shares = meetings.compactMap(\.share)
        return shares.isEmpty ? nil : shares.reduce(0, +) / Double(shares.count)
    }
}

public enum PersonStatistics {
    /// Per person name, from the calls where that name is a speaker.
    public static func compute(_ records: [CallRecord]) -> [String: PersonStats] {
        var stats: [String: PersonStats] = [:]
        var together: [String: [String: Int]] = [:]
        for r in records.sorted(by: { $0.start > $1.start }) {
            let names = Set(r.speakerNames.values)
            guard !names.isEmpty else { continue }
            var talk: [String: TimeInterval] = [:]
            var total: TimeInterval = 0
            for u in r.utterances {
                let seconds = max(0, u.end - u.start)
                total += seconds
                if let name = r.speakerNames[u.speakerKey] { talk[name, default: 0] += seconds }
            }
            for name in names {
                let t = talk[name] ?? 0
                stats[name, default: PersonStats()].meetings.append(
                    PersonMeeting(id: r.id, title: r.title, platform: r.platform, start: r.start, talk: t,
                                  share: total > 0 ? t / total : nil))
                for other in names where other != name { together[name, default: [:]][other, default: 0] += 1 }
            }
            for item in r.actionItems {
                guard let owner = item.owner, let name = speaker(forOwner: owner, among: names) else { continue }
                stats[name]?.actionItems.append(PersonActionItem(meetingID: r.id, meetingTitle: r.title, start: r.start, item: item))
            }
        }
        for (name, counts) in together {
            stats[name]?.oftenWith = counts.map { CoSpeaker(name: $0.key, meetings: $0.value) }
                .sorted { ($1.meetings, $0.name) < ($0.meetings, $1.name) }
        }
        return stats
    }

    /// The exact name, else the one speaker with that first name. Matches how a note colors an action item's owner.
    static func speaker(forOwner owner: String, among names: Set<String>) -> String? {
        if let exact = names.first(where: { $0.caseInsensitiveCompare(owner) == .orderedSame }) { return exact }
        guard let first = firstName(owner) else { return nil }
        let matches = names.filter { firstName($0)?.caseInsensitiveCompare(first) == .orderedSame }
        return matches.count == 1 ? matches.first : nil
    }

    /// Unnamed voices and emails have no first name: "Speaker C" must not match "Speaker A".
    private static func firstName(_ name: String) -> String? {
        if name.hasPrefix("Speaker ") || name.contains("@") { return nil }
        return name.split(separator: " ").first.map(String.init)
    }
}
