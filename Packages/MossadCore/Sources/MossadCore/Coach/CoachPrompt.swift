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
        - Proof: quote is \(owner)'s own words, copied exactly from one of their lines, 3 to 12 words; \
        at_seconds is the time of that line ([00:12:40] is 760). The app looks for the quote in \(owner)'s lines \
        and drops a note it cannot prove. Never quote another person.
        - skill: the one key that fits the behavior. \(skills) Use the same key each time for the same behavior. \
        skill_label is "" unless the key is other; then it names the behavior in 2 to 5 words, the same words \
        each time.

        Never say a thing twice. Do not give advice with a skill from "Advice you already gave", in any words, and \
        do not repeat praise. When this call shows that skill again, put it in seen_again with \(owner)'s quote \
        and its time; the app counts it. Then write try_next about another skill, or null.

        Never judge a trend. Do not write that something improved, got worse, happened again, or changed against \
        earlier calls. The app measures what is usual and each trend, and shows them itself.

        Stay quiet when there is little to say. When \(owner) mostly listened, or the call was routine, set quiet \
        to true and leave did_well and try_next null unless one is clearly worth it. Do not invent strengths or \
        problems. Listening, asking the one question that mattered, or claiming work that is theirs can be a did_well.

        The focus. \(owner) works on one thing at a time, and only on a focus they accepted.
        - With an active focus, set focus_result: hit when the call shows the plan carried out, missed when a clear \
        chance came and passed, no_chance otherwise. evidence is one sentence of at most 20 words about this call. \
        quote and at_seconds are \(owner)'s own line that shows it, as above, or "" and null for no_chance. Do not \
        restate the focus, and do not give try_next for the focus's skill.
        - With no focus and none proposed, propose one in focus_proposal: the most valuable habit from the patterns, \
        as a when-then plan of at most 20 words, a why of at most 25 words, a metric when talk_share, longest_turn, \
        questions, or pace measures it, and its skill as above. Otherwise null.
        - Never claim progress on something \(owner) never agreed to work on.

        Use a number only when it explains something in the transcript. Do not coach filler words or pace. Judge against what this meeting needed: a \
        1:1, a working session, a monthly update, and a negotiation need different behavior. You know \(owner)'s \
        role, responsibilities, goals, and relationships: something unowned or at risk in their area is theirs to \
        act on. Advice about another person is how \(owner) can work with them better, never a judgment of character.

        Questions. When you conclude something about \(owner)'s world that would change your advice, and the \
        material does not say it, ask: at most 2, often none. A plain claim to answer yes or no, at most 15 words \
        ("Sam reports to you."). kind is relationship, role, meeting_purpose, preference, or this_call. evidence \
        is the quote behind it, with its time. person is the full name of the one person the claim is about, \
        exactly as their lines are labeled in the transcript, or null when it is about no one person. Never ask what \
        is a fact, waiting for an answer, not confirmed, or marked not true, and do not treat an open question as true.

        \(owner)'s guidance is standing instruction: follow it. Do not repeat advice they rejected. \(owner) also \
        answers your findings with yes, no, or never again: the material says which skills were useful to them, \
        which were less useful (give those only for a clear moment), and which to never coach, praise, or offer again.

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

    /// "commitment-dates (a day or a date for ...); answer-first (...); ..."
    static var skills: String { CoachSkill.allCases.map { "\($0.rawValue) (\($0.hint))" }.joined(separator: "; ") + "." }

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

    /// The skills that got a line in the 30 days around this call, one row for each, the newest first: what
    /// the model must not give again. The focus that waits for an answer is one of them.
    static func earlierAdvice(_ p: CoachProfile, record r: CallRecord, kinds: Set<CoachLine.Kind> = [.tryNext, .again]) -> [CoachAdvice] {
        var seen = Set<String>()
        // A skill that the owner said no to a few times waits longer, as in `CoachLineRules`.
        let training = p.training(asOf: r.start)
        return AdviceRules.said(p).sorted { $0.date > $1.date }.filter { a in
            guard !a.held, a.shown, kinds.contains(a.kind), a.callID != r.id,
                  abs(a.date.timeIntervalSince(r.start)) <= training.repeatDays(a.skill) * 86_400 else { return false }
            return seen.insert(AdviceRules.key(a.skill)).inserted
        }
    }

    private static func named(_ skill: String) -> String {
        if skill.hasPrefix("other:") { return "other, skill_label \"\(skill.dropFirst(6))\"" }
        if skill.hasPrefix("pattern:") { return "the pattern \"\(skill.dropFirst(8))\"" }
        if skill.hasPrefix("number:") { return "the number \(skill.dropFirst(7))" }
        return skill
    }

    /// What the owner's answers to the cards say for this review: the skills that were useful, the ones that were
    /// less useful, and what was blocked for good. Empty with no such answer.
    static func trainingText(_ p: CoachProfile, record r: CallRecord) -> String {
        let training = p.training(asOf: r.start)
        // The ids as they were written, by their key.
        var ids: [String: String] = [:]
        for a in p.answers where a.verdict != nil { ids[AdviceRules.key(a.skill)] = ids[AdviceRules.key(a.skill)] ?? a.skill }
        func list(_ keys: some Sequence<String>) -> String { keys.sorted().map { named(ids[$0] ?? $0) }.joined(separator: "; ") }
        var parts: [String] = []
        let useful = training.weights.filter { $0.value >= CoachTraining.raised }.keys, less = training.weights.filter { $0.value <= CoachTraining.lowered }.keys
        if !useful.isEmpty { parts.append("Useful to them: \(list(useful)).") }
        if !less.isEmpty { parts.append("Less useful to them, only for a clear moment: \(list(less)).") }
        if !training.blocked.isEmpty { parts.append("Never again, do not coach, praise, or mention: \(list(training.blocked)).") }
        if !training.blockedGoals.isEmpty { parts.append("Never offer as a focus: \(list(training.blockedGoals)).") }
        // The reasons for a no, each with its subject. A reason about a person goes with that person.
        let reasons = p.whyRules.filter { $0.person == nil }
        if !reasons.isEmpty {
            parts.append("Their reasons for a no to a card (for that subject only):\n"
                         + reasons.map { "- " + ($0.skill.map { "\(named($0)): " } ?? "") + $0.text }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }

    private static func named(_ a: CoachAdvice) -> String {
        a.skill.hasPrefix("other:") ? "other, skill_label \"\(a.skill.dropFirst(6))\"" : a.skill
    }

    static func earlierAdviceText(_ p: CoachProfile, record r: CallRecord) -> String {
        var parts = earlierAdvice(p, record: r).prefix(earlierAdviceRows).map { "- \(named($0)), last said \(day($0.date))" }
        let praise = earlierAdvice(p, record: r, kinds: [.didWell]).prefix(earlierAdviceRows)
        if !praise.isEmpty { parts.append("Praise you already gave: " + praise.map(named).joined(separator: "; ")) }
        return parts.joined(separator: "\n")
    }

    /// `saved` are the saved people: with them, what the coach knows of a person in the call is read by that
    /// person's id, under any name.
    static func user(record r: CallRecord, owner: String, profile: CoachProfile, delivery: DeliveryStats? = nil,
                     people titles: [String] = [], measured: CoachMeasured = CoachMeasured(), saved: CoachPeople = .none) -> String {
        let delivery = delivery ?? DeliveryStats(record: r, owner: owner)
        var parts: [String] = []
        if !profile.facts.isEmpty {
            var about: [String] = profile.facts(.role).map { "Role: \($0.text)" }
            for kind in [CoachFact.Kind.responsibility, .goal, .relationship, .context] where !profile.facts(kind).isEmpty {
                let label = switch kind { case .responsibility: "Responsible for:"; case .goal: "Goals:"; case .context: "Confirmed context:"; default: "Relationships:" }
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
        parts.append("## The focus\n" + focusText(profile, measured: measured, now: r.start))
        let said = earlierAdviceText(profile, record: r)
        if !said.isEmpty { parts.append("## Advice you already gave (do not give it again)\n" + said) }
        let asked = questionsText(profile, now: r.start)
        if !asked.isEmpty { parts.append("## Your questions to \(owner)\n" + asked) }
        // A conclusion about this one call that the owner confirmed: for a new review of the same call only.
        let thisCall = profile.questions.filter { $0.kind == .thisCall && $0.callID == r.id && ($0.status == .confirmed || $0.status == .corrected) }
        if !thisCall.isEmpty {
            parts.append("## What \(owner) confirmed about this call\n" + thisCall.map { "- " + ($0.status == .corrected ? $0.note ?? $0.statement : $0.statement) }.joined(separator: "\n"))
        }
        if !profile.ownGuidance.isEmpty {
            parts.append("## What \(owner) told you about your coaching (follow this)\n" + profile.ownGuidance.map { "- \($0.text)" }.joined(separator: "\n"))
        }
        let answered = trainingText(profile, record: r)
        if !answered.isEmpty { parts.append("## How \(owner) answered your findings (follow this)\n" + answered) }
        if !profile.rated.isEmpty {
            parts.append("## \(owner)'s ratings of your recent points\n" + profile.rated.suffix(15).map {
                "- \($0.agree ? "Right" : "Wrong"): \"\($0.title)\" (\($0.principle), \($0.callTitle))" + ($0.note.map { ". They said: \($0)" } ?? "")
            }.joined(separator: "\n"))
        }

        // What is known of each person who spoke: the note, and what the owner confirmed or said about them.
        let people = Set(r.speakerNames.values).subtracting([owner]).sorted().compactMap { name -> String? in
            let id = saved.id(of: name)
            var lines: [String] = []
            if let note = profile.note(on: name, people: saved)?.value, note.note.nonBlank != nil {
                lines.append("- \(name) (\(note.calls) earlier calls): \(note.note)")
            }
            if let id {
                lines += profile.learnings(about: id, people: saved).map { "  Confirmed by \(owner): \($0.text)" }
                lines += profile.guidance(about: id, people: saved).map { "  \(owner) told you: \($0.text)" }
            }
            guard !lines.isEmpty else { return nil }
            if !lines[0].hasPrefix("- ") { lines.insert("- \(name)", at: 0) }
            return lines.joined(separator: "\n")
        }
        if !people.isEmpty { parts.append("## Your notes on the people in this call\n" + people.joined(separator: "\n")) }

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
            parts.append("## Numbers the app measured in this call\n" + callNumbers(delivery, longestTurn: measured.longestTurn, voice: profile.activeFocus?.metric == .pace))
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
    static func questionsText(_ p: CoachProfile, now: Date) -> String {
        var parts: [String] = []
        let open = p.openQuestions
        if !open.isEmpty { parts.append("Waiting for an answer:\n" + open.map { "- \($0.statement)" }.joined(separator: "\n")) }
        // A plain no to a card: one signal. It is not "not true", and it is not to be asked again for the days of
        // the repeat rule. After them the coach may ask it again.
        let unsure = p.questions.filter { q in
            q.status == .open && q.dismissed.map { now.timeIntervalSince($0) < AdviceRules.repeatDays * 86_400 } == true
        }.suffix(10)
        if !unsure.isEmpty { parts.append("Not confirmed (do not treat as true, and do not ask again now):\n" + unsure.map { "- \($0.statement)" }.joined(separator: "\n")) }
        let denied = p.questions.filter { $0.status == .rejected }.suffix(15)
        if !denied.isEmpty { parts.append("Not true:\n" + denied.map { "- \($0.statement)" }.joined(separator: "\n")) }
        return parts.joined(separator: "\n")
    }

    static func focusText(_ p: CoachProfile, measured: CoachMeasured = CoachMeasured(), now: Date = Date()) -> String {
        if let f = p.activeFocus, let goal = f.goal, let measure = goal.measure {
            // A goal that the app measures: the numbers are the app's, and the model gives only the moment.
            var lines = ["Active goal" + (f.accepted.map { " (accepted \(day($0)))" } ?? "") + ": \(f.plan)",
                         "The app measures it: \(measure.title.lowercased()). Before the goal: \(goal.typicalText) (\(goal.usualText)). Target: \(goal.targetText)."]
            if let r = measured.goalResult {
                let outcome = r.outcome == .hit ? "hit" : "missed"
                lines.append("The app's result for this call: \(outcome). \(r.evidence) The target is \(goal.targetText).")
                lines.append("In focus_result, use the outcome \(outcome) and give the one moment of the owner's that shows it: "
                             + (r.outcome == .hit ? "a moment that gave the other person room (a question, a handover, a pause for them)."
                                                  : "a moment that took the room (a long turn, talking over them, answering for them)."))
            } else {
                lines.append("This call is not a 1:1 the app can measure, so the goal does not apply: set focus_result to no_chance.")
            }
            if let progress = measured.goal { lines.append("Progress, measured by the app (do not restate or judge it): \(progress.sentence).") }
            return lines.joined(separator: "\n")
        }
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
        // The goal of room in 1:1s is the app's; a goal the owner declined, ended, or learned rests.
        let resting = Set(p.foci.map(\.skillID).filter { GoalOffers.rests($0, profile: p, at: now) }).union([GoalOffers.skill]).sorted()
        return "No focus and none proposed: propose one." + earlier + (learned.isEmpty ? "" : " Already learned: " + learned.joined(separator: "; "))
            + " Do not propose a focus with the skill " + resting.joined(separator: ", ") + "."
    }

    /// This call's numbers for the model: no goals from other people's research, and nothing to compare with.
    /// Fillers are not coached, and a count of lines with "?" counts "right?". The longest turn is the one of
    /// the Analytics baselines when the app measured it, so the model gets one value for it. Pace and the voice
    /// go along only when the focus is about pace.
    static func callNumbers(_ d: DeliveryStats, longestTurn: TimeInterval?, voice: Bool) -> String {
        var parts = [String(format: "talk share %.0f%%", d.talkShare * 100), "longest turn \(Int(longestTurn ?? d.longestTurnSeconds)) s",
                     "interrupted others \(d.interruptions) times", "was interrupted \(d.interrupted) times"]
        if voice {
            parts.append(String(format: "%.0f words per minute", d.wordsPerMinute))
            if let t = d.tone { parts.append(String(format: "voice: pitch variation %.1f semitones, turn ends %.1f dB quieter", t.pitchVariation, t.endDrop)) }
        }
        return parts.joined(separator: ", ")
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
