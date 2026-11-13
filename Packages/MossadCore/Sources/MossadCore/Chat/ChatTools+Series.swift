import Foundation

/// The calendar's next meetings, the page "Before this meeting", the recurring meetings, and the owner's points for
/// next time: the same rules as those pages (`UpcomingMeeting`, `MeetingPrep`, `SeriesCatalog`, `SeriesReport`,
/// `SeriesSuggestion`, `NextTimeBook`).
extension ChatTools {
    static var seriesDefinitions: [ToolSpec] { [
        ToolSpec(name: "recurring",
                 description: "Lists the owner's recurring meetings (series), the next one first: series_id, title, when it usually is (\"Tue 10:00\"), the next date, the last meeting, how many were recorded, who usually comes, and one line such as \"Usually 5 people, runs 8 min over; 3 open items\". query narrows by words of the title or a usual person. Read one with read_series.",
                 schema: ["type": "object", "properties": ["query": ["type": "string"], "limit": ["type": "integer"]] as [String: Any]]),
        ToolSpec(name: "read_series",
                 description: "Reads one recurring meeting as its page shows it: when it is, the owner's points for next time (open, discussed with the quote, carried, or seen in notes), the coach's suggested points with their source, each meeting (call_id, length, late, over time, the owner's talk share, people), who comes (and who joined or dropped off), the numbers (median length, ran over, started late, skipped), and what is still open (the owner's tasks, others' items of the last meeting, open decisions). series is a series_id or words of its title.",
                 schema: ["type": "object", "properties": [
                    "series": ["type": "string"], "limit": ["type": "integer", "description": "The most meetings to list, default 20."],
                 ] as [String: Any], "required": ["series"]]),
        ToolSpec(name: "next_time_points",
                 description: "The owner's points to raise later: for the next meeting of a recurring meeting or the next time they see a person. Each with point_id, its series or person, when it was saved, and what happened to it: discussed (in which call_id, at what second, with the quote), carried over meetings that did not discuss it, or seen in a meeting Mossad has only the notes of. status is open (default), done, or all. Narrow by series (series_id or title words) or person (person_id or whole name). To add one, use add_next_time_point.",
                 schema: ["type": "object", "properties": [
                    "status": ["type": "string", "enum": ["open", "done", "all"]], "series": ["type": "string"], "person": ["type": "string"], "limit": ["type": "integer"],
                 ] as [String: Any]]),
    ] }

    /// Only the Mac reads the calendar.
    static var calendarDefinitions: [ToolSpec] {
        #if os(macOS)
        [
            ToolSpec(name: "upcoming_meetings",
                     description: "The owner's next calls from the calendar, soonest first (as Mossad last read it; the answer says when): upcoming_id, title, day and time, platform, who is invited, and series_id for a recurring meeting. days is how far ahead, 1 to 45 (default 7). query narrows by words of the title or a person. Use prep with an upcoming_id to prepare for one.",
                     schema: ["type": "object", "properties": [
                        "days": ["type": "integer"], "query": ["type": "string"], "limit": ["type": "integer"],
                     ] as [String: Any]]),
            ToolSpec(name: "prep",
                     description: "The page \"Before this meeting\" for one upcoming call: who is invited and when the owner last met each (with one fact from their history), the last meeting of the series or with these people (its decisions and action items, and which of the owner's are open or done), the owner's open tasks for these people, the owner's points for next time, the series in numbers, and how to present to each person when the coach has a read. meeting is an upcoming_id from upcoming_meetings or words of the title; leave it out for the next call.",
                     schema: ["type": "object", "properties": ["meeting": ["type": "string"]] as [String: Any]]),
        ]
        #else
        []
        #endif
    }

    // MARK: Inputs

    /// The calendar as the app last read it; nil before the app read it on this Mac.
    var snapshot: CalendarSnapshot? { paths.flatMap { CalendarSnapshot.load(from: $0.calendar) } }

    /// The invites still to come, as the app's lists have them: no all-day event, no declined one, none that is
    /// recorded or was.
    func upcoming(_ snapshot: CalendarSnapshot?, now: Date) -> [UpcomingMeeting] {
        guard let snapshot else { return [] }
        return UpcomingMeeting.from(snapshot.calendarEvents, now: now, limit: .max, recorded: records + (live.map { [$0] } ?? []))
    }

