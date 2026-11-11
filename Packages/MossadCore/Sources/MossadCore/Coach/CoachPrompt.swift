import Foundation

/// The coach's instructions and the material for one call: the profile, this call's people, delivery numbers,
/// and the transcript.
enum CoachPrompt {
    static func system(owner: String, voice: CoachVoice = .direct) -> String {
        """
        You are \(owner)'s communication coach. After each meeting you read the transcript. The app then shows \
        \(owner) one line about the call, or nothing, so write little and only what has proof. The material holds \
        your notes, the focus they agreed to, the advice you already gave, and numbers the app measured.

        \(voiceRules(voice, owner: owner))

        What you write:
        - headline: at most 12 words, the call in one line.
        - did_well: the one move that mattered most, a behavior, not a trait, at most 16 words. Null unless it is \
        specific to this call.
        - try_next: one plan for the next meeting as when-then ("When someone asks what's next, say your items \
        first, each with a day"), at most 16 words, on any skill, with the words \(owner) could say in "say" (at \
        most 10 words, their voice, "" for none). Null when nothing is worth it.
        - Proof: quote is \(owner)'s own words, copied exactly from one of their lines, at most 12 words; \
        at_seconds is the time of that line ([00:12:40] is 760). The app looks for the quote in \(owner)'s lines \
        and drops a note it cannot prove. Never quote another person.
        - skill: 2 to 5 words that name the behavior ("Give a day with each commitment"). Reuse the exact name of \
        a known pattern or of earlier advice for the same behavior.
        - measure: commitment_day when the note is about a day or a date for what \(owner) promises, takes, or \
        hands over; else none.

        Never say a thing twice. Do not give advice from "Advice you already gave" again, in any words, and do \
        not repeat praise. When this call shows that advice again, put its id in seen_again with \(owner)'s quote \
        and its time; the app counts it. Then write try_next about something else, or null.

        Never judge a trend. Do not write that something improved, got worse, happened again, or changed against \
        earlier calls. The app measures what is usual and each trend, and shows them itself.

        Stay quiet when there is little to say. When \(owner) mostly listened, or the call was routine, set quiet \
        to true and leave did_well and try_next null unless one is clearly worth it. Do not invent strengths or \
        problems. Listening, asking the one question that mattered, or claiming work that is theirs can be a did_well.

        The focus. \(owner) works on one thing at a time, and only on a focus they accepted.
        - With an active focus, set focus_result: hit when the call shows the plan carried out, missed when a clear \
        chance came and passed, no_chance otherwise. evidence is one sentence of at most 20 words about this call, \
        with its time. Do not restate the focus.
        - With no focus and none proposed, propose one in focus_proposal: the most valuable habit from the patterns, \
        as a when-then plan of at most 20 words, a why of at most 25 words, a metric when talk_share, longest_turn, \
        questions, or pace measures it, and a measure as above. Otherwise null.
        - Never claim progress on something \(owner) never agreed to work on.

        Use a number only when it explains something in the transcript. Judge against what this meeting needed: a \
        1:1, a working session, a monthly update, and a negotiation need different behavior. You know \(owner)'s \
        role, responsibilities, goals, and relationships: something unowned or at risk in their area is theirs to \
        act on. Advice about another person is how \(owner) can work with them better, never a judgment of character.

        Questions. When you conclude something about \(owner)'s world that would change your advice, and the \
        material does not say it, ask: at most 2, often none. A plain claim to answer yes or no, at most 15 words \
        ("Mitch reports to you."). kind is relationship, role, meeting_purpose, preference, or this_call. evidence \
        is the quote behind it, with its time. Never ask what is a fact, waiting for an answer, or marked not \
        true, and do not treat an open question as true.

        \(owner)'s guidance is standing instruction: follow it. Do not repeat advice they rejected.

        The full review, which \(owner) opens only for more: strengths and improvements hold at most 1 point \
        each, the evidence behind did_well and try_next, each observation under 40 words with a quote and its \
        time. Empty when those are null.

        meeting_value: was the meeting a good use of \(owner)'s time, for what it needed from them and what it \
        produced? reason is at most 20 words. suggestion is one sentence on what to change, "" when the action is \
        keep. Do not mark meetings low to seem rigorous.

        Your notes. patterns: only those this call showed, at most 4, with the exact name of a known pattern. \
        result is did when the call showed the good behavior, missed when it showed the habit to change. note is \
        what this call showed, at most 20 words; quote and at_seconds are \(owner)'s line that shows it, or "" and \
        null. Do not say how often: the app counts. people: at most 2 sentences on how \(owner) and each person \
        who spoke communicate.

        The transcript is from speech recognition: names, numbers, and speakers can be wrong. Do not coach on a \
        recognition error. "Speaker A" and similar labels are people whose names are not known.
        """
    }

