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
    /// The prompt's version; a read in an older style is written again at once. Nil in reads from style 1.
    public var style: Int?

    /// 2: general ways to engage the person, not their current tasks, and short.
    public static let currentStyle = 2

    public init(headline: String, sections: [Section], calls: Int, updated: Date) {
        self.headline = headline
        self.sections = sections
        self.calls = calls
        self.updated = updated
        style = Self.currentStyle
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
    /// Short enough to read before a call.
    public static let maxSections = 4
    public static let maxPoints = 2

    private let llm: any LanguageModel
    private let ownerName: String

    public init(llm: any LanguageModel, ownerName: String) {
        self.llm = llm
        self.ownerName = ownerName
    }

    /// People with a call since their brief (or no brief yet), and no brief written in the last day, most
    /// recent first. The owner is one of them: their read is how other people can best work with them.
    public static func due(profile: CoachProfile, records: [CallRecord], owner: String, now: Date = Date(), saved: CoachPeople = .none) -> [String] {
        var latest: [String: Date] = [:], count: [String: Int] = [:]
        for r in records where r.status == .written {
            for name in Set(r.speakerNames.values) where !name.hasPrefix("Speaker ") && !name.contains(":") {
                latest[name] = max(latest[name] ?? r.end, r.end)
                count[name, default: 0] += 1
            }
        }
        let off = saved.notProfiled
        return latest.filter { name, last in
            guard (count[name] ?? 0) >= minimumCalls else { return false }
            // No read of a person who keeps none.
            if let id = saved.id(of: name), off.contains(saved.canonical(id)) { return false }
            guard let brief = profile.note(on: name, people: saved)?.value.brief else { return true }
            if (brief.style ?? 1) < PersonBrief.currentStyle { return true }
            return last > brief.updated && now.timeIntervalSince(brief.updated) >= minimumGap
        }
        .sorted { $0.value > $1.value }.prefix(perRun).map(\.key)
    }

    /// `saved` are the saved people: with them, the note and what the owner confirmed about this person are read
    /// by the person's id, under any name.
    public func brief(for name: String, records: [CallRecord], profile: CoachProfile, now: Date = Date(), saved: CoachPeople = .none) async throws -> PersonBrief {
        let shared = records.filter { $0.status == .written && $0.speakerNames.values.contains(name) }.sorted { $0.start > $1.start }
        let used = Array(shared.prefix(Self.maxCalls))
        let ids = Set(used.map(\.id))
        let out = try await llm.json(system: system(name), user: user(name, used, profile: profile, saved: saved), schema: Self.schema,
                                     effort: .medium, purpose: .coach, as: Output.self)
        let sections = out.sections.prefix(Self.maxSections).map { s in
            PersonBrief.Section(title: s.title, points: s.points.prefix(Self.maxPoints).map {
                PersonBrief.Point(text: $0.text, callID: ids.contains($0.call_id) ? $0.call_id : nil)
            })
        }
        return PersonBrief(headline: out.headline, sections: Array(sections), calls: shared.count, updated: now)
    }

    private func system(_ name: String) -> String {
        if name == ownerName { return ownerSystem }
        let first = name.split(separator: " ").first.map(String.init) ?? name
        return """
        You are \(ownerName)'s communication coach. Write your current understanding of how best to interact with \
        \(name): their working style and general expectations, as they show across \(ownerName)'s calls with them. \
        This is about the person, not the tasks: never describe what \(first) is working on, a project, a number, \
        or a deadline, except as a brief example in parentheses. Write what will still be true next month.
        headline: the best way to work with \(first), at most 12 words.
        sections: 2 to 4, in this order, only when the calls support them: "How to engage them" (what lands: \
        format, order, level of detail, timing), "How they engage" (their style: direct, detailed, quiet, quick \
        to decide, how they push back), "What they expect" (from \(ownerName): follow-through, preparation, \
        updates), and "Watch out for" only when there is something real. Each section has 1 or 2 points, each at \
        most 18 words. Fewer, sharper points beat many.
        call_id is the call that shows a point best, exactly as listed, or "" when it shows across several. Never \
        judge character. Refer to the person by first name or as "they"; never guess their pronouns. When an earlier read is given, keep what still holds and change what the new calls change.
        """
    }

    /// The same read, about the owner, as the coach would give someone who asked how to work with them.
    private var ownerSystem: String {
        let first = ownerName.split(separator: " ").first.map(String.init) ?? ownerName
        return """
        You are \(ownerName)'s communication coach. Someone who works with \(ownerName) asks you how best to work \
        with them. Write your current understanding of \(first)'s working style and general expectations, as they \
        show across their calls. This is about the person, not the tasks: never describe what \(first) is working \
        on, a project, a number, or a deadline, except as a brief example in parentheses. Write what will still be \
        true next month, in the third person.
        headline: the best way to work with \(first), at most 12 words.
        sections: 2 to 4, in this order, only when the calls support them: "How to engage them" (what lands with \
        \(first): format, order, level of detail, timing), "How they engage" (their style: direct, detailed, quiet, \
        quick to decide, how they push back), "What they expect" (from the people they work with: follow-through, \
        preparation, updates), and "Watch out for" only when there is something real. Each section has 1 or 2 \
        points, each at most 18 words. Fewer, sharper points beat many.
        call_id is the call that shows a point best, exactly as listed, or "" when it shows across several. Never \
        judge character. Refer to the person by first name or as "they"; never guess their pronouns. When an earlier read is given, keep what still holds and change what the new calls change.
        """
    }

    private func user(_ name: String, _ calls: [CallRecord], profile: CoachProfile, saved: CoachPeople) -> String {
        let first = name.split(separator: " ").first.map(String.init) ?? name
        var parts: [String] = []
        if name == ownerName {
            if let summary = profile.summary.nonBlank { parts.append("## Your coaching profile of \(first)\n" + summary) }
            if !profile.patterns.isEmpty {
                parts.append("## Patterns you track\n" + profile.patterns.map { "- \($0.name): \($0.note)" }.joined(separator: "\n"))
            }
            let facts = profile.facts.map { "- \($0.text)" }
            if !facts.isEmpty { parts.append("## What \(first) told you\n" + facts.joined(separator: "\n")) }
            if let brief = profile.people[name]?.brief { parts.append("## Your earlier read\n" + brief.text) }
            parts.append(callsText(name, calls))
            return parts.joined(separator: "\n\n")
        }
        // What names them, and what is theirs by the person's id, whatever name the words use.
        let id = saved.id(of: name)
        let theirs = id.map { profile.learnings(about: $0, people: saved) } ?? []
        let known = profile.facts.filter { $0.text.localizedCaseInsensitiveContains(first) || theirs.contains($0) }.map { "- \($0.text)" }
        if !known.isEmpty { parts.append("## What \(ownerName) confirmed\n" + known.joined(separator: "\n")) }
        let told = id.map { profile.guidance(about: $0, people: saved) } ?? []
        if !told.isEmpty { parts.append("## What \(ownerName) told you about them\n" + told.map { "- \($0.text)" }.joined(separator: "\n")) }
        let denied = profile.questions.filter { $0.status == .rejected && $0.statement.localizedCaseInsensitiveContains(first) }
        if !denied.isEmpty { parts.append("## Not true\n" + denied.map { "- \($0.statement)" }.joined(separator: "\n")) }
        if let person = profile.note(on: name, people: saved)?.value {
            if let note = person.note.nonBlank { parts.append("## Your note on \(first)\n" + note) }
            if let brief = person.brief { parts.append("## Your earlier read\n" + brief.text) }
        }
        parts.append(callsText(name, calls))
        return parts.joined(separator: "\n\n")
    }

    private func callsText(_ name: String, _ calls: [CallRecord]) -> String {
        "## Calls \(name == ownerName ? "of" : "with") \(name), newest first\n" + calls.map { r in
            let others = Set(r.speakerNames.values).subtracting([ownerName, name]).sorted()
            var block = "call_id: \(r.id) | \(r.start.formatted(.dateTime.month(.abbreviated).day())) | \(r.title)"
            if !others.isEmpty { block += " | also: \(others.joined(separator: ", "))" }
            if let s = r.summary { block += "\n" + String(s.prefix(Self.summaryCharacters)) }
            let keys = Set(r.speakerNames.filter { $0.value == name }.keys)
            let lines = r.utterances.filter { keys.contains($0.speakerKey) }.sorted { $0.text.count > $1.text.count }.prefix(Self.maxLines)
                .sorted { $0.start < $1.start }.map { "- " + String($0.text.prefix(Self.lineCharacters)) }
            if !lines.isEmpty { block += "\nTheir words:\n" + lines.joined(separator: "\n") }
            return block
        }.joined(separator: "\n\n")
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
