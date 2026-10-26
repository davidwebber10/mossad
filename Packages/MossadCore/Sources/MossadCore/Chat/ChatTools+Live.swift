import Foundation

extension ChatTools {
    static var currentCallDefinition: ToolSpec {
        ToolSpec(name: "current_call",
                 description: "Reads the call that is recording right now: its title, invited people, how long it has run, and the live transcript so far with times. The owner's lines use their name; the other people are Speaker A, Speaker B, and so on (Others when not yet known), so use the invite and the context to tell who is who. Use it for \"what was just said\", \"they just asked me to\", or anything about the meeting happening now. The live transcript can misspell words; the full note comes after the call.",
                 schema: ["type": "object", "properties": [
                    "minutes": ["type": "number", "description": "Only the last this many minutes. Leave out for the whole call."],
                 ] as [String: Any]])
    }

    func currentCall(minutes: Double?, now: Date = Date()) -> String {
        guard let r = live, let paths else { return "No call is recording now." }
        let elapsed = now.timeIntervalSince(r.start)
        var parts = ["\(r.calendarTitle ?? r.title) | \(r.platform.displayName) | started \(r.start.formatted(date: .omitted, time: .shortened)) | \(Int(elapsed / 60)) min so far"]
        if !r.attendees.isEmpty { parts.append("Invited: \(r.attendees.joined(separator: ", "))") }
        let url = paths.callDirectory(r.id).appendingPathComponent(LiveTranscript.fileName)
        guard let transcript = try? LiveTranscript.load(from: url) else {
            parts.append("No live transcript yet. It needs Live transcript on in Settings and an AssemblyAI key; the full transcript comes after the call.")
            return parts.joined(separator: "\n")
        }
        let text = transcript.text(owner: owner, since: minutes.map { elapsed - $0 * 60 })
        parts.append(text.isEmpty ? "Nothing said in that time." : "Transcript (minutes:seconds into the call):\n" + text)
        return parts.joined(separator: "\n")
    }
}