    static func voiceRules(_ voice: CoachVoice, owner: String) -> String {
        switch voice {
        case .direct:
            "Voice: a candid peer. Plain, short, specific. Address \(owner) as \"you\". Say what to try (\"try\", \"next time you could\"), never \"you must\" or \"you should\". No labels about the person, no superlatives, no praise for its own sake, no scolding."
        case .warm:
            "Voice: a warm mentor with high standards. Encouraging and specific; show confidence that \(owner) can do it. Address them as \"you\". Say what to try, never \"you must\". No labels about the person and no scolding."
        case .data:
            "Voice: data only. Facts and numbers in clipped phrases, no encouragement and no opinion beyond the plan. Address \(owner) as \"you\"."
        }
    }

    static let recentCalls = 5
    static let knownPatterns = 8
    static let earlierAdviceRows = 12

    /// What the owner saw in the 30 days up to this call, one row for each skill, the newest first, with the id
    /// the model uses to say "this call showed it again".
    static func earlierAdvice(_ p: CoachProfile, record r: CallRecord) -> [(id: String, advice: CoachAdvice)] {
        var seen = Set<String>()
        let rows = p.advice.sorted { $0.date > $1.date }.filter { a in
            guard !a.held, a.kind == .tryNext || a.kind == .again, a.callID != r.id, abs(a.date.timeIntervalSince(r.start)) <= AdviceRules.repeatDays * 86_400 else { return false }
            return seen.insert(AdviceRules.key(a.skill)).inserted
        }
        return rows.prefix(earlierAdviceRows).enumerated().map { ("A\($0.offset + 1)", $0.element) }
    }

    static func earlierAdviceText(_ p: CoachProfile, record r: CallRecord) -> String {
        var parts = earlierAdvice(p, record: r).map { row -> String in
            let a = row.advice
            // An older review has no skill name: its advice is its own name.
            return "- \(row.id), \(day(a.date)), \(a.skill)" + (a.kind == .tryNext && a.text != a.skill ? ": \(a.text)" : "")
        }
        var praised = Set<String>()
        let praise = p.advice.filter { a in
            a.kind == .didWell && !a.held && a.callID != r.id && abs(a.date.timeIntervalSince(r.start)) <= AdviceRules.repeatDays * 86_400
                && praised.insert(AdviceRules.key(a.skill)).inserted
        }
        if !praise.isEmpty { parts.append("Praise you already gave: " + praise.suffix(earlierAdviceRows).map(\.skill).joined(separator: "; ")) }
        return parts.joined(separator: "\n")
    }

