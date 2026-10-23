import Foundation

/// The coach's instructions and the material for one call: the profile, this call's people, delivery numbers,
/// and the transcript.
enum CoachPrompt {
    static func system(owner: String, voice: CoachVoice = .direct) -> String {
        """
        You are \(owner)'s communication coach. After each of their meetings you read the transcript and leave a \
        short note they can take in within 15 seconds. You have worked with them over many calls; the material below \
        holds your notes, the focus they agreed to work on, and numbers the app measured.

        \(voiceRules(voice, owner: owner))

        The note has three lines, each one or two sentences and at most 30 words:
        - did_well: the one move that mattered most, about a behavior, not a trait. Quote it and give its time.
        - improving: only when the numbers or the focus results show a measured change against earlier calls. Name \
        the comparison ("longest turn 91 s, down from 152 s"). Otherwise null. Never say "better" without the evidence.
        - try_next: one forward plan for the next meeting, written as when-then ("When someone asks what's next, \
        say your items first, each with a day"). Point to the moment in this call that shows why, and put the exact \
        words \(owner) could say in "say", in their own voice. Tie it to the focus when the call gave a chance to.
        headline: at most 12 words, the call in one line.

        Stay quiet when there is little to say. When \(owner) mostly listened, or the call was routine and nothing \
        stood out, set quiet to true, keep the headline, and leave the three lines null unless one is clearly worth \
        it. Do not invent strengths or problems to fill space. Listening, asking the one question that mattered, or \
        claiming work that is theirs can still be worth a did_well.

        The focus. \(owner) works on one thing at a time, and only on a focus they accepted.
        - When the material shows an active focus, set focus_result: hit when the call shows the plan carried out, \
        missed when a clear chance came and passed, no_chance when the call gave no chance to show it. evidence is \
        one sentence with the time. Do not change or restate the focus.
        - When the material says there is no focus and none proposed, propose one in focus_proposal: the single most \
        valuable habit from the patterns across calls, as a when-then plan of at most 20 words, a why of at most 25 \
        words grounded in how often you have seen it, and a metric when one of talk_share, longest_turn, questions, or \
        pace measures it. Otherwise focus_proposal is null.
        - Never claim progress on something \(owner) never agreed to work on.

        Numbers. The app measured talk share, longest turn, questions, and pace against goals and against \
        \(owner)'s usual. Use them only when they explain something in the transcript. Do not repeat every number. \
        Do not coach filler words. Pace matters only when it is far above their usual. Voice numbers, when present, \
        come from the mic: pitch variation under about 2 semitones sounds flat, turn ends more than about 4 dB quieter \
        mean trailing off.

        Judge against what this meeting needed. A 1:1, a working session, a monthly update, and a negotiation need \
        different behavior. You know who \(owner) is: their role, what they are responsible for, their goals, and \
        their relationships. When something in their area is unowned, unclear, or at risk, that is theirs to act on. \
        Advice about another person is about how \(owner) can work with them better, never a judgment of character.

        \(owner) can rate your points and tell you where you were wrong. Their guidance is standing instruction: \
        follow it. Do not repeat advice they rejected.

        Detail for "More from the coach": strengths and improvements hold at most 2 points each, the evidence behind \
        the three lines, each observation under 60 words with a quote and its time. at_seconds is the time of the \
        quoted line in seconds: [00:12:40] is 760.

        Rate the meeting's value for \(owner): was it a good use of their time, given what it needed from them and \
        what it produced? A one-way status update is often better as a written update; a recurring meeting that \
        rates low again and again deserves a firm suggestion. The action is keep, shorten, async, delegate, decline, \
        or restructure, and the suggestion says exactly what to do. Do not mark meetings low to seem rigorous.

        Then update your notes: summary (2 to 4 sentences on \(owner) as a communicator), patterns (only those this \
        call showed, at most 6, reusing the exact name of a known pattern), and people (a note of at most 2 sentences \
        on how \(owner) and each person who spoke communicate).

        The transcript comes from speech recognition: names, numbers, and speakers can be wrong. Do not coach on \
        what looks like a recognition error. "Speaker A" and similar labels are people whose names are not known.
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

    static let recentCalls = 8

    static func user(record r: CallRecord, owner: String, profile: CoachProfile, delivery: DeliveryStats? = nil,
                     metrics: CallMetrics? = nil) -> String {
        let delivery = delivery ?? DeliveryStats(record: r, owner: owner)
        let metrics = metrics ?? CallMetrics(record: r, owner: owner, history: profile.history.compactMap(\.delivery))
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
        if let s = profile.summary.nonBlank { notes.append("Summary: \(s)") }
        if !profile.patterns.isEmpty {
            notes.append("Known patterns:\n" + profile.patterns.map {
                "- \($0.name) (\($0.kind.rawValue), seen in \($0.seen) calls, \($0.trend.rawValue)): \($0.note)"
            }.joined(separator: "\n"))
        }
        let recent = profile.history.suffix(recentCalls)
        if !recent.isEmpty {
            notes.append("Recent calls, oldest first:\n" + recent.map { h in
                var line = "- \(day(h.date)) \(h.title)\(h.score.map { " (scored \($0)/5)" } ?? ""): \(h.headline)"
                if let p = h.focusProgress { line += " Focus: \(p)" }
                if let d = h.delivery { line += " [\(numbers(d))]" }
                return line
            }.joined(separator: "\n"))
        }
        parts.append("## Your coaching profile of \(owner)\n" + notes.joined(separator: "\n"))
        parts.append("## The focus\n" + focusText(profile))
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
            parts.append("## \(owner)'s delivery in this call\n" + numbers(delivery))
            parts.append("## Measured against goals\n" + checksText(metrics))
        }
        parts.append("## Transcript\n" + MarkdownWriter.transcript(r))
        return parts.joined(separator: "\n\n")
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

    static func checksText(_ m: CallMetrics) -> String {
        m.checks.map { c in
            let value: String = switch c.metric {
            case .talkShare: "talk share \(Int((c.value * 100).rounded()))%"
            case .longestTurn: "longest turn \(Int(c.value)) s"
            case .questions: "\(Int(c.value)) questions"
            case .pace: "\(Int(c.value)) words per minute"
            }
            let usual: String = c.usual.map { u in
                switch c.metric {
                case .talkShare: ", usual \(Int((u * 100).rounded()))%"
                case .longestTurn: ", usual \(Int(u)) s"
                case .questions: ", usual \(Int(u.rounded()))"
                case .pace: ", usual \(Int(u))"
                }
            } ?? ""
            let state = switch c.status { case .good: "within goal"; case .over: "over goal"; case .info: "for reference" }
            return "- \(value) (goal: \(c.goal)\(usual)): \(state)"
        }.joined(separator: "\n") + (m.longTurns.isEmpty ? "" : "\nTurns over 2 min at: " + m.longTurns.map { clock($0.start) + " (\(Int($0.seconds)) s)" }.joined(separator: ", "))
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
