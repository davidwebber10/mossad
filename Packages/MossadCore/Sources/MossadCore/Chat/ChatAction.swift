import Foundation

/// One thing the owner asked the app's own chat to do: what, and to what. A flat list of optional fields, so an older
/// build reads a chat with actions (it ignores the key) and a newer one reads a chat without them.
public struct ChatActionRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        // Light: run at once, with a receipt and Undo. Allowed during a call.
        case addPoint, editPoint, removePoint, tickPoint, reopenPoint
        case addTask, setTaskDone, setTaskOpen, setTaskDue
        case addBookmark, bookmarkNow
        // One click on a card first. Never during a call.
        case nameVoice, setRecording, renameMeeting, addTag, removeTag
        /// Actions over the limit of one message, as one card.
        case batch
        // Only inverses, never offered to the model.
        case restorePoint, deleteTask, removeBookmark

        /// The riskier class: a card with "Do it" before anything happens.
        public var needsClick: Bool { [.nameVoice, .setRecording, .renameMeeting, .addTag, .removeTag, .batch].contains(self) }
        /// Small files outside or inside the call folder, as the hotkey bookmark and the points: allowed during a call.
        public var isLight: Bool { !needsClick }
        /// What kind of words in the owner's message ask for it.
        var family: Family {
            switch self {
            case .addPoint, .editPoint, .removePoint, .tickPoint, .reopenPoint, .restorePoint: .points
            case .addTask, .setTaskDone, .setTaskOpen, .setTaskDue, .deleteTask: .tasks
            case .addBookmark, .bookmarkNow, .removeBookmark: .bookmarks
            case .nameVoice: .voices
            case .setRecording: .recording
            case .renameMeeting: .titles
            case .addTag, .removeTag: .tags
            case .batch: .any
            }
        }
    }

    enum Family { case points, tasks, bookmarks, voices, recording, titles, tags, any }

    public var kind: Kind
    public var text: String?
    public var pointID: UUID?
    public var taskID: UUID?
    public var callID: String?
    public var callTitle: String?
    public var at: TimeInterval?
    public var seriesID: String?
    public var seriesKeys: [String]?
    public var seriesTitle: String?
    public var personID: String?
    public var personName: String?
    public var date: Date?
    /// A task's due date taken away.
    public var noDate: Bool?
    /// A point's state before an action changed it, for its Undo.
    public var discussed: NextTimePoint.Discussed?
    public var speakerKey: String?
    public var speakerLabel: String?
    public var email: String?
    public var choice: String?
    public var upcomingID: String?
    public var tags: [String]?
    /// The actions of a card for those over the limit.
    public var items: [ChatActionRequest]?

    public init(_ kind: Kind) { self.kind = kind }
}

/// What the thread shows for one action: a receipt of what was done, or a card that waits for a click. Saved with
/// the answer (`ChatMessage.actions`).
public struct ChatActionRecord: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        /// Done, with its Undo while it holds.
        case done
        case undone
        /// A card that waits for "Do it" or "Not now".
        case proposed
        case declined
        case failed
    }

    public var id = UUID()
    public var request: ChatActionRequest
    public var state: State
    /// What happened or will happen, in words: "Saved for the next Weekly sync: discuss the budget".
    public var summary: String
    /// The place it went: `mossad://call/<id>?t=<s>`, `mossad://series/<id>`, `mossad://person/<id>`, `mossad://tasks`.
    public var place: String?
    /// The inverse, for Undo; nil when there is none.
    public var undo: ChatActionRequest?
    /// The target as the action left it: Undo runs only while it is still so.
    public var after: ChatActionTarget?
    public var date: Date

    public init(request: ChatActionRequest, state: State, summary: String, place: String? = nil, undo: ChatActionRequest? = nil,
                after: ChatActionTarget? = nil, date: Date) {
        self.request = request
        self.state = state
        self.summary = summary
        self.place = place
        self.undo = undo
        self.after = after
        self.date = date
    }

    /// The receipt as plain text, for the iPhone and an older reader.
    public var plainText: String {
        switch state {
        case .done: "Done: \(summary)"
        case .undone: "Undone: \(summary)"
        case .proposed: "Waits for a click on the Mac: \(summary)"
        case .declined: "Not done: \(summary)"
        case .failed: "Could not do it: \(summary)"
        }
    }
}

/// The part of the target that an action changed, as it left it. Equal means nobody changed it since.
public struct ChatActionTarget: Codable, Equatable, Sendable {
    public var pointText: String?
    public var pointDone: Bool?
    public var pointDeleted: Bool?
    public var taskText: String?
    public var taskDone: Bool?
    public var taskDue: Date?
    public var taskDeleted: Bool?
    public var bookmark: Bool?
    public var title: String?
    public var tags: [String]?

    public init() {}

    public static func point(_ p: NextTimePoint) -> ChatActionTarget {
        var t = ChatActionTarget()
        t.pointText = p.text
        t.pointDone = p.done != nil
        t.pointDeleted = p.deleted
        return t
    }

    public static func task(_ c: Commitment) -> ChatActionTarget {
        var t = ChatActionTarget()
        t.taskText = c.text
        t.taskDone = c.done != nil
        t.taskDue = c.due
        t.taskDeleted = c.deleted
        return t
    }
}

extension ChatMessage {
    /// The receipts and cards of an answer, as plain lines: for the iPhone, which shows no buttons.
    public var actionLines: [String] { (actions ?? []).map(\.plainText) }
}
