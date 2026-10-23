import Foundation

/// The tools beyond the meetings themselves: the coach's reviews and memory, people, the period's numbers,
/// what to remember about the owner, and earlier chats.
extension ChatTools {
    public static var coachDefinitions: [ToolSpec] { [
        ToolSpec(name: "coach_profile",
                 description: "What the communication coach knows about the owner: role, responsibilities, goals, relationships, coaching preferences, current focus, patterns with trends, notes on people, and the owner's recent ratings of the coach's advice.",
                 schema: ["type": "object", "properties": [:] as [String: Any]]),
        ToolSpec(name: "coach_reviews",
                 description: "Lists the coach's reviews of meetings, newest first: call_id, title, date, score out of 5 with its reason, meeting value, and the key positive (+) and negative (-) points. Filter by people and dates (YYYY-MM-DD).",
                 schema: ["type": "object", "properties": [
                    "people": ["type": "array", "items": ["type": "string"]], "from": ["type": "string"], "to": ["type": "string"], "limit": ["type": "integer"],
                 ] as [String: Any]]),
        ToolSpec(name: "read_coach_review",
                 description: "Reads one meeting's full coach review: scorecard, strengths and improvements with quotes and what to say instead, meeting value, delivery numbers (pace, fillers, talk share, interruptions, voice), and the owner's own ratings and conversation with the coach.",
                 schema: ["type": "object", "properties": ["call_id": ["type": "string"]], "required": ["call_id"]]),
        ToolSpec(name: "people",
                 description: "The people the owner meets with: meetings together, time, when last seen, and the coach's note on how to work with each. Filter by a name.",
                 schema: ["type": "object", "properties": ["query": ["type": "string"], "limit": ["type": "integer"]] as [String: Any]]),
        ToolSpec(name: "stats",
                 description: "The numbers for a period (YYYY-MM-DD, default the last 30 days): calls, hours, average length, talk share, scheduled share, meeting value, top topics and people, delivery trends, and API cost.",
                 schema: ["type": "object", "properties": ["from": ["type": "string"], "to": ["type": "string"]] as [String: Any]]),
        ToolSpec(name: "remember",
                 description: "Saves something lasting about the owner for every later chat and coach review. kind is role, responsibility, goal, relationship, or preference (how they want to be coached or answered). Use it when they tell you something that should change future advice; tell them you saved it.",
                 schema: ["type": "object", "properties": [
                    "kind": ["type": "string", "enum": ["role", "responsibility", "goal", "relationship", "preference"]], "text": ["type": "string"],
                 ] as [String: Any], "required": ["kind", "text"]]),
        ToolSpec(name: "commitments",
                 description: "What the owner personally promised in meetings (separate from action items), with who it was promised to, the meeting and moment, the due date, and whether it is done or overdue. status is open (default), overdue, done, or all. Filter by a person.",
                 schema: ["type": "object", "properties": [
                    "status": ["type": "string", "enum": ["open", "overdue", "done", "all"]], "person": ["type": "string"], "limit": ["type": "integer"],
                 ] as [String: Any]]),
        ToolSpec(name: "past_chats",
                 description: "Earlier conversations with the owner, newest first, with their summaries. Filter by words.",
                 schema: ["type": "object", "properties": ["query": ["type": "string"], "limit": ["type": "integer"]] as [String: Any]]),
        ToolSpec(name: "read_chat",
                 description: "Reads one earlier conversation in full.",
                 schema: ["type": "object", "properties": ["chat_id": ["type": "string"]], "required": ["chat_id"]]),
    ] }

    var profile: CoachProfile { paths.flatMap { try? CoachProfile.load(from: $0.coach) } ?? CoachProfile() }

    var chats: [Chat] { paths.map { ChatStore(directory: $0.chats).all() } ?? [] }

    private func review(_ id: String) -> CoachReview? { paths.flatMap { CoachReview.load(in: $0.callDirectory(id)) } }

