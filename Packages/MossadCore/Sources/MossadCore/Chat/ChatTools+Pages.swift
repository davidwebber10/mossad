import Foundation

/// The other pages, read as the app shows them: bookmarks, a meeting's Analytics tab, the coach's deck and goals,
/// the share links (never a token, a link, or a PIN), and the app's own state (never a key).
extension ChatTools {
    static var pageDefinitions: [ToolSpec] { [
        ToolSpec(name: "bookmarks",
                 description: "The owner's bookmarks across meetings, newest meeting first: call_id, the moment (at_seconds), the owner's note, and what was being said then. query narrows by words of the note, the line, or the meeting's title; call_id narrows to one meeting.",
                 schema: ["type": "object", "properties": ["query": ["type": "string"], "call_id": ["type": "string"], "limit": ["type": "integer"]] as [String: Any]]),
        ToolSpec(name: "meeting_analytics",
                 description: "One meeting's Analytics tab: each speaker's talk time and share, turns, pace, fillers, questions, cut-ins made and received, and reply times; who invited came and spoke; decisions and action items by owner; the coach's rating; shared screens by presenter; the cost; and what stood out against the owner's earlier meetings. A number the call cannot give is \"not known\", never 0.",
                 schema: ["type": "object", "properties": ["call_id": ["type": "string"]] as [String: Any], "required": ["call_id"]]),
        ToolSpec(name: "coach_findings",
                 description: "The coach's cards that wait for the owner's answer in Findings (the newest calls first, at most 10, each gone 14 days after its call): what the owner did well, missed, or could do better, a conclusion to confirm, a goal offer, or how a person thinks; each with its call_id, the moment, the quote or the number with its usual value, why it matters, and the question it asks. call_id gives one call's cards.",
                 schema: ["type": "object", "properties": ["call_id": ["type": "string"]] as [String: Any]]),
        ToolSpec(name: "coach_goals",
                 description: "The owner's coaching goal as the Goals page shows it: the goal (active, or offered and waiting), why, the target and what was usual before, the progress sentence over the 1:1s since it began, each call's result with its moment, and the goals learned, ended, or not taken.",
                 schema: ["type": "object", "properties": [:] as [String: Any]]),
    ] }

    static var macPageDefinitions: [ToolSpec] {
        #if os(macOS)
        [
            ToolSpec(name: "shares",
                     description: "The owner's share links of meetings: the meeting (call_id), when it was made, when it expires in words, whether it has a PIN, and whether it still works. Never the link, its token, or the PIN; the view counts are on the Shares page.",
                     schema: ["type": "object", "properties": ["limit": ["type": "integer"]] as [String: Any]]),
            ToolSpec(name: "app_status",
                     description: "How Mossad is set up on this Mac: its version, the transcription and notes providers and models by name, and what is on (the coach, its reads of how people think and whether other AI apps get them, the live transcript, shared screen capture, voice recognition, sync, the recording backup, the coach's email, and which Google parts). Never a key, a secret, or an address. Use it to explain why something is missing.",
                     schema: ["type": "object", "properties": [:] as [String: Any]]),
        ]
        #else
        []
        #endif
    }

    // MARK: Bookmarks

    func bookmarksText(_ input: [String: Any]) -> String {
        let limit = min(input["limit"] as? Int ?? Self.defaultLimit * 2, Self.maxLimit)
        var list = records
        if let id = (input["call_id"] as? String)?.nonBlank { list = list.filter { $0.id == id } }
        let groups = BookmarkIndex.groups(list, query: (input["query"] as? String) ?? "")
        guard !groups.isEmpty else { return "No bookmarks match." }
        var lines: [String] = []
        for g in groups {
            for b in g.bookmarks {
                guard lines.count < limit else { break }
                var line = "call_id: \(g.callID) | \(g.title) | \(shortDay(g.start)) | at_seconds: \(Int(b.offset)) [\(MarkdownWriter.timestamp(b.offset))]"
                if let note = b.note { line += " | note: \(note)" }
                if let said = b.said { line += " | \(said.speaker): \(said.text)" }
                lines.append(line)
            }
        }
        let total = BookmarkIndex.count(groups)
        return lines.joined(separator: "\n") + (total > lines.count ? "\n(\(total - lines.count) more.)" : "")
    }

    // MARK: A meeting's Analytics tab

