import Foundation

/// A meeting as the server's MCP and share pages read it: the note's parts with display names, built here so
/// the naming rules live in one place. `server/src/types.ts` has the same shape.
public struct MeetingView: Codable, Equatable, Sendable {
    public struct Line: Codable, Equatable, Sendable {
        public var at: TimeInterval
        public var speaker: String
        public var text: String
        /// The speaker's id in `people.json`, when the record has it. Never on a share page.
        public var speakerId: String? = nil
    }

    public struct Item: Codable, Equatable, Sendable {
        public var task: String
        public var owner: String?
        public var text: String
        /// The owner's id in `people.json`, when the record has it. Never on a share page.
        public var ownerId: String? = nil
    }

    /// A saved person of the meeting: the id and the name of now.
    public struct PersonRef: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
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
    /// The saved people of the meeting with their ids; nil for a record with no ids. A deployed server that does not
    /// know it reads `people` as before.
    public var persons: [PersonRef]?
    public var attendees: [String]
    public var summary: String?
    public var topics: [Topic]
    public var decisions: [String]
    /// Seconds into the call for each decision, in order; nil when none is known. Beside the text so the
    /// deployed Worker keeps reading `decisions` as strings.
    public var decisionTimes: [Double?]?
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
        decisions = r.decisions.map(\.text)
        decisionTimes = Decision.times(of: r.decisions)
        actionItems = r.actionItems.map { Item(task: $0.task, owner: $0.owner, text: $0.text, ownerId: $0.ownerID) }
        let names = MarkdownWriter.displayNames(r)
        lines = Transcript.interleaved(r.utterances).map {
            Line(at: $0.start, speaker: names[$0.speakerKey] ?? $0.speakerKey, text: $0.text, speakerId: r.speakerPeople?[$0.speakerKey])
        }
        persons = Self.persons(r)
        self.timeZone = timeZone.identifier
    }

    /// The saved people of a record, by id, with the label the record has for each: the voices first, then the
    /// invited people.
    static func persons(_ r: CallRecord) -> [PersonRef]? {
        var out: [PersonRef] = []
        for (key, id) in (r.speakerPeople ?? [:]).sorted(by: { $0.key < $1.key }) where !out.contains(where: { $0.id == id }) {
            if let name = r.speakerNames[key] { out.append(PersonRef(id: id, name: name)) }
        }
        for i in r.invitees ?? [] {
            guard let id = i.personID, !out.contains(where: { $0.id == id }), let name = i.name.map(PersonNames.plain) ?? i.email else { continue }
            out.append(PersonRef(id: id, name: name))
        }
        return out.isEmpty ? nil : out
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
