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
