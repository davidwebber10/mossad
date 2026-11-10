import Foundation

extension ChatTools {
    /// Screens exist only where calls are recorded. The iPhone gets no frames, so its chat does not list the tools.
    static var screenDefinitions: [ToolSpec] {
        #if os(macOS)
        screenToolSpecs
        #else
        []
        #endif
    }

    static var screenToolSpecs: [ToolSpec] { [
        ToolSpec(name: "list_screens",
                 description: "Lists the screens that were shared in one meeting: each time someone shared (start, end, who shared when the call app showed it), and each kept frame with its index, its time in seconds, and the text that was on it. Only meetings recorded on this Mac with \"Capture shared screens\" on have screens.",
                 schema: ["type": "object", "properties": ["meeting_id": ["type": "string", "description": "The meeting's call_id."]],
                          "required": ["meeting_id"]]),
        ToolSpec(name: "get_screen",
                 description: "Reads one shared screen of a meeting: the text on it, who shared it when known, and what was said from 30 seconds before to 30 seconds after. Pick it by index (from list_screens) or by at_seconds (the nearest frame). include_image adds the picture itself, for apps connected over MCP; leave it false unless the text is not enough.",
                 schema: ["type": "object", "properties": [
                    "meeting_id": ["type": "string", "description": "The meeting's call_id."],
                    "index": ["type": "integer", "description": "The frame's number in list_screens, from 1."],
                    "at_seconds": ["type": "number"],
                    "include_image": ["type": "boolean"],
                 ] as [String: Any], "required": ["meeting_id"]]),
    ] }

    static func meetingID(_ input: [String: Any]) -> String? {
        (input["meeting_id"] as? String) ?? (input["call_id"] as? String)
    }

    private func meeting(_ input: [String: Any]) -> CallRecord? {
        Self.meetingID(input).flatMap { id in records.first { $0.id == id } }
    }

    func listScreens(_ input: [String: Any]) -> String {
        guard let r = meeting(input) else { return "No meeting with that call_id." }
        let screens = r.screens ?? []
        guard !screens.isEmpty else { return "No shared screens were kept for this meeting." }
        var lines = ["call_id: \(r.id) | \(r.title) | \(screens.count) screens"]
        var number = 0
        for session in ShareSession.group(screens) {
            // The list stays short; get_screen has a frame's whole text.
            lines.append(session.heading { MarkdownWriter.timestamp($0) })
            for s in session.screens {
                number += 1
                lines.append("\(number). at_seconds: \(Int(s.offset)) [\(MarkdownWriter.timestamp(s.offset))] \"\(String(ScreenText.excerpt(s.text).prefix(90)))\"")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The screen a call names: by its number from 1, or the one nearest to a time.
    func screen(_ input: [String: Any]) -> (record: CallRecord, screen: SharedScreen, number: Int)? {
        guard let r = meeting(input) else { return nil }
        let screens = (r.screens ?? []).sorted { $0.offset < $1.offset }
        guard !screens.isEmpty else { return nil }
        if let index = (input["index"] as? NSNumber)?.intValue {
            guard screens.indices.contains(index - 1) else { return nil }
            return (r, screens[index - 1], index)
        }
        let at = (input["at_seconds"] as? NSNumber)?.doubleValue ?? 0
        guard let i = screens.indices.min(by: { abs(screens[$0].offset - at) < abs(screens[$1].offset - at) }) else { return nil }
        return (r, screens[i], i + 1)
    }

    func getScreen(_ input: [String: Any]) -> String {
        guard meeting(input) != nil else { return "No meeting with that call_id." }
        guard let (r, s, number) = screen(input) else { return "No shared screen there. Use list_screens for the screens of this meeting." }
        var parts = ["call_id: \(r.id) | \(r.title) | screen \(number) of \(r.screens?.count ?? 0) | at_seconds: \(Int(s.offset)) [\(MarkdownWriter.timestamp(s.offset))]"]
        if let presenter = s.presenter {
            parts.append("Shared by: \(presenter)")
        } else if let speaker = r.mainSpeaker(around: s.offset) {
            parts.append("Shared by: not shown by the call app. \(speaker) spoke most at that time.")
        }
        parts.append("Text on the screen:\n\(s.text)")
        let lines = r.lines(around: s.offset).map { "[\(MarkdownWriter.timestamp($0.start))] \($0.speaker): \($0.text)" }
        parts.append(lines.isEmpty ? "Nobody spoke within 30 seconds of it." : "Said around it:\n" + lines.joined(separator: "\n"))
        if input["include_image"] as? Bool == true, screenImageURL(input) == nil {
            parts.append("The picture is no longer on this Mac; only its text is kept.")
        }
        return parts.joined(separator: "\n\n")
    }

    /// The picture's file, when it is still on disk.
    func screenImageURL(_ input: [String: Any]) -> URL? {
        guard let paths, let (r, s, _) = screen(input) else { return nil }
        let url = FrameIndex.folder(in: paths.callDirectory(r.id)).appendingPathComponent(s.file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