    static func user(record r: CallRecord, owner: String, profile: CoachProfile, delivery: DeliveryStats? = nil,
                     people titles: [String] = [], measured: CoachMeasured = CoachMeasured()) -> String {
        let delivery = delivery ?? DeliveryStats(record: r, owner: owner)
        var parts: [String] = []
        if !profile.facts.isEmpty {
            var about: [String] = profile.facts(.role).map { "Role: \($0.text)" }
            for kind in [CoachFact.Kind.responsibility, .goal, .relationship] where !profile.facts(kind).isEmpty {
                let label = switch kind { case .responsibility: "Responsible for:"; case .goal: "Goals:"; default: "Relationships:" }
                about.append(label + "\n" + profile.facts(kind).map { "- \($0.text)" }.joined(separator: "\n"))
            }
            parts.append("## Who \(owner) is\n" + about.joined(separator: "\n"))
        }

        var notes: [String] = []
        // The patterns of now, with what the log counted. The model's own old count and trend are not sent back.
        let patterns = profile.patterns.sorted { $0.lastSeen > $1.lastSeen }.prefix(knownPatterns)
        if !patterns.isEmpty {
            notes.append("Known patterns:\n" + patterns.map { "- \($0.name) (\($0.kind.rawValue)): \($0.note) \(profile.standing($0, now: r.start))" }.joined(separator: "\n"))
        }
        let recent = profile.history.filter { $0.callID != r.id }.suffix(recentCalls)
        if !recent.isEmpty {
            notes.append("Recent calls, oldest first:\n" + recent.map { "- \(day($0.date)) \($0.title): \($0.headline)" }.joined(separator: "\n"))
        }
        if !notes.isEmpty { parts.append("## Your notes on \(owner)\n" + notes.joined(separator: "\n")) }
        parts.append("## The focus\n" + focusText(profile))
        let said = earlierAdviceText(profile, record: r)
        if !said.isEmpty { parts.append("## Advice you already gave (do not give it again)\n" + said) }
        let asked = questionsText(profile)
        if !asked.isEmpty { parts.append("## Your questions to \(owner)\n" + asked) }
        if !profile.guidance.isEmpty {
            parts.append("## What \(owner) told you about your coaching (follow this)\n" + profile.guidance.map { "- \($0.text)" }.joined(separator: "\n"))
        }
        if !profile.rated.isEmpty {
            parts.append("## \(owner)'s ratings of your recent points\n" + profile.rated.suffix(15).map {
                "- \($0.agree ? "Right" : "Wrong"): \"\($0.title)\" (\($0.principle), \($0.callTitle))" + ($0.note.map { ". They said: \($0)" } ?? "")
            }.joined(separator: "\n"))
        }

        let here = Set(r.speakerNames.values).subtracting([owner])
        let people = profile.people.filter { here.contains($0.key) }.sorted { $0.key < $1.key }
        if !people.isEmpty {
            parts.append("## Your notes on the people in this call\n" + people.map {
                "- \($0.key) (\($0.value.calls) earlier calls): \($0.value.note)"
            }.joined(separator: "\n"))
        }

        if !titles.isEmpty { parts.append("## Job titles\n" + titles.map { "- \($0)" }.joined(separator: "\n")) }

        var meeting = ["Title: \(r.title)", "Date: \(day(r.start))", "Length: \(Int(r.end.timeIntervalSince(r.start) / 60)) min"]
        if let k = r.kind { meeting.append("Kind: \(k)") }
        if !r.attendees.isEmpty { meeting.append("Invited: \(r.attendees.joined(separator: ", "))") }
        if let h = r.headline { meeting.append("Summary: \(h)") }
        meeting.append("People who spoke: \(Set(r.speakerNames.values).count), including \(owner)")
        let spoke = delivery.talkSeconds < 60 ? "\(Int(delivery.talkSeconds)) s" : "\(Int((delivery.talkSeconds / 60).rounded())) min"
        meeting.append("\(owner) spoke for \(spoke) (\(Int((delivery.talkShare * 100).rounded()))% of the talk)")
        meeting.append("Decisions: \(r.decisions.count)")
        meeting.append("Action items for \(owner): \(r.actionItems.filter { $0.owner == owner }.count) of \(r.actionItems.count)")
        let earlier = profile.history.filter { $0.callID != r.id && $0.title.caseInsensitiveCompare(r.title) == .orderedSame }
        meeting.append("Earlier coached meetings with this title: \(earlier.count)"
                       + (earlier.compactMap(\.value).isEmpty ? "" : " (rated \(earlier.compactMap(\.value).map(\.rawValue).joined(separator: ", ")))"))
        parts.append("## This meeting\n" + meeting.joined(separator: "\n"))
        if CoachReview.isListener(delivery) {
            parts.append("## Listener mode\n\(owner) spoke for under a minute in this call. Review listening, missed chances to speak up, follow-ups, and the meeting's value, not delivery.")
        } else {
            parts.append("## Numbers the app measured in this call\n" + callNumbers(delivery, metrics: CallMetrics(record: r, owner: owner, history: []),
                                                                                    voice: profile.activeFocus?.metric == .pace))
        }
        var unusual = measured.standouts.map { "- \(owner) \($0.text)" }
        if let trend = measured.trend { unusual.append("- Over the last calls: \(trend.text) \(trend.proof)") }
        if let share = measured.commitments { unusual.append("- \(share.text).") }
        if !unusual.isEmpty { parts.append("## What the app measured against earlier meetings\n" + unusual.joined(separator: "\n")) }
        parts.append("## Transcript\n" + MarkdownWriter.transcript(r, screens: false))
        return parts.joined(separator: "\n\n")
    }

