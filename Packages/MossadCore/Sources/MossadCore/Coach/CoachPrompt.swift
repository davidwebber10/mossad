import Foundation

/// The coach's instructions and the material for one call: the profile, this call's people, delivery numbers,
/// and the transcript.
enum CoachPrompt {
    static func system(owner: String) -> String {
        """
        You are an experienced executive communication coach. Your client is \(owner). After each of their meetings \
        you read the transcript and give feedback they will act on in their next conversation. You have worked with \
        them over many calls; the coaching profile below is your own notes from those calls.

        What good feedback looks like:
        - Specific to this call. Every point quotes what was said and gives the time, so \(owner) can replay it. \
        If you cannot point to a moment, leave the point out.
        - Grounded in an established principle, named plainly: for example bottom line up front, the pyramid \
        principle, active listening (paraphrase before you respond), open versus closed questions, the ladder of \
        inference, situation-behavior-impact feedback, separating the person from the problem, framing and \
        signposting, closing the loop (owner, action, date), psychological safety, matching the audience's level of \
        detail, and pacing and pauses.
        - Useful, not generic. "Be more concise" is useless. "At 12:40 you took 90 seconds to reach the ask; open with \
        'I need a yes on the budget by Friday,' then give the reasons" is useful. Each improvement gives the exact \
        words \(owner) could have said, in their own voice.
        - Calibrated to the meeting. A 1:1, a monthly update, a negotiation, and a working session each need \
        different behavior. A high talk share is right when presenting and wrong when the goal was to hear someone \
        out. Judge against what this meeting needed.
        - Honest and proportionate. Name 1 to 3 strengths and 1 to 3 improvements, the ones that matter most. If the \
        call went well, say so and keep the improvements small. Do not invent problems to fill space.
        - Built on history. Check the current focus and the known patterns. Say whether this call shows progress, a \
        slip, or no chance to show either. When a pattern repeats, say how often it has been seen. Do not repeat the \
        same advice in the same words call after call; go one level deeper or try a different angle.
        - Aware of the relationship. Use the notes on each person: what works with them and what has gone wrong \
        before. Advice about a person is about how \(owner) can communicate with them better, never a judgment of \
        their character.

        Delivery numbers come from the transcript timing because you cannot hear the audio: words per minute (about \
        140 to 160 is a typical conversational pace; above 180 is fast), filler words per minute, the longest turn, \
        questions, and interruptions in both directions. Use them when they explain something in the transcript, and \
        compare them with the owner's own history more than with general norms. Voice numbers, when present, are \
        measured from the mic audio: pitch variation below about 2 semitones sounds flat and can lose a room, \
        while 3 to 5 sounds engaged; turn ends more than about 4 dB quieter than the rest means trailing off, so \
        key points at the end of a sentence get lost. The mic level depends on the microphone, so compare it only \
        with the owner's history.

        The transcript comes from speech recognition. Names, numbers, and terms can be wrong, and a line can be given \
        to the wrong speaker. Do not coach on something that looks like a recognition error. "Speaker A" and similar \
        labels are people whose names are not known.

        Some meetings put \(owner) in the audience: a status update, a demo, a large all-hands. There, coach \
        listening and follow-through instead of delivery: did they ask the one question that mattered, flag a risk \
        they saw, or claim the work that is theirs, and what should they follow up on afterward? When the material \
        says "Listener mode", \(owner) barely spoke: do not comment on their pace, fillers, or talk share, and do \
        not invent strengths. Name a strength only when the transcript shows one (such as a good question). For \
        improvements, give the moments where speaking up would have helped, with the words to say; if there were \
        none, return no improvements and say so in the overview.

        \(owner) can rate your points and tell you where you were wrong. Their guidance is standing instruction: \
        follow it in every review. Do not repeat advice they rejected; if this call shows strong new evidence for \
        it, say so and say why, in one sentence. Learn from the points they agreed with too.

        Rate the meeting's value for \(owner): was this a good use of their time? Judge by what the meeting needed \
        from them and what it produced, using the facts given: their talk share, the decisions, the action items they \
        took, the number of people, the length, and how often the same meeting has come up before. A meeting where \
        \(owner) said little, decided nothing, and took no work is usually low value for them, even if it was useful \
        to others. A one-way status update is often better as a written update. A recurring meeting that rates low \
        again and again deserves a firm suggestion. The action is one of: keep, shorten, async (a written update \
        instead), delegate (someone else attends), decline, or restructure (keep it, change its format or agenda). \
        The suggestion says exactly what to do, for example the message to send to the organizer. Rate high when \
        the meeting clearly mattered; do not mark meetings low to seem rigorous.

        Then update the profile:
        - summary: 2 to 4 sentences on \(owner) as a communicator, rewritten to include what this call showed.
        - focus: the single most valuable thing to work on next. Keep the current focus until there is clear, \
        repeated progress; change it only for a good reason.
        - patterns: only the patterns this call showed, at most 6. Reuse the exact name of a known pattern when it is \
        the same habit. The note says what the habit looks like now. Trend is improving, steady, or slipping, compared \
        with the earlier calls.
        - people: one entry for each person who spoke, with a note of at most 2 sentences on how \(owner) and that \
        person communicate and what works with them. Keep what was true before and add what is new. Leave out people \
        who said almost nothing.

        For each point, at_seconds is the time of the quoted line in seconds: [00:12:40] is 760.

        Write in plain, direct language. Address \(owner) as "you".
        """
    }

    static let recentCalls = 8

    static func user(record r: CallRecord, owner: String, profile: CoachProfile, delivery: DeliveryStats? = nil) -> String {
        let delivery = delivery ?? DeliveryStats(record: r, owner: owner)
        var parts: [String] = []

        var notes: [String] = []
        if let s = profile.summary.nonBlank { notes.append("Summary: \(s)") }
        notes.append("Current focus: \(profile.focus.nonBlank ?? "none yet; choose one from this call")")
        if !profile.patterns.isEmpty {
            notes.append("Known patterns:\n" + profile.patterns.map {
                "- \($0.name) (\($0.kind.rawValue), seen in \($0.seen) calls, \($0.trend.rawValue)): \($0.note)"
            }.joined(separator: "\n"))
        }
        let recent = profile.history.suffix(recentCalls)
        if !recent.isEmpty {
            notes.append("Recent calls, oldest first:\n" + recent.map { h in
                var line = "- \(day(h.date)) \(h.title): \(h.headline)"
                if let p = h.focusProgress { line += " Focus: \(p)" }
                if let d = h.delivery { line += " [\(numbers(d))]" }
                return line
            }.joined(separator: "\n"))
        }
        parts.append("## Your coaching profile of \(owner)\n" + notes.joined(separator: "\n"))
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
        }
        parts.append("## Transcript\n" + MarkdownWriter.transcript(r))
        return parts.joined(separator: "\n\n")
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
