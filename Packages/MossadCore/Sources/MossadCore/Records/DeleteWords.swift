import Foundation

/// The words of the confirmation before a Delete of a meeting. They say what Delete removes (`CallForget`), that the
/// people stay, and that there is no Undo.
public enum DeleteWords {
    public static let confirmation = "Mossad deletes the recording and its notes, its tasks, its chats, your points for this meeting, "
        + "and the voice samples it learned from this call. The people stay. You cannot undo this."
}
