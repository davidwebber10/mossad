import Foundation

extension ChatTools {
    static var currentCallDefinition: ToolSpec {
        ToolSpec(name: "current_call",
                 description: "Reads the call that is recording right now: its title, invited people, how long it has run, and the live transcript so far with times. The owner's lines use their name; the other people are Speaker A, Speaker B, and so on (Others when not yet known), or a name from the voice library, which can change or go as the call goes on; so use the invite and the context to tell who is who. A label with a number, such as Speaker A2, is a voice after a pause or a new connection; it can be a person who had a name or another label earlier in the call. Times are minutes:seconds of the recording, which leaves out any pause. Use it for \"what was just said\", \"they just asked me to\", or anything about the meeting happening now. The live transcript can misspell words; the full note comes after the call.",
                 schema: ["type": "object", "properties": [
                    "minutes": ["type": "number", "description": "Only the last this many minutes. Leave out for the whole call."],
                 ] as [String: Any]])
    }

    func currentCall(minutes: Double?, now: Date = Date()) -> String {
        guard let r = live, let paths else { return "No call is recording now." }
        let clockTime = now.timeIntervalSince(r.start)
        let url = paths.callDirectory(r.id).appendingPathComponent(LiveTranscript.fileName)
        let transcript = try? LiveTranscript.load(from: url)
        // The lines count seconds of the recording, which leave the pauses out: "the last 5 minutes" counts the same.
        let elapsed = transcript?.recordedNow(at: now) ?? clockTime
        var parts = ["\(r.calendarTitle ?? r.title) | \(r.platform.displayName) | started \(r.start.formatted(date: .omitted, time: .shortened)) | \(Int(elapsed / 60)) min recorded so far"]
        if let pause = LiveChatPrompt.pauseNote(clock: clockTime, recorded: elapsed) { parts.append(pause) }
        if !r.attendees.isEmpty { parts.append("Invited: \(r.attendees.joined(separator: ", "))") }
        guard let transcript else {
            if let points = livePoints(r, heard: []) { parts.append(points) }
            parts.append("No live transcript yet. It needs Live transcript on in Settings and an AssemblyAI key; the full transcript comes after the call.")
            return parts.joined(separator: "\n")
        }
        if let points = livePoints(r, heard: Array(Set(transcript.voiceNames.values))) { parts.append(points) }
        let text = transcript.text(owner: owner, since: minutes.map { elapsed - $0 * 60 })
        parts.append(text.isEmpty ? "Nothing said in that time." : "Transcript (minutes:seconds into the recording):\n" + text)
        return parts.joined(separator: "\n")
    }

    /// "Your points" of the call that records now, as its panel lists them: the series' and each person's, with
    /// the owner's ticks and what Mossad heard. The check after the call decides.
    /// The call's own points, as its panel lists them (`LivePoints`).
    func livePointList(_ r: CallRecord, heard: [String] = []) -> [NextTimePoint] {
        guard let book else { return [] }
        let (all, _, snapshot) = catalog(now: now)
        let series = LivePoints.series(ofLive: r, in: all, records: records, owner: owner, directory: PersonDirectory(profiles: profiles),
                                       ownerEmails: [settings.ownerEmail], aliases: SeriesCatalog.aliases(snapshot?.calendarEvents ?? []))
        let names = heard.isEmpty ? Array(Set(r.speakerNames.values)) : heard
        let people = LivePoints.personIDs(attendees: r.attendees, heard: names, people: saved)
        return LivePoints.list(book, series: series, people: people, callID: r.id, canonical: saved.canonical)
    }

    func livePoints(_ r: CallRecord, heard: [String]) -> String? {
        guard let paths else { return nil }
        let list = livePointList(r, heard: heard)
        guard !list.isEmpty else { return nil }
        let marks = LivePointMarks.load(from: paths.callDirectory(r.id)) ?? LivePointMarks()
        return "Your points for this call:\n" + list.map { p in
            var line = "- \(p.text) (point_id: \(p.id.uuidString))"
            if p.done?.callID == r.id { line += " | ticked by the owner" } else if let m = marks.mark(for: p.id) { line += " | Mossad heard it raised at \(MarkdownWriter.timestamp(m.at)), not yet sure" }
            return line
        }.joined(separator: "\n")
    }
}
