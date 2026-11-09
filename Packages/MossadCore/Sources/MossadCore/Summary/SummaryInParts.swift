import Foundation

/// A model with a small context: one request when the meeting fits, otherwise each part is summarized with the
/// same schema and the parts' notes are combined into one summary of the same shape.
extension LLMSummarizer {
    static let combineRule = """


    The meeting was too long to read at once, so you get notes on each part, in order, in place of the \
    transcript. Combine them into the notes for the whole meeting: one overview of the whole call, the topics \
    merged and in the order they came up, and every action item and decision from the parts.
    """

    static func partPrompt(part: Int, of count: Int, knownTags: [String], title: String, transcript: String, people: [String]) -> String {
        "Part \(part) of \(count) of a longer meeting. Summarize only this part; the other parts are summarized separately. "
            + "The times are from the start of the whole meeting.\n\n"
            + userPrompt(knownTags: knownTags, title: title, transcript: transcript, people: people)
    }

    static func combinePrompt(knownTags: [String], title: String, notes: [String], people: [String]) -> String {
        let known = knownTags.isEmpty ? "" : "Known tags: \(knownTags.joined(separator: ", "))\n\n"
        let titles = people.isEmpty ? "" : "Job titles of people in the meeting:\n" + people.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        return "\(known)\(titles)Meeting: \(title)\n\nNotes on each part:\n\n" + notes.joined(separator: "\n\n")
    }

    /// One part's notes as plain text, for the combine step.
    static func noteText(_ o: Output, label: String) -> String {
        var lines = ["\(label):", "Summary: \(o.summary)", "Headline: \(o.headline)", "Kind: \(o.kind)"]
        if !o.topics.isEmpty { lines += ["Topics:"] + o.topics.map { "- \($0.title): \($0.summary)" } }
        if !o.action_items.isEmpty { lines += ["Action items:"] + o.action_items.map { "- \($0.text)" } }
        if !o.decisions.isEmpty {
            lines += ["Decisions:"] + o.decisions.map { d in "- \(d.text)" + (d.at_seconds.map { " (at_seconds \(Int($0)))" } ?? "") }
        }
        if let tags = o.tags, !tags.isEmpty { lines.append("Tags: \(tags.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    func summarizeInParts(_ model: any ContextLimitedModel, system: String, transcript: String, title: String,
                          knownTags: [String], people: [String]) async throws -> Output {
        let context = await model.contextTokens()
        let reply = ChunkPlanner.replyReserve(context: context)
        let schemaTokens = await model.tokenCount(JSONRepair.instructions(Self.schema))
        let systemTokens = await model.tokenCount(system) + schemaTokens
        let whole = Self.userPrompt(knownTags: knownTags, title: title, transcript: transcript, people: people)
        let wholeTokens = await model.tokenCount(whole)
        if systemTokens + wholeTokens + reply <= context {
            return try await model.json(system: system, user: whole, schema: Self.schema, effort: .medium, purpose: .summary, as: Output.self)
        }

        // Counted once, then each line estimated at the same rate with a margin, so planning stays cheap.
        let measured = await model.tokenCount(transcript)
        let rate = Double(measured) / Double(max(1, transcript.utf8.count)) * 1.1
        let count: (String) -> Int = { Int((Double($0.utf8.count) * rate).rounded(.up)) + 1 }
        let header = await model.tokenCount(Self.partPrompt(part: 99, of: 99, knownTags: knownTags, title: title, transcript: "", people: people))
        let budget = ChunkPlanner.budget(context: context, fixed: systemTokens + header, reply: reply)
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let parts = ChunkPlanner.plan(lines, budget: budget, tokens: count)
        Log.info("Summarizing a long meeting in \(parts.count) parts of at most \(budget) tokens (context \(context))")

        var notes: [Output] = []
        for (i, part) in parts.enumerated() {
            let user = Self.partPrompt(part: i + 1, of: parts.count, knownTags: knownTags, title: title,
                                       transcript: part.joined(separator: "\n"), people: people)
            notes.append(try await model.json(system: system, user: user, schema: Self.schema, effort: .medium, purpose: .summary, as: Output.self))
        }
        let combined = try await combine(notes, model: model, system: system + Self.combineRule, context: context, reply: reply,
                                         schemaTokens: schemaTokens, count: count, title: title, knownTags: knownTags, people: people)
        return Self.merged(combined, parts: notes)
    }

    /// Combines the notes in one request when they fit, otherwise in groups, again and again, until one is left.
    private func combine(_ notes: [Output], model: any ContextLimitedModel, system: String, context: Int, reply: Int, schemaTokens: Int,
                         count: (String) -> Int, title: String, knownTags: [String], people: [String]) async throws -> Output {
        let fixed = await model.tokenCount(system) + schemaTokens
        var level = notes
        var round = 0
        while true {
            round += 1
            let blocks = level.enumerated().map { Self.noteText($1, label: "Part \($0 + 1)") }
            let user = Self.combinePrompt(knownTags: knownTags, title: title, notes: blocks, people: people)
            let size = await model.tokenCount(user)
            if level.count <= 2 || fixed + size + reply <= context {
                return try await model.json(system: system, user: user, schema: Self.schema, effort: .medium, purpose: .summary, as: Output.self)
            }
            let header = await model.tokenCount(Self.combinePrompt(knownTags: knownTags, title: title, notes: [], people: people))
            var groups = ChunkPlanner.plan(blocks, budget: ChunkPlanner.budget(context: context, fixed: fixed + header, reply: reply), tokens: count)
            // Notes that will not pack go in pairs, so each round makes fewer.
            if groups.count >= level.count { groups = stride(from: 0, to: blocks.count, by: 2).map { Array(blocks[$0..<min($0 + 2, blocks.count)]) } }
            var next: [Output] = []
            var start = 0
            for group in groups {
                let members = Array(level[start..<start + group.count])
                start += group.count
                if members.count == 1 { next.append(members[0]); continue }
                let groupUser = Self.combinePrompt(knownTags: knownTags, title: title,
                                                   notes: members.enumerated().map { Self.noteText($1, label: "Part \($0 + 1)") }, people: people)
                next.append(try await model.json(system: system, user: groupUser, schema: Self.schema, effort: .medium, purpose: .summary, as: Output.self))
            }
            Log.info("Combined \(level.count) part summaries into \(next.count) (round \(round))")
            level = next
        }
    }

    /// The combined notes. The combine step merges the parts' action items and decisions, repeats included; when
    /// it drops all of them, the parts' own lists come back, once each.
    static func merged(_ combined: Output, parts: [Output]) -> Output {
        var seenItems = Set<String>(), seenDecisions = Set<String>(), seenTags = Set<String>()
        var items = combined.action_items, decisions = combined.decisions
        if items.isEmpty {
            items = parts.flatMap(\.action_items).filter { seenItems.insert($0.task.lowercased().trimmingCharacters(in: .whitespaces)).inserted }
        }
        if decisions.isEmpty {
            decisions = parts.flatMap(\.decisions).filter { seenDecisions.insert($0.text.lowercased().trimmingCharacters(in: .whitespaces)).inserted }
        }
        var tags = combined.tags ?? []
        if tags.isEmpty { tags = Array(parts.flatMap { $0.tags ?? [] }.filter { seenTags.insert($0.lowercased()).inserted }.prefix(5)) }
        return Output(summary: combined.summary, topics: combined.topics, action_items: items, decisions: decisions,
                      headline: combined.headline, kind: combined.kind,
                      has_outcomes: combined.has_outcomes || !items.isEmpty || !decisions.isEmpty, tags: tags, title: combined.title)
    }
}