    /// The recurring meetings as the Recurring page makes them: the records and the calendar's invites.
    func catalog(now: Date = Date()) -> (all: [MeetingSeries], upcoming: [UpcomingMeeting], snapshot: CalendarSnapshot?) {
        let snapshot = snapshot
        let upcoming = upcoming(snapshot, now: now)
        let all = SeriesCatalog.build(records: records, upcoming: upcoming, owner: owner, directory: PersonDirectory(profiles: profiles),
                                      ownerEmails: [settings.ownerEmail], aliases: SeriesCatalog.aliases(snapshot?.calendarEvents ?? []), now: now)
        return (all, upcoming, snapshot)
    }

    /// Every address of each saved person, as the meeting page and the prep page read them.
    var fullDirectory: PersonDirectory { PersonDirectory(profiles: profiles, people: savedPeople) }

    /// The owner under each name they have or had.
    var ownerIdentity: OwnerIdentity { paths.map { OwnerIdentity.read(name: owner, paths: $0) } ?? OwnerIdentity(name: owner) }

    var book: NextTimeBook? { paths.flatMap { NextTimeBook.peek(in: $0.nextTime) } }

    private func series(_ query: String?, in all: [MeetingSeries]) -> [MeetingSeries] {
        guard let q = query?.nonBlank else { return [] }
        if let s = all.first(where: { $0.id == q || $0.keys.contains(q) }) { return [s] }
        return NextTimeAdd.series(q, in: all)
    }

