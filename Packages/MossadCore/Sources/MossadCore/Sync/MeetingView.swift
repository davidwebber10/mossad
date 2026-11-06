import Foundation

/// A meeting as the server's MCP and share pages read it: the note's parts with display names, built here so
/// the naming rules live in one place. `server/src/types.ts` has the same shape.
public struct MeetingView: Codable, Equatable, Sendable {
    public struct Line: Codable, Equatable, Sendable {
        public var at: TimeInterval
        public var speaker: String
        public var text: String
    }

    public struct Item: Codable, Equatable, Sendable {
        public var task: String
        public var owner: String?
        public var text: String
    }

    public struct Topic: Codable, Equatable, Sendable {
        public var title: String
        public var summary: String
    }

    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var platform: String?
    public var kind: String?
    public var headline: String?
    public var tags: [String]
    public var people: [String]
    public var attendees: [String]
    public var summary: String?
    public var topics: [Topic]
    public var decisions: [Decision]
    public var actionItems: [Item]
    public var lines: [Line]
    public var timeZone: String?

    public init(_ r: CallRecord, timeZone: TimeZone = .current) {
        id = r.id
        title = r.title
        start = r.start
        end = r.end
        platform = r.platform.rawValue
        kind = r.kind
        headline = r.headline
        tags = r.tags
        people = Self.people(r)
        attendees = r.attendees
        summary = r.summary
        topics = r.topics.map { Topic(title: $0.title, summary: $0.summary) }
        decisions = r.decisions
        actionItems = r.actionItems.map { Item(task: $0.task, owner: $0.owner, text: $0.text) }
        let names = MarkdownWriter.displayNames(r)
        lines = Transcript.interleaved(r.utterances).map { Line(at: $0.start, speaker: names[$0.speakerKey] ?? $0.speakerKey, text: $0.text) }
        self.timeZone = timeZone.identifier
    }

    /// Named people: the voices and the invited names, without "Speaker A" and without email addresses.
    static func people(_ r: CallRecord) -> [String] {
        Array(Set(r.speakerNames.values).union(r.attendees.filter { !$0.contains("@") })).filter { !$0.hasPrefix("Speaker ") }.sorted()
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
