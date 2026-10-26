import Foundation

/// The coach's read on one person, across all of the owner's calls with them: a one-line way to work with
/// them, then a few sections the coach picks for that person (their goals, how to communicate with them, how
/// they communicate, and whatever else the calls show). Each point names the call it came from.
public struct PersonBrief: Codable, Equatable, Sendable, Hashable {
    public struct Point: Codable, Equatable, Sendable, Hashable {
        public var text: String
        public var callID: String?

        public init(text: String, callID: String?) {
            self.text = text
            self.callID = callID
        }
    }

    public struct Section: Codable, Equatable, Sendable, Hashable {
        public var title: String
        public var points: [Point]

        public init(title: String, points: [Point]) {
            self.title = title
            self.points = points
        }
    }

    public var headline: String
    public var sections: [Section]
    /// The calls with them it was built from.
    public var calls: Int
    public var updated: Date

    public init(headline: String, sections: [Section], calls: Int, updated: Date) {
        self.headline = headline
        self.sections = sections
        self.calls = calls
        self.updated = updated
    }

    /// Plain text, for Chat and other AI apps.
    public var text: String {
        ([headline] + sections.map { s in "\(s.title): " + s.points.map(\.text).joined(separator: " ") }).joined(separator: "\n")
    }
}

/// Writes and updates the coach's read on one person.
public struct PersonBriefWriter: Sendable {
    /// Recent calls carry the most signal; older ones are already in the earlier brief.
    static let maxCalls = 12
    static let summaryCharacters = 800
    static let maxLines = 15
    static let lineCharacters = 300
    /// Two calls show a pattern; one is an anecdote.
    static let minimumCalls = 2
    static let minimumGap: TimeInterval = 20 * 3600
    /// Briefs written per run, so a first run cannot cost much.
    public static let perRun = 5

    private let llm: any LanguageModel
    private let ownerName: String

    public init(llm: any LanguageModel, ownerName: String) {
        self.llm = llm
        self.ownerName = ownerName
    }

    /// People with a call since their brief (or no brief yet), and no brief written in the last day, most
    /// recent first.
    public static func due(profile: CoachProfile, records: [CallRecord], owner: String, now: Date = Date()) -> [String] {
        var latest: [String: Date] = [:], count: [String: Int] = [:]
        for r in records where r.status == .written {
            for name in Set(r.speakerNames.values) where name != owner && !name.hasPrefix("Speaker ") && !name.contains(":") {
                latest[name] = max(latest[name] ?? r.end, r.end)
                count[name, default: 0] += 1
            }
        }
        return latest.filter { name, last in
            guard (count[name] ?? 0) >= minimumCalls else { return false }
            guard let brief = profile.people[name]?.brief else { return true }
            return last > brief.updated && now.timeIntervalSince(brief.updated) >= minimumGap
        }
        .sorted { $0.value > $1.value }.prefix(perRun).map(\.key)
    }

    public func brief(for name: String, records: [CallRecord], profile: CoachProfile, now: Date = Date()) async throws -> PersonBrief {
        let shared = records.filter { $0.status == .written && $0.speakerNames.values.contains(name) }.sorted { $0.start > $1.start }
        let used = Array(shared.prefix(Self.maxCalls))
        let ids = Set(used.map(\.id))
        let out = try await llm.json(system: system(name), user: user(name, used, profile: profile), schema: Self.schema,
                                     effort: .medium, purpose: .coach, as: Output.self)
        let sections = out.sections.prefix(6).map { s in
            PersonBrief.Section(title: s.title, points: s.points.map {
                PersonBrief.Point(text: $0.text, callID: ids.contains($0.call_id) ? $0.call_id : nil)
            })
        }
        return PersonBrief(headline: out.headline, sections: Array(sections), calls: shared.count, updated: now)
    }

    private func system(_ name: String) -> String {
        let first = name.split(separator: " ").first.map(String.init) ?? name
        return """
        You are \(ownerName)'s communication coach. Write your read on \(name), from \(ownerName)'s calls with them, \
        so \(ownerName) can work with \(first) better. headline: one sentence, at most 15 words, on the best way to \
        work with \(first) now. Then 3 to 6 sections you choose for this person. Try these first, when the calls \
        support them: "Goals" (what \(first) is trying to achieve), "How to communicate with them" (what lands: \
        format, order, timing, level of detail), "How they communicate" (their style: direct, detailed, quiet, \
        fast to decide). Add others only when they are worth knowing, with a short title of your own, such as \
        "What they care about", "Watch out for", "Decides on", or "Worth knowing". Each section has 1 to 3 points, \
        each one sentence of at most 25 words, concrete and specific to \(first), never generic advice. call_id is \
        the call a point came from, exactly as listed, or "" when it comes from several. Only what the calls show; \
        never judge character. When an earlier read is given, keep what still holds and change what the new calls \
        change.
        """
    }

    private func user(_ name: String, _ calls: [CallRecord], profile: CoachProfile) -> String {
        let first = name.split(separator: " ").first.map(String.init) ?? name
        var parts: [String] = []
        let known = profile.facts.filter { $0.text.localizedCaseInsensitiveContains(first) }.map { "- \($0.text)" }
        if !known.isEmpty { parts.append("## What \(ownerName) confirmed\n" + known.joined(separator: "\n")) }
        let denied = profile.questions.filter { $0.status == .rejected && $0.statement.localizedCaseInsensitiveContains(first) }
        if !denied.isEmpty { parts.append("## Not true\n" + denied.map { "- \($0.statement)" }.joined(separator: "\n")) }
        if let person = profile.people[name] {
            if let note = person.note.nonBlank { parts.append("## Your note on \(first)\n" + note) }
            if let brief = person.brief { parts.append("## Your earlier read\n" + brief.text) }
        }
        parts.append("## Calls with \(name), newest first\n" + calls.map { r in
            let others = Set(r.speakerNames.values).subtracting([ownerName, name]).sorted()
            var block = "call_id: \(r.id) | \(r.start.formatted(.dateTime.month(.abbreviated).day())) | \(r.title)"
            if !others.isEmpty { block += " | also: \(others.joined(separator: ", "))" }
            if let s = r.summary { block += "\n" + String(s.prefix(Self.summaryCharacters)) }
            let keys = Set(r.speakerNames.filter { $0.value == name }.keys)
            let lines = r.utterances.filter { keys.contains($0.speakerKey) }.sorted { $0.text.count > $1.text.count }.prefix(Self.maxLines)
                .sorted { $0.start < $1.start }.map { "- " + String($0.text.prefix(Self.lineCharacters)) }
            if !lines.isEmpty { block += "\nTheir words:\n" + lines.joined(separator: "\n") }
            return block
        }.joined(separator: "\n\n"))
        return parts.joined(separator: "\n\n")
    }

    static var schema: [String: Any] {
        Schema.object([
            "headline": Schema.string,
            "sections": Schema.array(Schema.object([
                "title": Schema.string,
                "points": Schema.array(Schema.object(["text": Schema.string, "call_id": Schema.string])),
            ])),
        ])
    }

    private struct Output: Decodable {
        let headline: String
        let sections: [SectionOut]
    }

    private struct SectionOut: Decodable {
        let title: String
        let points: [PointOut]
    }

    private struct PointOut: Decodable {
        let text, call_id: String
    }
}
