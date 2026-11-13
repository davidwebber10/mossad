import Foundation

/// One person in full, as their page shows them: the band, Overview, Meetings, Tasks, Analytics, Knowledge, and the
/// Voice tab without a fingerprint. A person is found only on a sure match; the read of how they think shows only
/// where the app shows it.
extension ChatTools {
    static var peopleDefinitions: [ToolSpec] { [
        ToolSpec(name: "read_person",
                 description: "Reads one person as the owner's People page shows them: person_id, every written form of the name, addresses, job and team, how many meetings (spoke or only invited), when last met, how often, time together; the owner's points for next time with them; how to present to them (when the coach has a read); talk numbers; topics; who they are often with; the meetings with them (call_id); their action items and the owner's promises to them; how the two talk (who starts, questions, cut-ins, reply times); what the owner confirmed about them; and the number of voice samples. person is a person_id, a whole name, or an address; a first name alone is not enough. sections narrows the answer to overview, meetings, tasks, analytics, knowledge, or voice.",
                 schema: ["type": "object", "properties": [
                    "person": ["type": "string", "description": "A person_id, a whole name, or an email address."],
                    "sections": ["type": "array", "items": ["type": "string", "enum": PersonSection.allCases.map(\.rawValue)]],
                    "limit": ["type": "integer", "description": "The most meetings to list, default 20."],
                 ] as [String: Any], "required": ["person"]]),
    ] }

    enum PersonSection: String, CaseIterable { case overview, meetings, tasks, analytics, knowledge, voice }

    /// The people of the People page by the rule of the Meetings filter: the saved people with their ids.
    var filterPeople: MeetingFilterPeople { MeetingFilterPeople(profiles: profiles, people: savedPeople, owner: owner) }

    /// The person the words are, on a sure match: an id, a whole name in any written form, or an address.
    func person(_ query: String?) -> Person? {
        guard let q = query?.nonBlank, let id = saved.id(for: q) else { return nil }
        return saved.person(saved.canonical(id))
    }

    /// The read of how a person thinks, only where the app shows it: the switch for this place on, and never for a
    /// person who keeps no read.
    func shownRead(of id: String) -> PersonaSummary? {
        guard personaTraits, !coachPeople.notProfiled.contains(coachPeople.canonical(id)) else { return nil }
        return personaReads()[coachPeople.canonical(id)]
    }

