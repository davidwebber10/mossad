import Foundation

/// What Claude can look up in the meetings during a chat. Each tool returns plain text that names the call IDs,
/// so Claude can read a meeting next and link to it.
public struct ChatTools: Sendable {
    public struct Hit: Equatable, Sendable {
        public var callID: String
        public var title: String
        public var date: Date
        public var at: TimeInterval
        public var line: String
    }

    public struct Item: Equatable, Sendable {
        public var callID: String
        public var title: String
        public var date: Date
        public var owner: String?
        public var task: String
    }

    public static let defaultLimit = 20
    static let maxLimit = 60
    /// About 40k tokens: room for a long meeting, but one read cannot fill the context.
    static let maxMeetingCharacters = 160_000

    let records: [CallRecord]
    let owner: String
    /// Where the coach's reviews, its memory, and the chats live; without it only the meeting tools work.
    let paths: Paths?

    public init(records: [CallRecord], owner: String, paths: Paths? = nil) {
        self.records = records.filter { $0.status == .written }.sorted { $0.start > $1.start }
        self.owner = owner
        self.paths = paths
    }

    // MARK: Names

    /// "Jen" finds "Jennifer Lee"; "Ray" and "Austin Ray" find "Austin Ray".
    static func name(_ query: String, matches person: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let p = person.lowercased()
        guard q.count >= 2 else { return false }
        if p == q || p.contains(q) && q.contains(" ") { return true }
        let parts = p.split(separator: " ").map(String.init)
        if let first = parts.first, first == q || (q.count >= 3 && first.hasPrefix(q)) { return true }
        return parts.dropFirst().contains(q)
    }

    private func people(_ r: CallRecord) -> [String] {
        Array(Set(r.speakerNames.values).union(r.attendees.filter { !$0.contains("@") })).filter { !$0.hasPrefix("Speaker ") }.sorted()
    }

    /// Everyone in the meetings, most frequent first, for the system prompt.
    public var knownPeople: [String] {
        var counts: [String: Int] = [:]
        for r in records { for p in people(r) where p != owner { counts[p, default: 0] += 1 } }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    // MARK: Tools

    public func findMeetings(query: String? = nil, people names: [String] = [], from: Date? = nil, to: Date? = nil,
                             tag: String? = nil, limit: Int = defaultLimit) -> [CallRecord] {
        records.filter { r in
            if let from, r.start < from { return false }
            if let to, r.start >= to { return false }
            if let tag, !r.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { return false }
            let here = people(r)
            if !names.allSatisfy({ n in here.contains { Self.name(n, matches: $0) } }) { return false }
            if let q = query?.trimmingCharacters(in: .whitespaces), !q.isEmpty, !MeetingSearch.matches(r, q),
               !(r.summary ?? "").localizedCaseInsensitiveContains(q) { return false }
            return true
        }.prefix(min(limit, Self.maxLimit)).map { $0 }
    }

    public func searchTranscripts(query: String, people names: [String] = [], from: Date? = nil, to: Date? = nil,
                                  limit: Int = 30) -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var hits: [Hit] = []
        for r in findMeetings(people: names, from: from, to: to, limit: Self.maxLimit * 10) {
            let display = MarkdownWriter.displayNames(r)
            for u in Transcript.interleaved(r.utterances) where u.text.localizedCaseInsensitiveContains(q) {
                hits.append(Hit(callID: r.id, title: r.title, date: r.start, at: u.start,
                                line: "[\(MarkdownWriter.timestamp(u.start))] \(display[u.speakerKey] ?? u.speakerKey): \(u.text)"))
                if hits.count >= min(limit, Self.maxLimit) { return hits }
            }
        }
        return hits
    }

    public func readMeeting(_ id: String) -> String? {
        guard let r = records.first(where: { $0.id == id }) else { return nil }
        var parts = [header(r)]
        if !r.attendees.isEmpty { parts.append("Invited: \(r.attendees.joined(separator: ", "))") }
        if let s = r.summary { parts.append("Summary:\n\(s)") }
        for t in r.topics { parts.append("### \(t.title)\n\(t.summary)") }
        if !r.decisions.isEmpty { parts.append("Decisions:\n" + r.decisions.map { "- \($0)" }.joined(separator: "\n")) }
        if !r.actionItems.isEmpty { parts.append("Action items:\n" + r.actionItems.map { "- \($0.text)" }.joined(separator: "\n")) }
        let transcript = MarkdownWriter.transcript(r)
        parts.append("Transcript:\n" + String(transcript.prefix(Self.maxMeetingCharacters))
                     + (transcript.count > Self.maxMeetingCharacters ? "\n(Transcript cut here; use search_transcripts for later parts.)" : ""))
        return parts.joined(separator: "\n\n")
    }

    public func actionItems(owner name: String? = nil, from: Date? = nil, to: Date? = nil) -> [Item] {
        findMeetings(from: from, to: to, limit: Self.maxLimit * 10).flatMap { r in
            r.actionItems.filter { item in
                guard let name else { return true }
                return item.owner.map { Self.name(name, matches: $0) } ?? false
            }.map { Item(callID: r.id, title: r.title, date: r.start, owner: $0.owner, task: $0.task) }
        }
    }

    private func header(_ r: CallRecord) -> String {
        var line = "call_id: \(r.id) | \(r.title) | \(day(r.start)) | \(Int((r.end.timeIntervalSince(r.start) / 60).rounded())) min | people: \(people(r).joined(separator: ", "))"
        if !r.tags.isEmpty { line += " | tags: \(r.tags.joined(separator: ", "))" }
        if let h = r.headline { line += " | \(h)" }
        if let note = r.markdownPath { line += " | note: \(note)" }
        return line
    }