    func runCoachTool(_ name: String, input: [String: Any], from: Date?, to: Date?, people: [String], limit: Int) -> String? {
        guard let paths else { return name.hasPrefix("coach") || ["people", "stats", "remember", "past_chats", "read_chat", "read_coach_review", "commitments"].contains(name) ? "Not available here." : nil }
        switch name {
        case "coach_profile": return coachProfileText()
        case "coach_reviews":
            let lines = findMeetings(people: people, from: from, to: to, limit: Self.maxLimit * 10).compactMap { r -> String? in
                guard let v = review(r.id) else { return nil }
                var line = "call_id: \(r.id) | \(r.title) | \(r.start.formatted(.dateTime.month(.abbreviated).day().year()))"
                if let c = v.scorecard { line += " | \(c.score)/5: \(c.reason)" }
                if let value = v.value { line += " | value \(value.rating.rawValue)" }
                if let c = v.scorecard { line += (c.positives.map { "\n  + \($0)" } + c.negatives.map { "\n  - \($0)" }).joined() } else { line += " | \(v.headline)" }
                if v.scorecard == nil {
                    let l = v.lines
                    line += [l.didWell.map { "\n  Did well: \($0.text)" }, l.improving.map { "\n  Improving: \($0.text)" },
                             l.tryNext.map { "\n  Try next: \($0.text)" }, v.focusResult.map { "\n  Focus: \($0.outcome.rawValue). \($0.evidence)" }]
                        .compactMap { $0 }.joined()
                }
                return line
            }.prefix(min(limit, Self.maxLimit))
            return lines.isEmpty ? "No coach reviews match." : lines.joined(separator: "\n")
        case "read_coach_review":
            guard let id = input["call_id"] as? String, let v = review(id) else { return "No coach review for that call_id." }
            return reviewText(v, title: records.first { $0.id == id }?.title ?? id)
        case "people": return peopleText(query: input["query"] as? String, limit: limit)
        case "commitments": return commitmentsText(status: input["status"] as? String ?? "open", person: input["person"] as? String, limit: limit)
        case "stats":
            let end = to ?? Date(), start = from ?? end.addingTimeInterval(-30 * 86_400)
            return statsText(DateInterval(start: start, end: max(start, end)), usage: UsageLog(directory: paths.usage).all())
        case "remember":
            guard let raw = input["kind"] as? String, let text = (input["text"] as? String)?.nonBlank else { return "Nothing to remember." }
            var profile = self.profile
            if raw == "preference" {
                profile.updateGuidance(add: [text], remove: [], at: Date())
            } else if let kind = CoachFact.Kind(rawValue: raw) {
                profile.updateFacts(add: [CoachFact(kind: kind, text: text)], remove: [])
            } else {
                return "Unknown kind \(raw)."
            }
            do { try profile.save(to: paths.coach) } catch { return "Could not save: \(error)" }
            return "Remembered (\(raw)): \(text)"
        case "past_chats":
            let q = (input["query"] as? String)?.lowercased()
            let list = chats.filter { c in
                guard let q else { return true }
                return c.title.lowercased().contains(q) || (c.summary ?? "").lowercased().contains(q) || c.messages.contains { m in m.text.lowercased().contains(q) }
            }.prefix(min(limit, Self.maxLimit))
            return list.isEmpty ? "No earlier chats match." : list.map {
                "chat_id: \($0.id.uuidString) | \($0.updated.formatted(.dateTime.month(.abbreviated).day())) | \($0.title)" + ($0.summary.map { " | \($0)" } ?? "")
            }.joined(separator: "\n")
        case "read_chat":
            guard let id = (input["chat_id"] as? String).flatMap(UUID.init(uuidString:)), let chat = chats.first(where: { $0.id == id }) else {
                return "No chat with that chat_id."
            }
            return "\(chat.title)\n" + chat.messages.map { "\($0.role == .user ? owner : "You"): \($0.text)" }.joined(separator: "\n\n")
        default: return nil
        }
    }