    func readPerson(_ input: [String: Any]) -> String {
        guard let p = person(input["person"] as? String) else {
            return "No saved person is surely \u{201C}\((input["person"] as? String) ?? "")\u{201D}. Use their person_id (from people or read_meeting), their whole name, or an address."
        }
        let wanted = Set((input["sections"] as? [String] ?? []).compactMap(PersonSection.init(rawValue:)))
        func shows(_ s: PersonSection) -> Bool { wanted.isEmpty || wanted.contains(s) }
        let limit = min(input["limit"] as? Int ?? Self.defaultLimit, Self.maxLimit)
        let id = p.id.rawValue, name = p.displayName, first = SeriesSuggestion.first(name)
        let isOwner = p.isOwner
        let commitments = paths.flatMap { CommitmentBook.peek(in: $0.commitments) }?.visible ?? []
        let list = PersonMeetings(records: records, name: name, isOwner: isOwner, people: filterPeople)
        let stats = PersonStatistics.compute(records)[name] ?? PersonStats()
        let relation: PersonRelation? = isOwner ? nil : {
            let same = savedPeople.filter { $0.isLive && $0.displayName == name }
            let shared = records.filter { $0.speakerNames.values.contains(name) }
            let reviews = Dictionary(shared.compactMap { r in paths.flatMap { CoachReview.load(in: $0.callDirectory(r.id)) }.map { (r.id, $0) } }, uniquingKeysWith: { a, _ in a })
            return PersonRelation(name: name, personID: id, owner: owner, records: records, reviews: reviews, commitments: commitments,
                                  nameIsUnique: same.count <= 1)
        }()

        var parts: [String] = []
        // The band.
        var head = "person_id: \(id) | \(name)" + (isOwner ? " (the owner)" : "")
        if let role = [p.directory?.jobTitle, p.directory?.department].compactMap({ $0?.nonBlank }).joined(separator: " · ").nonBlank { head += " | \(role)" }
        if let company = p.company?.nonBlank { head += " | \(company)" }
        let emails = p.emails.filter { $0.state != .rejected && !$0.shared }.map(\.address)
        if !emails.isEmpty { head += " | \(emails.joined(separator: ", "))" }
        parts.append(head)
        let forms = Array(Set(p.forms.map(\.text).filter { $0 != name })).sorted()
        if !forms.isEmpty { parts.append("Also written as: \(forms.joined(separator: "; "))") }
        let t = list.together
        var band = "\(t.meetings) \(t.countLabel(owner: isOwner))"
        band += " | last met " + (t.lastMet.map(shortDay) ?? (t.meetings > 0 ? "not known" : "not yet"))
        band += t.cadence.map { " | \($0.word), \(t.recent) in the last 90 days" } ?? " | \(t.recent) in the last 90 days"
        band += " | time together " + (t.seconds > 0 ? Self.duration(t.seconds) : "none")
        parts.append(band)

        if shows(.overview) {
            if !isOwner, let book = paths.flatMap({ NextTimeBook.peek(in: $0.nextTime) }) {
                let points = book.points(forPerson: id, people: savedPeople).filter(\.isOpen)
                parts.append("Next time I see \(first):\n" + (points.isEmpty ? "- nothing saved" : points.map { "- \($0.text) (point_id: \($0.id.uuidString))" }.joined(separator: "\n")))
            }
            if !isOwner {
                let read = shownRead(of: id)
                if let read, read.card != nil || !read.traits.isEmpty {
                    parts.append("How \(first) thinks (the coach's read, by code from several calls):\n" + read.text(name: first))
                } else if let brief = profile.note(on: name, people: coachPeople)?.value.brief, !coachPeople.notProfiled.contains(id) {
                    parts.append("The coach's read (from \(brief.calls) calls): \(brief.headline)\n" + brief.sections.map { "\($0.title): " + $0.points.map(\.text).joined(separator: " ") }.joined(separator: "\n"))
                }
            }
            var numbers = ["\(stats.totalTalk > 0 ? Self.duration(stats.totalTalk) : "none") \(isOwner ? "total talk time" : "\(first) talking")"]
            numbers.append("average talk share " + (stats.averageShare.map(Self.percent) ?? "not known"))
            numbers.append("\(stats.actionItems.count) action items")
            numbers.append("first heard " + (stats.firstHeard.map { $0.formatted(.dateTime.month(.abbreviated).year()) } ?? "not yet"))
            parts.append("By the numbers: " + numbers.joined(separator: " | "))
            if let r = relation, r.calls > 0 {
                var together: [String] = []
                if let s = r.usualSlot { together.append("usual time \(Self.slot(s))") }
                together.append("your talk share one to one " + (r.oneOnOne?.share.map(Self.percent) ?? "not known"))
                together.append("in groups " + (r.group?.share.map(Self.percent) ?? "not known"))
                together.append("\(r.myCommitments.filter { $0.done == nil }.count) open tasks for \(first)")
                parts.append("Together: " + together.joined(separator: " | "))
                if !r.topics.isEmpty { parts.append("Topics: " + r.topics.joined(separator: ", ")) }
            }
            if !stats.oftenWith.isEmpty { parts.append("Often with: " + stats.oftenWith.prefix(8).map { "\($0.name) \($0.meetings)" }.joined(separator: ", ")) }
        }

        if shows(.meetings) {
            let rows = list.rows.prefix(limit).map { row -> String in
                var line = "- call_id: \(row.id) | \(row.title) | \(shortDay(row.start)) | \(Int((row.seconds / 60).rounded())) min | \(row.part == .spoke ? "spoke" : "only invited")"
                if row.notesOnly { line += " | from Gemini notes" }
                return line
            }
            parts.append("Meetings (newest first, \(rows.count) of \(list.rows.count)):\n" + (rows.isEmpty ? "- none" : rows.joined(separator: "\n")))
        }

        if shows(.tasks), let r = relation {
            func items(_ list: [PersonRelation.Item]) -> String {
                list.isEmpty ? "- none" : list.prefix(limit).map { "- \($0.task) (call_id: \($0.callID), \(shortDay($0.date)))" }.joined(separator: "\n")
            }
            parts.append("\(first)'s action items:\n" + items(r.theirItems))
            parts.append("Your action items from your 1:1s with \(first):\n" + items(r.myItems))
            let promises = r.myCommitments.map { c in
                "- \(c.text)" + (c.done.map { " | done \(shortDay($0))" } ?? (c.due.map { " | due \(shortDay($0))" } ?? "")) + (c.callID.map { " | call_id: \($0)" } ?? "")
            }
            parts.append("Your promises to \(first):\n" + (promises.isEmpty ? "- none" : promises.joined(separator: "\n")))
        }

        if shows(.analytics), let r = relation, r.calls > 0 {
            var lines = ["\(r.calls) calls together, \(Self.duration(r.seconds))" + (r.averageGapDays.map { String(format: ", about every %.0f days", $0) } ?? "")]
            lines.append("Who speaks first: you \(r.ownerFirst), \(first) \(r.theyFirst)")
            func rate(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "not known" }
            lines.append("Questions an hour: you \(rate(r.myQuestionsPerHour)), \(first) \(rate(r.theirQuestionsPerHour))")
            lines.append("Cutting in an hour: you on \(first) \(rate(r.iInterruptPerHour)), \(first) on you \(rate(r.theyInterruptPerHour))")
            func pause(_ v: TimeInterval?) -> String { v.map { String(format: "%.1f s", $0) } ?? "not known" }
            lines.append("Usual pause before an answer: yours \(pause(r.myReply)), \(first)'s \(pause(r.theirReply))")
            if !r.value.isEmpty {
                lines.append("The coach's rating of these meetings: " + MeetingValue.Rating.allCases.compactMap { k in r.value[k].map { "\(k.rawValue) \($0)" } }.joined(separator: ", "))
            }
            lines.append("Calls in the last 26 weeks: \(r.weekly.reduce(0) { $0 + $1.calls })")
            parts.append("How you two talk:\n" + lines.joined(separator: "\n"))
        }

        if shows(.knowledge), !isOwner {
            let byID = profile.learnings(about: id, people: coachPeople)
            let confirmed = byID.isEmpty ? profile.learnings(named: name) : byID
            if !confirmed.isEmpty { parts.append("You confirmed:\n" + confirmed.map { "- \($0.text)" }.joined(separator: "\n")) }
            if let read = shownRead(of: id), !read.traits.isEmpty {
                parts.append("How they think, each with its confidence:\n" + read.traits.map { "- \($0.statement) (\($0.confidenceLine))" }.joined(separator: "\n"))
            }
            let blocked = profile.neverAgain.filter { a in a.person.map { coachPeople.canonical($0) == id || $0 == id } ?? false }
            if !blocked.isEmpty { parts.append("Never again (the owner blocked these cards):\n" + blocked.map { "- \($0.text)" }.joined(separator: "\n")) }
            if coachPeople.notProfiled.contains(id) { parts.append("The owner keeps no read on \(first): the coach learns nothing about them.") }
        }

        if shows(.voice) {
            let voice = profiles.first { $0.name == name }
            let samples = paths.flatMap { VoiceSampleStore.peek(in: $0.voices) }?.filter { $0.personID == p.id } ?? []
            let count = voice?.embeddings.count ?? samples.count
            var line = count == 0 ? "No voice sample yet." : "\(count) voice \(count == 1 ? "sample" : "samples"): Mossad recognizes \(isOwner ? "the owner" : first) by voice in later calls."
            if p.provisional { line += " Named from an invite only so far: it names a voice only on a call that invites them." }
            let rows = samples.sorted { ($0.recorded ?? $0.learned) > ($1.recorded ?? $1.learned) }.prefix(limit).map { s in
                "- \(shortDay(s.recorded ?? s.learned)) | \(s.origin.words)" + (s.callID.map { " | call_id: \($0)" } ?? "") + (s.seconds.map { " | \(Int($0.rounded())) s" } ?? "")
            }
            parts.append("Voice: " + line + (rows.isEmpty ? "" : "\n" + rows.joined(separator: "\n")) + "\nFingerprints stay on this Mac and are never given.")
        }
        return parts.joined(separator: "\n\n")
    }

    /// The pairs the People page offers to merge, and why. Mossad never merges by itself.
    func duplicatesText() -> String {
        let pairs = PeopleDuplicates.shown(profiles, people: savedPeople, dismissed: settings.notDuplicates)
        guard !pairs.isEmpty else { return "No people look like one person." }
        return "These may be one person (only the owner can merge them, on the People page):\n" + pairs.map { pair in
            let ids = PeopleDuplicates.people(of: pair, among: savedPeople)
            return "- \(pair.first) and \(pair.second): \(pair.reason.words.lowercased())" + (ids.map { " (person_ids \($0.0) and \($0.1))" } ?? "")
        }.joined(separator: "\n")
    }

    // MARK: Words

    func shortDay(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day().year()) }

    /// "1 h 5 min", "12 min", or "40 s".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let m = s / 60
        return m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }

    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    static func slot(_ s: PersonRelation.Slot) -> String {
        let names = Calendar(identifier: .gregorian).shortWeekdaySymbols
        return "\(names[(s.weekday - 1) % 7]) \(s.hour):00"
    }
}