    private func day(_ d: Date) -> String {
        d.formatted(.dateTime.weekday(.abbreviated).year().month(.abbreviated).day().hour().minute())
    }

    // MARK: Claude

    /// The meeting tools, plus the coach, people, stats, memory, and chat tools.
    public static var allDefinitions: [ToolSpec] { definitions + coachDefinitions }

    public static var definitions: [ToolSpec] { [
        ToolSpec(name: "find_meetings",
                 description: "Lists meetings, newest first, with call_id, title, date, length, people, tags, and a one-line summary. Every filter is optional and they combine. people matches first names, short forms (\"Jen\" finds Jennifer), last names, or full names; every person listed must be in the meeting. Dates are YYYY-MM-DD in local time; to is inclusive.",
                 schema: ["type": "object", "properties": [
                    "query": ["type": "string", "description": "Words in the title, tags, summary, or transcript."],
                    "people": ["type": "array", "items": ["type": "string"]],
                    "from": ["type": "string"], "to": ["type": "string"],
                    "tag": ["type": "string"], "limit": ["type": "integer"],
                 ] as [String: Any]]),
        ToolSpec(name: "search_transcripts",
                 description: "Finds transcript lines that contain a word or phrase, with the meeting, the time, and the speaker. Narrow by people and dates like find_meetings.",
                 schema: ["type": "object", "properties": [
                    "query": ["type": "string"], "people": ["type": "array", "items": ["type": "string"]],
                    "from": ["type": "string"], "to": ["type": "string"], "limit": ["type": "integer"],
                 ] as [String: Any], "required": ["query"]]),
        ToolSpec(name: "read_meeting",
                 description: "Reads one meeting in full: people, summary, topics, decisions, action items with owners, and the whole timestamped transcript. Use it before saying what someone said, agreed to, or committed to.",
                 schema: ["type": "object", "properties": ["call_id": ["type": "string"]], "required": ["call_id"]]),
        ToolSpec(name: "action_items",
                 description: "Lists action items from meeting summaries with their owner, meeting, and date. Filter by owner (same name matching as find_meetings) and dates.",
                 schema: ["type": "object", "properties": [
                    "owner": ["type": "string"], "from": ["type": "string"], "to": ["type": "string"],
                 ] as [String: Any]]),
    ] }

    /// Runs a tool call from Claude and returns its result as text.
    public func run(_ name: String, input: [String: Any]) -> String {
        let people = input["people"] as? [String] ?? []
        let from = (input["from"] as? String).flatMap { Self.date($0) }
        let to = (input["to"] as? String).flatMap { Self.date($0) }.map { $0.addingTimeInterval(86_400) }
        let limit = input["limit"] as? Int ?? Self.defaultLimit
        switch name {
        case "find_meetings":
            let found = findMeetings(query: input["query"] as? String, people: people, from: from, to: to, tag: input["tag"] as? String, limit: limit)
            return found.isEmpty ? "No meetings match." : found.map(header).joined(separator: "\n")
        case "search_transcripts":
            let hits = searchTranscripts(query: input["query"] as? String ?? "", people: people, from: from, to: to, limit: limit)
            return hits.isEmpty ? "No transcript lines match." : hits.map { "call_id: \($0.callID) | \($0.title) | \(day($0.date)) | \($0.line)" }.joined(separator: "\n")
        case "read_meeting":
            return (input["call_id"] as? String).flatMap(readMeeting) ?? "No meeting with that call_id."
        case "action_items":
            let items = actionItems(owner: input["owner"] as? String, from: from, to: to)
            return items.isEmpty ? "No action items match." : items.map {
                "call_id: \($0.callID) | \($0.title) | \(day($0.date)) | \($0.owner ?? "no owner"): \($0.task)"
            }.joined(separator: "\n")
        default:
            return runCoachTool(name, input: input, from: from, to: to, people: people, limit: limit) ?? "Unknown tool \(name)."
        }
    }

    static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }

    /// The line shown while a tool runs, such as "Finding meetings with Jen".
    static func step(_ name: String, input: [String: Any], title: (String) -> String?) -> String {
        switch name {
        case "find_meetings":
            if let p = input["people"] as? [String], !p.isEmpty { return "Finding meetings with \(p.joined(separator: " and "))" }
            if let q = input["query"] as? String, !q.isEmpty { return "Finding meetings about \(q)" }
            return "Finding meetings"
        case "search_transcripts": return "Searching transcripts for “\(input["query"] as? String ?? "")”"
        case "read_meeting": return "Reading \((input["call_id"] as? String).flatMap(title) ?? "a meeting")"
        case "action_items": return (input["owner"] as? String).map { "Listing action items for \($0)" } ?? "Listing action items"
        case "coach_profile": return "Reading what the coach knows about you"
        case "coach_reviews": return "Reading the coach's reviews"
        case "read_coach_review": return "Reading the coach's review of \((input["call_id"] as? String).flatMap(title) ?? "a meeting")"
        case "people": return (input["query"] as? String).map { "Looking up \($0)" } ?? "Looking at the people you meet"
        case "stats": return "Adding up your numbers"
        case "remember": return "Remembering that"
        case "past_chats", "read_chat": return "Reading earlier chats"
        default: return "Looking it up"
        }
    }
}