    private func when(_ start: Date, _ end: Date) -> String {
        start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()) + "–" + end.formatted(date: .omitted, time: .shortened)
    }

    private func asOf(_ s: CalendarSnapshot, now: Date) -> String {
        let hours = now.timeIntervalSince(s.saved) / 3600
        let line = "Calendar as Mossad read it \(s.saved.formatted(.dateTime.month(.abbreviated).day().hour().minute()))."
        return hours > 24 ? line + " That is more than a day ago: open Mossad to read it again." : line
    }

    static let noCalendar = "Mossad has not read the calendar on this Mac yet. It reads it while the app runs, with calendar access on."

    // MARK: Upcoming and prep

    func upcomingText(_ input: [String: Any], now: Date = Date()) -> String {
        let (all, upcoming, snapshot) = catalog(now: now)
        guard let snapshot else { return Self.noCalendar }
        let days = max(1, min(input["days"] as? Int ?? 7, UpcomingMeeting.days))
        let limit = min(input["limit"] as? Int ?? Self.defaultLimit, Self.maxLimit)
        let horizon = now.addingTimeInterval(Double(days) * 86_400)
        let query = (input["query"] as? String)?.nonBlank
        let directory = fullDirectory
        let list = upcoming.filter { $0.start < horizon }.filter { u in
            guard let query else { return true }
            return u.title.localizedCaseInsensitiveContains(query) || u.attendees.contains { Self.name(query, matches: $0) || $0.localizedCaseInsensitiveContains(query) }
        }
        guard !list.isEmpty else { return asOf(snapshot, now: now) + "\nNo calls in the next \(days) days" + (query.map { " match \u{201C}\($0)\u{201D}" } ?? "") + "." }
        let lines = list.prefix(limit).map { u -> String in
            var line = "upcoming_id: \(u.id) | \(u.title) | \(when(u.start, u.end))"
            if let p = u.platform { line += " | \(p.displayName)" }
            let invited = MeetingPrep.invited(u.attendees, owner: owner, directory: directory, ownerEmails: [settings.ownerEmail]).map(\.name)
            if !invited.isEmpty { line += " | invited: \(invited.joined(separator: ", "))" }
            if let s = SeriesCatalog.series(of: u, in: all) { line += " | series_id: \(s.id)" }
            return line
        }
        return ([asOf(snapshot, now: now)] + lines + (list.count > limit ? ["(\(list.count - limit) more; raise limit or narrow days.)"] : [])).joined(separator: "\n")
    }

    func prepText(_ input: [String: Any], now: Date = Date()) -> String {
        let (all, upcoming, snapshot) = catalog(now: now)
        guard let snapshot else { return Self.noCalendar }
        let query = (input["meeting"] as? String)?.nonBlank
        let meeting = query.map { q in upcoming.first { $0.id == q } ?? upcoming.first { $0.title.localizedCaseInsensitiveContains(q) } } ?? upcoming.first
        guard let meeting else { return asOf(snapshot, now: now) + "\nNo upcoming call" + (query.map { " matches \u{201C}\($0)\u{201D}" } ?? "") + ". Use upcoming_meetings for the list." }
        let directory = fullDirectory
        // The reads go only where the app shows them.
        let reads = personaTraits ? personaReads().filter { !coachPeople.notProfiled.contains($0.key) } : [:]
        let commitments = paths.flatMap { CommitmentBook.peek(in: $0.commitments) }?.items
        let prep = MeetingPrep(meeting: meeting, owner: owner, records: records, facts: MeetingFactsCache().facts(for: records, owner: owner),
                               commitments: commitments, people: directory, ownerEmails: [settings.ownerEmail], now: now,
                               memory: profile, saved: coachPeople, reads: reads)
        var parts = ["upcoming_id: \(meeting.id) | \(meeting.title) | \(when(meeting.start, meeting.end))"
                     + (SeriesCatalog.series(of: meeting, in: all).map { " | series_id: \($0.id)" } ?? "")]
        if !prep.invited.isEmpty {
            parts.append("Invited: " + prep.invited.map { i in i.name + (saved.id(for: i.person ?? i.written).map { " (person_id: \(saved.canonical($0)))" } ?? "") }.joined(separator: ", "))
        }
        if !prep.people.isEmpty {
            parts.append("The people:\n" + prep.people.map { p in
                var line = "- \(p.name): " + (p.lastMet.map { "last met \(shortDay($0.start)) (call_id: \($0.id))" } ?? "no recorded meeting together")
                line += " | \(p.recent) in the last 90 days | \(p.meetings) in all"
                if let f = p.fact { line += " | \(f.text) (\(f.basis))" }
                return line
            }.joined(separator: "\n"))
        }
        if let book {
            let ids = NextTimeInvite.personIDs(meeting.attendees, people: saved)
            let points = book.points(for: SeriesCatalog.series(of: meeting, in: all), people: ids, canonical: saved.canonical).filter(\.isOpen)
            if !points.isEmpty { parts.append("Your points:\n" + points.map { "- \($0.text) (point_id: \($0.id.uuidString))" }.joined(separator: "\n")) }
        }
        if let last = prep.lastTime {
            var lines = ["\(last.inSeries ? "Last time in this series" : "Last time with these people"): \(last.meeting.title), \(shortDay(last.meeting.start)) (call_id: \(last.meeting.id))"
                         + (last.headline.map { ". \($0)" } ?? "")]
            if !last.decisions.isEmpty {
                lines.append("Decisions:\n" + last.decisions.map { "- \($0.text)" }.joined(separator: "\n") + (last.moreDecisions > 0 ? "\n- and \(last.moreDecisions) more" : ""))
            }
            if !last.items.isEmpty {
                lines.append("Action items:\n" + last.items.map { i in
                    let who = i.isOwners ? "You" : (i.owner ?? "No owner")
                    let state = i.state.map { $0 == .open ? " [open]" : " [done]" } ?? ""
                    return "- \(who): \(i.task)\(state)"
                }.joined(separator: "\n") + (last.moreItems > 0 ? "\n- and \(last.moreItems) more" : ""))
            }
            if last.absent > 0 { lines.append("\(last.absent) action items of people not invited this time are left out.") }
            parts.append(lines.joined(separator: "\n"))
        }
        if !prep.tasksKnown {
            parts.append("Your tasks could not be read.")
        } else if !prep.promises.isEmpty {
            parts.append("Your open tasks for these people (\(prep.openPromises)):\n" + prep.promises.map { p in
                "- \(p.commitment.text)" + (p.commitment.to.map { " (to \($0))" } ?? "") + (p.commitment.due.map { " | due \(shortDay($0))" } ?? "")
            }.joined(separator: "\n") + (prep.morePromises > 0 ? "\n- and \(prep.morePromises) more" : ""))
        }
        if let s = prep.series {
            var line = "The series: \(s.meetings) meetings since \(shortDay(s.since))"
            if let l = s.length { line += " | usually \(Int(l.median.rounded())) min" }
            if let o = s.ownerShare { line += " | your talk share usually \(Self.percent(o.median))" }
            if s.planned > 0 { line += " | ran over \(s.ranOver) of \(s.planned), you joined late \(s.joinedLate) of \(s.planned)" }
            parts.append(line)
        }
        let coach = prep.coach.people.compactMap { p -> String? in
            guard let headline = p.headline else { return nil }
            var line = "- \(p.name): \(headline)"
            if p.showsCard, let card = p.card { line += "\n  " + card.lines.map { "\($0.kind.title): \($0.text)" }.joined(separator: " / ") }
            return line
        }
        if !coach.isEmpty { parts.append("The coach:\n" + coach.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: Recurring

    func recurringText(_ input: [String: Any], now: Date = Date()) -> String {
        let (all, _, _) = catalog(now: now)
        let limit = min(input["limit"] as? Int ?? Self.defaultLimit, Self.maxLimit)
        let list = (input["query"] as? String)?.nonBlank.map { NextTimeAdd.series($0, in: all) } ?? all
        guard !list.isEmpty else { return all.isEmpty ? "No recurring meetings yet: two meetings of one series make one." : "No recurring meeting matches." }
        let sorted = list.sorted { a, b in
            switch (a.next?.start, b.next?.start) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (a.last?.start ?? .distantPast) > (b.last?.start ?? .distantPast)
            }
        }
        let identity = ownerIdentity
        let commitments = paths.flatMap { CommitmentBook.peek(in: $0.commitments) }?.items
        let directory = fullDirectory
        return sorted.prefix(limit).map { s in
            var line = "series_id: \(s.id) | \(s.title)"
            line += " | " + (s.schedule.text() ?? "no fixed day")
            if let n = s.next { line += " | next \(when(n.start, n.end))" }
            if let l = s.last { line += " | last \(shortDay(l.start)) (call_id: \(l.id))" }
            line += " | \(s.meetings.count) recorded"
            if !s.usualPeople.isEmpty { line += " | usually: \(s.usualPeople.prefix(6).joined(separator: ", "))" }
            let report = SeriesReport(series: s, records: records, commitments: commitments, owner: identity, directory: directory, ownerEmails: [settings.ownerEmail])
            if let l = report.line { line += " | \(l)" }
            return line
        }.joined(separator: "\n") + (sorted.count > limit ? "\n(\(sorted.count - limit) more.)" : "")
    }

    func readSeries(_ input: [String: Any], now: Date = Date()) -> String {
        let (all, _, _) = catalog(now: now)
        let found = series(input["series"] as? String, in: all)
        guard found.count == 1, let s = found.first else {
            if found.count > 1 { return "Several recurring meetings match; ask which one: " + found.map { "\($0.title) (series_id: \($0.id))" }.joined(separator: "; ") + "." }
            return "No recurring meeting matches. Use recurring for the list."
        }
        let limit = min(input["limit"] as? Int ?? Self.defaultLimit, Self.maxLimit)
        let identity = ownerIdentity
        let commitments = paths.flatMap { CommitmentBook.peek(in: $0.commitments) }?.items
        let report = SeriesReport(series: s, records: records, commitments: commitments, owner: identity, directory: fullDirectory, ownerEmails: [settings.ownerEmail])
        var parts = ["series_id: \(s.id) | \(s.title) | " + (s.schedule.text() ?? "no fixed day") + (s.next.map { " | next \(when($0.start, $0.end))" } ?? "")]
        if let l = report.line { parts.append(l) }
        if !s.usualPeople.isEmpty { parts.append("Usually: " + s.usualPeople.joined(separator: ", ")) }

        let book = self.book ?? NextTimeBook()
        let points = book.points(of: s)
        parts.append("Your points for next time:\n" + (points.open.isEmpty ? "- none open" : points.open.map(pointLine).joined(separator: "\n")))
        if !points.done.isEmpty { parts.append("Done:\n" + points.done.prefix(limit).map(pointLine).joined(separator: "\n")) }
        let focus = profile.activeFocus
        let suggestions = SeriesSuggestion.make(for: s, records: records, commitments: commitments, owner: identity, points: points.open, answers: book.answers,
                                                goal: focus.map { (plan: $0.plan, oneOnOne: $0.goal?.measure == .oneOnOneTalkShare) }, now: now)
        if !suggestions.isEmpty {
            parts.append("Suggested by the coach (not the owner's points):\n" + suggestions.map { "- \($0.kind.title): \($0.text) (\($0.source.label)" + ($0.source.callID.map { ", call_id: \($0)" } ?? "") + ")" }.joined(separator: "\n"))
        }

        let rows = report.rows.prefix(limit).map { r -> String in
            var line = "- call_id: \(r.id) | \(shortDay(r.start)) | \(Int(r.minutes.rounded())) min"
            if let late = r.lateMinutes, late >= 1 { line += " | began \(Int(late.rounded())) min late" }
            if let over = r.overMinutes, over >= 1 { line += " | \(Int(over.rounded())) min over" }
            if let share = r.ownerShare { line += " | your share \(Self.percent(share))" }
            if let n = r.people { line += " | \(n) people" }
            if r.notesOnly { line += " | from Gemini notes" }
            if let h = r.headline { line += " | \(h)" }
            return line
        }
        parts.append("History (\(rows.count) of \(report.meetings)):\n" + (rows.isEmpty ? "- none recorded" : rows.joined(separator: "\n")))

        if !report.attendees.isEmpty {
            parts.append("People:\n" + report.attendees.map { a in
                var line = "- \(a.name): came \(a.came) of \(a.of)"
                if let share = a.share { line += " | talk share \(Self.percent(share))" }
                if let last = a.last { line += " | last \(shortDay(last))" }
                switch a.trend {
                case .joined: line += " | joined lately"
                case .droppedOff: line += " | dropped off"
                case .steady: break
                }
                return line
            }.joined(separator: "\n"))
        }

        var stats = ["\(report.meetings) meetings" + (report.since.map { " since \(shortDay($0))" } ?? "")]
        if let m = report.medianMinutes { stats.append("median \(Int(m.rounded())) min") }
        if let m = report.medianPlannedMinutes { stats.append("planned \(Int(m.rounded())) min") }
        if report.planned > 0 { stats.append("ran over \(report.ranOver) of \(report.planned)"); stats.append("started late \(report.startedLate) of \(report.planned)") }
        if let skipped = s.schedule.skippedText(gaps: report.gaps ?? 0), report.gaps != nil { stats.append(skipped) }
        if let share = report.ownerShare { stats.append("your talk share \(Self.percent(share))") }
        if let who = report.talksMost { stats.append("\(who == "You" ? "you talk" : "\(who) talks") most") }
        parts.append("Numbers: " + stats.joined(separator: " | "))

        if !report.openItems.isEmpty {
            parts.append("Still open:\n" + report.openItems.prefix(limit).map { i in
                let kind = switch i.kind {
                case .yourTask: "Your task"
                case .actionItem: "Action item" + (i.owner.map { " (\($0))" } ?? "")
                case .pendingDecision: "Decision that may be open"
                }
                return "- \(kind): \(i.text)" + (i.callID.map { " (call_id: \($0), \(shortDay(i.date)))" } ?? "")
            }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: Points

    func pointLine(_ p: NextTimePoint) -> String {
        var line = "- \(p.text) (point_id: \(p.id.uuidString)"
        line += p.seriesTitle.map { ", for the next \($0)" } ?? p.personName.map { ", for the next time you see \($0)" } ?? ""
        line += ", saved \(shortDay(p.created)))"
        if let d = p.done {
            line += " | discussed" + (d.callID.map { " in call_id \($0)" } ?? "") + (d.at.map { " at \(MarkdownWriter.timestamp($0))" } ?? "") + " on \(shortDay(d.date))"
            if d.byOwner { line += " (ticked by the owner)" }
            if let q = d.quote { line += ": \u{201C}\(q)\u{201D}" }
        }
        if let carried = p.carried, !carried.isEmpty, p.isOpen { line += " | carried over \(carried.count) \(carried.count == 1 ? "meeting" : "meetings")" }
        if p.isOpen, let m = p.lastMention {
            line += " | came up \(shortDay(m.date)) in a meeting Mossad has only the notes of (call_id: \(m.callID)): \u{201C}\(m.quote)\u{201D}"
        }
        return line
    }

    func nextTimeText(_ input: [String: Any], now: Date = Date()) -> String {
        guard let paths else { return "Not available here." }
        guard let book = NextTimeBook.peek(in: paths.nextTime) else { return "No points for next time yet." }
        let limit = min(input["limit"] as? Int ?? Self.defaultLimit * 2, Self.maxLimit)
        var list = book.visible
        if let q = (input["series"] as? String)?.nonBlank {
            let found = series(q, in: catalog(now: now).all)
            guard !found.isEmpty else { return "No recurring meeting matches \u{201C}\(q)\u{201D}." }
            list = list.filter { p in found.contains { p.belongs(to: $0) } }
        }
        if let q = (input["person"] as? String)?.nonBlank {
            guard let p = person(q) else { return "No saved person is surely \u{201C}\(q)\u{201D}. Use their person_id or whole name." }
            // Open and done: a point saved for a person who was merged into this one is theirs too.
            list = list.filter { $0.personID.map(saved.canonical) == p.id.rawValue }
        }
        switch input["status"] as? String ?? "open" {
        case "all": break
        case "done": list = list.filter { $0.done != nil }
        default: list = list.filter(\.isOpen)
        }
        guard !list.isEmpty else { return "No points match." }
        list.sort { ($0.isOpen ? 0 : 1, $0.seriesTitle ?? $0.personName ?? "", $0.rank) < ($1.isOpen ? 0 : 1, $1.seriesTitle ?? $1.personName ?? "", $1.rank) }
        return list.prefix(limit).map(pointLine).joined(separator: "\n") + (list.count > limit ? "\n(\(list.count - limit) more.)" : "")
    }
}