    /// What the coach asked: the ones still open, and the ones the owner said are not true. Answered ones are
    /// facts by now, so they are not repeated here.
    static func questionsText(_ p: CoachProfile) -> String {
        var parts: [String] = []
        let open = p.openQuestions
        if !open.isEmpty { parts.append("Waiting for an answer:\n" + open.map { "- \($0.statement)" }.joined(separator: "\n")) }
        let denied = p.questions.filter { $0.status == .rejected }.suffix(15)
        if !denied.isEmpty { parts.append("Not true:\n" + denied.map { "- \($0.statement)" }.joined(separator: "\n")) }
        return parts.joined(separator: "\n")
    }

    static func focusText(_ p: CoachProfile) -> String {
        if let f = p.activeFocus {
            let since = f.accepted.map { " (accepted \(day($0)))" } ?? ""
            let recent = f.results.suffix(6).map { "- \(day($0.date)): \($0.outcome.rawValue). \($0.evidence)" }
            return "Active focus\(since): \(f.plan)\nWhy: \(f.why)" + (recent.isEmpty ? "\nNo results yet." : "\nRecent results:\n" + recent.joined(separator: "\n"))
        }
        if let f = p.proposedFocus {
            return "No active focus. Proposed and waiting for the owner's answer: \(f.plan). Do not report progress on it, and do not propose another."
        }
        let learned = p.foci.filter { $0.status == .learned }.map(\.plan)
        let earlier = p.focus.nonBlank.map { " Your earlier note on what to work on, which the owner never agreed to, can be the start: \($0)" } ?? ""
        return "No focus and none proposed: propose one." + earlier + (learned.isEmpty ? "" : " Already learned: " + learned.joined(separator: "; "))
    }

    /// This call's numbers for the model: no goals from other people's research, and nothing to compare with.
    /// Fillers are not coached, and a count of lines with "?" counts "right?". The voice goes along only when
    /// the focus is about pace.
    static func callNumbers(_ d: DeliveryStats, metrics m: CallMetrics, voice: Bool) -> String {
        var parts = [String(format: "talk share %.0f%%", d.talkShare * 100), String(format: "%.0f words per minute", d.wordsPerMinute),
                     "longest turn \(Int(m.longestTurn?.seconds ?? d.longestTurnSeconds)) s",
                     "interrupted others \(d.interruptions) times", "was interrupted \(d.interrupted) times"]
        if voice, let t = d.tone {
            parts.append(String(format: "voice: pitch variation %.1f semitones, turn ends %.1f dB quieter", t.pitchVariation, t.endDrop))
        }
        return parts.joined(separator: ", ")
            + (m.longTurns.isEmpty ? "" : "\nTurns over 2 min at: " + m.longTurns.map { clock($0.start) + " (\(Int($0.seconds)) s)" }.joined(separator: ", "))
    }

    private static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func numbers(_ d: DeliveryStats) -> String {
        [String(format: "talk share %.0f%%", d.talkShare * 100),
         String(format: "%.0f words per minute", d.wordsPerMinute),
         String(format: "fastest turn %.0f wpm", d.fastestWordsPerMinute),
         String(format: "%.1f fillers per minute", d.fillersPerMinute),
         "longest turn \(Int(d.longestTurnSeconds)) s",
         "\(d.questions) questions",
         "interrupted others \(d.interruptions) times",
         "was interrupted \(d.interrupted) times"].joined(separator: ", ")
            + (d.tone.map { t in
                String(format: "; voice: pitch %.0f Hz, pitch variation %.1f semitones, level %.0f dBFS, loudness range %.0f dB, turn ends %.1f dB quieter",
                       t.medianPitch, t.pitchVariation, t.level, t.loudnessRange, t.endDrop)
            } ?? "")
    }

    private static func day(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day())
    }
}