    func meetingAnalyticsText(_ input: [String: Any]) -> String {
        guard let r = records.first(where: { $0.id == (input["call_id"] as? String) }) else { return "No meeting with that call_id." }
        let usage: (events: [UsageEvent], since: Date?) = paths.map { UsageLog(directory: $0.usage).events(forCall: r.id) } ?? ([], nil)
        let commitments = paths.flatMap { CommitmentBook.peek(in: $0.commitments) }?.items ?? []
        let a = MeetingAnalytics(record: r, owner: owner, review: paths.flatMap { CoachReview.load(in: $0.callDirectory(r.id)) },
                                 usage: usage.events, usageSince: usage.since, history: MeetingFactsCache().facts(for: records, owner: owner),
                                 value: { id in paths.flatMap { CoachReview.load(in: $0.callDirectory(id))?.value?.rating } },
                                 people: fullDirectory, commitments: commitments)
        guard !a.isEmpty else { return "No numbers for this call: it has no speech." }
        var names: [String: String] = [:]
        for s in a.speakers where names[s.id] == nil { names[s.id] = s.isOwner ? "You" : s.name }
        func said(_ s: MeetingFindings.Sentence) -> String { s.said { names[$0] ?? $0 } }
        func known(_ v: Double?, _ f: (Double) -> String) -> String { v.map(f) ?? "not known" }
        var parts = ["call_id: \(r.id) | \(r.title) | \(shortDay(r.start)) | \(MeetingFindings.span(a.duration))" + (a.byWords ? " | shares by words, from Gemini's notes" : "")]
        let sentences = [MeetingFindings.talk(a), MeetingFindings.flow(a), MeetingFindings.delivery(a)].compactMap { $0 }.map(said)
        if !sentences.isEmpty { parts.append(sentences.joined(separator: ". ") + ".") }
        var speakers: [String] = []
        for s in a.speakers {
            let who = s.isOwner ? "You (\(s.name))" : s.name
            var line = "- \(who): \(MeetingFindings.span(s.seconds)), \(Self.percent(s.share)) of the talk"
            if !a.byWords {
                let pace = known(s.wordsPerMinute) { "\(Int($0.rounded())) words a minute" }
                let fillers = known(s.fillersPerMinute) { String(format: "%.1f a minute", $0) }
                let made = s.interruptionsMade.map(String.init) ?? "not known"
                let received = s.interruptionsReceived.map(String.init) ?? "not known"
                let reply = known(s.medianResponse) { MeetingFindings.pause($0) }
                line += " | \(s.turns) turns | pace \(pace) | fillers \(fillers) | cut in \(made), cut off \(received) | reply after \(reply)"
            }
            speakers.append(line + " | \(s.questions) questions")
        }
        parts.append("Speakers:\n" + speakers.joined(separator: "\n"))
        if let p = a.participation { parts.append("Who came: " + MeetingFindings.participation(p)) }
        if let o = a.outcomes {
            var line = "Outcomes: " + MeetingFindings.outcomes(o)
            let owners = o.owners.map { "\($0.name ?? "No owner"): \($0.tasks.joined(separator: "; "))" }
            if !owners.isEmpty { line += "\n" + owners.map { "- \($0)" }.joined(separator: "\n") }
            parts.append(line)
        }
        if let c = a.coach, let line = MeetingFindings.coach(c) { parts.append("The coach: \(line)") }
        if let s = a.screens { parts.append("Screens: " + said(MeetingFindings.screens(s))) }
        if !a.baselines.standouts.isEmpty {
            parts.append("What stood out against your earlier meetings (\(a.baselines.earlier) to compare with):\n" + a.baselines.standouts.map { "- " + (($0.subject.map { (names[$0] ?? $0) + " " }) ?? "") + $0.text }.joined(separator: "\n"))
        } else if a.baselines.hasHistory {
            parts.append("Nothing stood out against your earlier meetings.")
        }
        if let cost = a.cost { parts.append(String(format: "Cost: $%.2f (transcription $%.2f, AI $%.2f)%@", cost.total, cost.transcription, cost.ai, cost.estimated ? ", estimated from the length" : "")) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: Coach

    /// The deck as Findings shows it, from the memory without what the coach learned about a person who keeps no
    /// read: never a card about such a person, and where the reads may not go (`traits` off) no card about any
    /// person (`FindingAbout`). A card that may not show here uses no place of its call. The local tool and the
    /// server's digest both read it.
    func findingCards(traits allowed: Bool) -> [CoachFinding] {
        guard let paths else { return [] }
        let saved = coachPeople
        let full = profile, now = now
        let shown = full.withoutCoachData(on: saved)
        let recent = records.filter { now.timeIntervalSince($0.start) <= FindingRules.expiryDays * 86_400 }
        let reads = allowed && settings.personaReads
        let traits = reads ? PersonaFindings.cards(PersonaReads.sources(paths: paths, saved: saved, answers: shown.answers, readOnly: true),
                                                   calls: PersonaFindings.calls(from: records, now: now), profile: shown, now: now) : [:]
        let off = saved.notProfiled
        let owner = ownerIdentity
        let others = savedPeople.filter { !$0.isOwner && $0.deleted == nil }.map(\.displayName)
        let voices = Dictionary(recent.map { r in (r.id, r.speakerNames.values.filter { !owner.isOwner($0) && !$0.hasPrefix("Speaker ") }) },
                                uniquingKeysWith: { a, _ in a })
        let questions = Dictionary(full.questions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return FindingRules.deck(reviews: recent.compactMap { r in CoachReview.load(in: paths.callDirectory(r.id)).map { (callID: r.id, date: r.start, review: $0) } },
                                 profile: shown, now: now, traits: traits) { c in
            if let p = c.person, off.contains(saved.canonical(p)) { return false }
            if allowed { return true }
            return !FindingAbout.person(c, question: c.questionID.flatMap { questions[$0] }, names: others + (voices[c.callID] ?? []), isOwner: owner.isOwner)
        }
    }

    func findingsText(_ input: [String: Any]) -> String {
        guard paths != nil else { return "Not available here." }
        guard settings.coach else { return "The coach is off in Settings, so there are no cards." }
        var cards = findingCards(traits: personaTraits)
        if let id = (input["call_id"] as? String)?.nonBlank { cards = cards.filter { $0.callID == id } }
        guard !cards.isEmpty else { return "No cards wait for an answer." }
        let titles = Dictionary(records.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        return cards.map { c in
            var line = "- \(c.kind.title): \(c.text) (call_id: \(c.callID), \(titles[c.callID] ?? ""), \(shortDay(c.date))"
            if let at = c.at { line += ", at_seconds: \(Int(at))" }
            line += ")"
            if let q = c.quote { line += "\n  Quote: \u{201C}\(q)\u{201D}" }
            if let n = c.number { line += "\n  Number: \(n)" + (c.usual.map { ", usually \($0)" } ?? "") }
            if let say = c.say { line += "\n  Say instead: \u{201C}\(say)\u{201D}" }
            if let why = c.why { line += "\n  Why it matters: \(why)" }
            line += "\n  It asks: \(c.kind.question) (\(c.kind.yes) or \(c.kind.no))"
            return line
        }.joined(separator: "\n")
    }

    func goalsText() -> String {
        let profile = profile
        let goals = profile.goalHistory
        guard goals.current != nil || !goals.offered.isEmpty || !goals.ended.isEmpty || !goals.finished.isEmpty else {
            return "No goal yet. After a few reviewed calls the coach offers one, as a card in Findings."
        }
        func hits(_ f: CoachFocus) -> String {
            "\(f.results.filter { $0.outcome == .hit }.count) of \(f.results.count) \(f.goal == nil ? "chances" : "1:1s at the target")"
        }
        var parts: [String] = []
        if let f = goals.current {
            var lines = ["\(f.status == .active ? "Your goal" : "Offered goal, waiting for the owner"): \(f.plan)", "Why: \(f.why)"]
            if let g = f.goal {
                lines.append("Target: \(g.targetText) of the talk in your 1:1s. Before the goal: \(g.typicalText), \(g.usualText).")
                if f.status == .active, let progress = GoalProgress(focus: f, facts: MeetingFactsCache().facts(for: records, owner: owner), now: now, people: filterPeople) {
                    lines.append("Progress: \(progress.sentence).")
                }
                if let review = f.reviewDate { lines.append("Look at the goal again on \(shortDay(review)).") }
            }
            if f.status == .active {
                lines.append("Call by call (\(hits(f))):\n" + (f.results.isEmpty ? "- none yet" : f.results.reversed().map { r in
                    let outcome = f.goal != nil && r.outcome == .hit ? "At the target" : f.goal != nil && r.outcome == .missed ? "Over the target" : r.outcome.label
                    return "- \(shortDay(r.date)) | \(outcome) | call_id: \(r.callID)" + (r.at.map { " at_seconds: \(Int($0))" } ?? "") + " | \(r.evidence)"
                }.joined(separator: "\n")))
            }
            parts.append(lines.joined(separator: "\n"))
        }
        if !goals.finished.isEmpty { parts.append("Learned:\n" + goals.finished.map { "- \($0.plan) (learned \(shortDay($0.updated)), \(hits($0)))" }.joined(separator: "\n")) }
        if !goals.ended.isEmpty { parts.append("Ended:\n" + goals.ended.map { "- \($0.plan) (ended \(shortDay($0.updated)), \(hits($0)))" }.joined(separator: "\n")) }
        if !goals.offered.isEmpty { parts.append("Not taken:\n" + goals.offered.map { "- \($0.plan) (offered \(shortDay($0.proposed)))" }.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    /// The parts of Coach › Knowledge and Weekly review beyond the facts: open questions, rules from the owner's
    /// answers, what was blocked for good, the advice log, and the review written and not sent.
    func coachKnowledgeText() -> String {
        let p = shownProfile
        var parts: [String] = []
        if !p.openQuestions.isEmpty { parts.append("The coach's questions waiting for the owner:\n" + p.openQuestions.map { "- \($0.statement)" }.joined(separator: "\n")) }
        if !p.whyRules.isEmpty { parts.append("Rules from the owner's answers:\n" + p.whyRules.map { "- \($0.text)" }.joined(separator: "\n")) }
        if !p.neverAgain.isEmpty { parts.append("Never again (blocked by the owner until Undo):\n" + p.neverAgain.map { "- \($0.text)" }.joined(separator: "\n")) }
        let shown = p.advice.filter(\.shown).suffix(15)
        if !shown.isEmpty { parts.append("Recent advice lines (a skill gets no line again for 30 days):\n" + shown.reversed().map { "- \(shortDay($0.date)) [\($0.skill)] \($0.text)" }.joined(separator: "\n")) }
        if let dir = paths?.coach {
            for w in WeeklyDigest.waiting(in: dir) {
                parts.append("\(w.weekly ? "Weekly" : "Monthly") review of \(shortDay(w.start)), written and not sent: \(w.digest.subject)\n\(w.digest.intro)"
                             + w.digest.improved.map { "\n+ \($0)" }.joined() + w.digest.toWork.map { "\n- \($0)" }.joined())
            }
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: Shares and the app

    func sharesText(_ input: [String: Any]) -> String {
        guard let paths else { return "Not available here." }
        let url = paths.shares.appendingPathComponent(ShareBook.fileName)
        // Only read: a damaged file stays where it is for the app.
        guard let data = try? Data(contentsOf: url), let book = try? JSONDecoder.callRecord.decode(ShareBook.self, from: data), !book.links.isEmpty else {
            return "No share links on this Mac."
        }
        let limit = min(input["limit"] as? Int ?? Self.defaultLimit, Self.maxLimit)
        let rows = ShareRows.make(links: book.links, remote: nil, now: now)
        return rows.prefix(limit).map { row in
            var line = "\(row.title)" + (row.link.map { " | call_id: \($0.callID)" } ?? "") + " | made \(shortDay(row.created)) | \(row.expiryText(now: now))"
            // Only whether there is a PIN: the PIN itself never leaves the Shares page.
            let pin = switch row.pin {
            case .off: " | no PIN"
            case .on: " | PIN on"
            case .unknown: " | PIN set on another Mac"
            case .locked: " | locked by wrong PINs"
            }
            line += pin
            if row.link?.stopping == true { line += " | stopping" }
            if let o = row.link?.options { line += " | shows " + [o.summary ? "summary" : nil, o.transcript ? "transcript" : nil, o.recording ? "recording" : nil].compactMap { $0 }.joined(separator: ", ") }
            return line
        }.joined(separator: "\n")
    }

    func statusText() -> String {
        let s = settings
        func on(_ v: Bool) -> String { v ? "on" : "off" }
        var lines = ["Mossad \(s.version ?? "version not known") on this Mac."]
        lines.append("Transcription: \(s.transcriptionProvider.displayName)" + (s.transcriptionModel.nonBlank.map { ", \($0)" } ?? ""))
        lines.append("Notes and Chat: \(s.aiProvider.displayName)" + (s.aiModel.nonBlank.map { ", \($0)" } ?? ""))
        lines.append("Coach: \(on(s.coach)); reads of how people think: \(on(s.coach && s.personaReads)); given to other AI apps: \(on(s.coach && s.personaReads && s.personaInMCP)); weekly email: \(on(s.coachEmail))")
        lines.append("Live transcript: \(on(s.liveTranscript)); shared screen capture: \(on(s.captureScreens)); voice recognition: \(on(s.voiceFingerprints))")
        let sync = switch s.sync {
        case .icloud: "iCloud"
        case .server: "the owner's own server"
        case .off: "off"
        }
        lines.append("Sync with the iPhone: \(sync); recording backup: \(s.backup == "local" ? "off, this Mac only" : "on"); recordings kept \(s.recordingDays) days")
        lines.append("Google parts turned on: " + (s.googleParts.isEmpty ? "none" : s.googleParts.map(\.rawValue).joined(separator: ", ")))
        lines.append("\(records.count) meetings written." + (live != nil ? " A call is recording now." : ""))
        return lines.joined(separator: "\n")
    }
}