    func coachProfileText() -> String {
        let p = profile
        var parts: [String] = []
        for kind in CoachFact.Kind.allCases where !p.facts(kind).isEmpty {
            parts.append("\(kind.title):\n" + p.facts(kind).map { "- \($0.text)" }.joined(separator: "\n"))
        }
        if !p.guidance.isEmpty { parts.append("Coaching preferences:\n" + p.guidance.map { "- \($0.text)" }.joined(separator: "\n")) }
        if let s = p.summary.nonBlank { parts.append("How they communicate: \(s)") }
        if let f = p.activeFocus {
            let hits = f.chances.filter { $0.outcome == .hit }.count
            parts.append("Current focus, agreed by the owner: \(f.plan) (why: \(f.why)). \(hits) hits in \(f.chances.count) chances so far.")
        } else if let f = p.proposedFocus {
            parts.append("Proposed focus, waiting for the owner to accept: \(f.plan)")
        } else if let f = p.focus.nonBlank {
            parts.append("Current focus: \(f)")
        }
        let learned = p.foci.filter { $0.status == .learned }.map(\.plan)
        if !learned.isEmpty { parts.append("Learned habits: " + learned.joined(separator: "; ")) }
        if !p.patterns.isEmpty {
            parts.append("Patterns:\n" + p.patterns.map { "- \($0.name) (\($0.kind.rawValue), \($0.trend.rawValue), seen in \($0.seen) calls): \($0.note)" }.joined(separator: "\n"))
        }
        if !p.people.isEmpty {
            parts.append("Notes on people:\n" + p.people.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value.note)" }.joined(separator: "\n"))
        }
        if !p.rated.isEmpty {
            parts.append("Their recent ratings of the coach's points:\n" + p.rated.suffix(15).map {
                "- \($0.agree ? "Right" : "Wrong"): \($0.title) (\($0.callTitle))" + ($0.note.map { ". They said: \($0)" } ?? "")
            }.joined(separator: "\n"))
        }
        let scored = p.history.compactMap { h in h.score.map { (h, $0) } }
        if !scored.isEmpty {
            parts.append("Recent scores: " + scored.suffix(10).map { "\($0.0.title) \($0.1)/5" }.joined(separator: ", "))
        }
        return parts.isEmpty ? "The coach has no notes yet." : parts.joined(separator: "\n\n")
    }

    func commitmentsText(status: String, person: String?, limit: Int) -> String {
        guard let paths, let book = try? CommitmentBook.load(from: paths.commitments) else { return "No commitments yet." }
        let now = Date()
        let list = book.visible.filter { c in
            let s = c.status(now: now)
            let keep = switch status {
            case "all": true
            case "done": s == .done
            case "overdue": s == .overdue
            default: s != .done
            }
            return keep && (person.map { p in (c.to ?? "").localizedCaseInsensitiveContains(p) || (c.callTitle ?? "").localizedCaseInsensitiveContains(p) } ?? true)
        }
        .sorted { ($0.due ?? .distantFuture, $0.madeAt) < ($1.due ?? .distantFuture, $1.madeAt) }
        .prefix(max(limit, 30))
        guard !list.isEmpty else { return "No commitments match." }
        let day = Date.FormatStyle().year().month(.abbreviated).day()
        return list.map { c in
            var line = "- \(c.text)"
            if let to = c.to { line += " (to \(to))" }
            line += c.done.map { " | done \($0.formatted(day))" } ?? (c.due.map { " | due \($0.formatted(day))" + (c.status(now: now) == .overdue ? ", overdue" : "") } ?? " | no date")
            if let id = c.callID { line += " | made in call_id \(id)" + (c.callTitle.map { " (\($0))" } ?? "") + (c.at.map { " at \(Int($0)) s" } ?? "") }
            return line
        }.joined(separator: "\n")
    }

