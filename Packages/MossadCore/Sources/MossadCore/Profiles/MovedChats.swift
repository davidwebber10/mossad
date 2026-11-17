import Foundation

/// Which chats of a moved meeting go with it. A chat goes only when each of its steps read this call alone; any other
/// step (another meeting, a person, the tasks, the coach, the calendar, a write, or a step this build does not know)
/// means its words may hold the first profile's other meetings: it is deleted there with the meeting, not moved.
public enum MovedChats {
    public enum Read: Equatable, Sendable { case thisCall, other }

    /// What one step of an answer read. The steps are the words that `ChatTools.step` writes: a meeting by its title.
    /// A title that another meeting of this profile also has is not this call alone.
    public static func read(_ step: String, title: String, otherTitles: Set<String>) -> Read {
        if step == "Listening to the call" { return .thisCall }
        guard !otherTitles.contains(title) else { return .other }
        for lead in ["Reading ", "Looking at the screens shared in "] where step == lead + title {
            // "Reading <title>" is also the words of a recurring meeting of that name, which has other meetings with
            // the same title: those are in `otherTitles`.
            return .thisCall
        }
        return .other
    }

    public static func goes(_ chat: Chat, title: String, otherTitles: Set<String>) -> Bool {
        chat.messages.allSatisfy { m in m.steps.allSatisfy { read($0, title: title, otherTitles: otherTitles) == .thisCall } }
    }

    /// The chats that go, without their receipts, and the ones that are deleted with the meeting.
    public static func split(_ chats: [Chat], title: String, otherTitles: Set<String>) -> (moved: [Chat], deleted: [Chat]) {
        var moved: [Chat] = [], deleted: [Chat] = []
        for c in chats {
            if goes(c, title: title, otherTitles: otherTitles) { moved.append(MovedRecord.prepared(c)) } else { deleted.append(c) }
        }
        return (moved, deleted)
    }
}

/// The chats from the iPhone that came in for a meeting whose move waits and were not kept: a count for each meeting
/// in `Moves/<id>.phone-chats` (never a word of a chat), until the window app has said so once.
public enum MovingChats {
    static let suffix = ".phone-chats"

    public static func url(_ callID: String, paths: Paths) -> URL {
        paths.moves.appendingPathComponent((MovePaths.isID(callID) ? callID : MovePaths.notAnID) + suffix)
    }

    public static func refused(_ callID: String, paths: Paths) {
        guard MovePaths.isID(callID) else { return }
        let n = (all(paths)[callID] ?? 0) + 1
        try? FileManager.default.createDirectory(at: paths.moves, withIntermediateDirectories: true)
        try? Data(String(n).utf8).write(to: url(callID, paths: paths), options: .atomic)
    }

    /// Each meeting with chats not kept, and how many.
    public static func all(_ paths: Paths) -> [String: Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.moves.path)) ?? []
        var out: [String: Int] = [:]
        for name in names where name.hasSuffix(suffix) {
            let id = String(name.dropLast(suffix.count))
            guard MovePaths.isID(id), let text = try? String(contentsOf: url(id, paths: paths), encoding: .utf8),
                  let n = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 else { continue }
            out[id] = n
        }
        return out
    }

    public static func shown(_ callID: String, paths: Paths) {
        guard MovePaths.isID(callID) else { return }
        try? FileManager.default.removeItem(at: url(callID, paths: paths))
    }
}

extension MoveWords {
    /// The chats from the iPhone that were not kept while their meeting was moving.
    public static func phoneChatsNotKept(_ n: Int) -> String {
        n == 1 ? "A chat from your iPhone about this meeting came in while it was moving. It was not kept."
            : "\(n) chats from your iPhone about a meeting that was moving came in. They were not kept."
    }
}
