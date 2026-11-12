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
            parts.append("No live transcript yet. It needs Live transcript on in Settings and an AssemblyAI key; the full transcript comes after the call.")
            return parts.joined(separator: "\n")
        }
        let text = transcript.text(owner: owner, since: minutes.map { elapsed - $0 * 60 })
        parts.append(text.isEmpty ? "Nothing said in that time." : "Transcript (minutes:seconds into the recording):\n" + text)
        return parts.joined(separator: "\n")
    }
}