    func reviewText(_ v: CoachReview, title: String) -> String {
        var parts = ["\(title): \(v.headline)"] + [v.overview].compactMap(\.nonBlank)
        let l = v.lines
        if let n = l.didWell { parts.append("Did well: \(n.text)" + (n.quote.map { " Quote: \"\($0)\"" } ?? "")) }
        if let n = l.improving { parts.append("Improving: \(n.text)") }
        if let n = l.tryNext { parts.append("Try next time: \(n.text)" + (n.say.map { " Say: \"\($0)\"" } ?? "")) }
        if let r = v.focusResult { parts.append("Focus result: \(r.outcome.rawValue). \(r.evidence)") }
        if let c = v.scorecard {
            parts.append("Score \(c.score)/5: \(c.reason). " + c.dimensions.map { "\($0.name) \($0.score)" }.joined(separator: ", "))
        }
        if let value = v.value { parts.append("Meeting value \(value.rating.rawValue) (\(value.action.rawValue)): \(value.reason) \(value.suggestion)") }
        if let p = v.focusProgress { parts.append("Focus: \(p)") }
        func points(_ label: String, _ list: [CoachPoint]) -> [String] {
            list.map { p in
                var line = "\(label) \(p.title) [\(p.principle)]: \(p.observation) Quote: \"\(p.quote)\""
                if let t = p.tryInstead { line += " Try: \(t)" }
                if let f = v.feedback[p.title] { line += " — owner rated this \(f.agree ? "right" : "wrong")\(f.note.map { ": \($0)" } ?? "")" }
                return line
            }
        }
        parts += points("Strength:", v.strengths) + points("Improve:", v.improvements)
        if let d = v.delivery { parts.append("Delivery: \(CoachPrompt.numbers(d))") }
        if !v.thread.isEmpty {
            parts.append("Owner's conversation with the coach:\n" + v.thread.map { "\($0.role == .user ? owner : "Coach"): \($0.text)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }

    func peopleText(query: String?, limit: Int) -> String {
        let stats = PersonStatistics.compute(records)
        let notes = profile.people
        let names = stats.keys.filter { name in
            name != owner && !name.hasPrefix("Speaker ") && (query.map { q in Self.name(q, matches: name) } ?? true)
        }
            .sorted { (stats[$0]?.meetings.count ?? 0, $1) > (stats[$1]?.meetings.count ?? 0, $0) }
        guard !names.isEmpty else { return "No people match." }
        return names.prefix(min(limit, Self.maxLimit)).map { name in
            let s = stats[name]!
            var line = "\(name) | \(s.meetings.count) meetings | talked \(Int(s.totalTalk / 60)) min"
            if let last = s.lastHeard { line += " | last \(last.formatted(.dateTime.month(.abbreviated).day()))" }
            if let note = notes[name]?.note { line += " | coach: \(note)" }
            return line
        }.joined(separator: "\n")
    }

    func statsText(_ interval: DateInterval, usage: [UsageEvent]) -> String {
        let reviews = Dictionary(uniqueKeysWithValues: records.compactMap { r in review(r.id).map { (r.id, $0) } })
        let r = AnalyticsReport(records: records, usage: usage, owner: owner, interval: interval, reviews: reviews)
        var lines = ["\(r.calls) call\(r.calls == 1 ? "" : "s"), \(Int(r.callSeconds / 3600))h \(Int(r.callSeconds / 60) % 60)m in calls, average \(Int(r.averageSeconds / 60)) min, \(String(format: "%.1f", r.callsPerDay)) a day"]
        if let share = r.talkShare { lines.append("Talk share \(Int(share * 100))%") }
        lines.append("Scheduled \(r.scheduled.calls), unscheduled \(r.unscheduled.calls)")
        if !r.valueSeconds.isEmpty { lines.append("Meeting value hours: " + r.valueSeconds.map { "\($0.key.rawValue) \(Int($0.value / 360) / 10)" }.joined(separator: ", ")) }
        if !r.tags.isEmpty { lines.append("Top topics: " + r.tags.prefix(8).map { "\($0.name) \(Int($0.seconds / 60))m" }.joined(separator: ", ")) }
        if !r.people.isEmpty { lines.append("Most time with: " + r.people.prefix(8).map { "\($0.name) \(Int($0.seconds / 60))m" }.joined(separator: ", ")) }
        if !r.delivery.isEmpty {
            lines.append("Pace " + r.delivery.map { "\(Int($0.wordsPerMinute))" }.joined(separator: ", ") + " wpm; fillers " + r.delivery.map { String(format: "%.1f", $0.fillersPerMinute) }.joined(separator: ", ") + " per min")
        }
        lines.append(String(format: "API cost $%.2f", r.cost.total))
        return lines.joined(separator: "\n")
    }
}
