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
        case restorePoint, deleteTask, removeBookmark, restoreTask

        /// The riskier class: a card with "Do it" before anything happens.
        public var needsClick: Bool { [.nameVoice, .setRecording, .renameMeeting, .addTag, .removeTag, .batch].contains(self) }
        /// Small files outside or inside the call folder, as the hotkey bookmark and the points: allowed during a call.
        public var isLight: Bool { !needsClick }
        /// What kind of words in the owner's message ask for it.
        var family: Family {
            switch self {
            case .addPoint, .editPoint, .removePoint, .tickPoint, .reopenPoint, .restorePoint: .points
            case .addTask, .setTaskDone, .setTaskOpen, .setTaskDue, .deleteTask, .restoreTask: .tasks
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
    /// What one action of such a card does, in words, for its receipt.
    public var summary: String?
    /// The key of one action of such a card, so a Retry does not run it beside the card.
    public var key: String?

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
    /// What a card says besides its summary: what the click starts and that it has no Undo.
    public var detail: String?
    /// The owner's message and the action's arguments: a Retry of that message never does it again.
    public var key: String?

    /// The words of a card, which says what a click will do: "Save for…", never "Saved for…".
    public static func futureForm(_ s: String) -> String {
        let pairs = [("Saved for", "Save for"), ("Task added:", "Add the task:"), ("Bookmarked this moment", "Bookmark this moment"),
                     ("Bookmarked", "Bookmark"), ("Point changed to:", "Change the point to:"), ("Point removed:", "Remove the point:"),
                     ("Point ticked as discussed:", "Tick as discussed:"), ("Point open again:", "Reopen the point:"),
                     ("Task done:", "Mark the task done:"), ("Task open again:", "Reopen the task:")]
        for (done, will) in pairs where s.hasPrefix(done) { return will + s.dropFirst(done.count) }
        if s.hasPrefix("Task "), s.contains(": due") || s.contains(": no due date") { return "Change the due date of the task " + s.dropFirst(5) }
        return s
    }

    /// The order of the states, for two copies of one chat: a later state never goes back to an earlier one.
    var rank: Int {
        switch state {
        case .proposed: 0
        case .done, .declined, .failed: 1
        case .undone: 2
        }
    }

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
    public var note: String?
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

    /// A meeting's title and tags as its record holds them, read again from disk for Undo.
    public static func meeting(_ r: CallRecord) -> ChatActionTarget {
        var t = ChatActionTarget()
        t.title = r.customTitle
        t.tags = r.tags
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

/// The edits of a chat's thread for the actions, the one rule for each writer: a receipt goes into the chat the
/// moment its action is done, before the answer goes on; the answer, when it comes, joins the copy in the file.
public enum ChatThreadEdits {
    /// Puts a receipt or a card on the answer `answer`, which is made (empty) when it is not there yet.
    public static func record(_ r: ChatActionRecord, in chat: inout Chat, answer: UUID) {
        if let i = chat.messages.firstIndex(where: { $0.id == answer }) {
            var list = chat.messages[i].actions ?? []
            if let j = list.firstIndex(where: { $0.id == r.id }) { list[j] = r } else { list.append(r) }
            chat.messages[i].actions = list
        } else {
            var m = ChatMessage(role: .assistant, text: "")
            m.id = answer
            m.actions = [r]
            chat.messages.append(m)
        }
    }

    /// The answer stopped or failed. With something done, the question stays and the answer says what was done;
    /// with nothing done, the question goes. Returns whether the question stays.
    static let stoppedText = "The answer stopped. This was done:"

    /// The answer stopped (`byOwner`, the owner's Stop) or failed. With something done, the question stays and the
    /// answer says what was done. A failure keeps the question for Retry; the owner's Stop with nothing done takes
    /// it out. Returns whether the question stays.
    @discardableResult
    public static func stop(in chat: inout Chat, answer: UUID, question: UUID, byOwner: Bool) -> Bool {
        if let i = chat.messages.firstIndex(where: { $0.id == answer }), !(chat.messages[i].actions ?? []).isEmpty {
            if chat.messages[i].text.isEmpty { chat.messages[i].text = stoppedText }
            return true
        }
        chat.messages.removeAll { $0.id == answer }
        guard byOwner else { return true }
        chat.messages.removeAll { $0.id == question }
        return false
    }

    /// The question a Retry asks again, by its id: the last one, when only a stopped answer with what it did (or
    /// nothing) follows it. Nil when it has its answer.
    public static func retryQuestion(_ chat: Chat) -> ChatMessage? {
        guard let i = chat.messages.lastIndex(where: { $0.role == .user }) else { return nil }
        let after = chat.messages[(i + 1)...]
        guard after.allSatisfy({ $0.role == .assistant && ($0.text.isEmpty || $0.text == stoppedText) }) else { return nil }
        return chat.messages[i]
    }

    /// The answer as it came, on the copy in the file: its receipts stay, and so does every click saved meanwhile.
    public static func finish(_ message: ChatMessage, in chat: inout Chat) {
        guard let i = chat.messages.firstIndex(where: { $0.id == message.id }) else {
            chat.messages.append(message)
            return
        }
        let kept = chat.messages[i].actions ?? []
        var m = message
        m.actions = merge(kept, message.actions ?? [])
        if m.actions?.isEmpty == true { m.actions = nil }
        chat.messages[i] = m
    }

    /// Each action once, in the later of its states.
    static func merge(_ a: [ChatActionRecord], _ b: [ChatActionRecord]) -> [ChatActionRecord] {
        var out = a
        for r in b {
            if let j = out.firstIndex(where: { $0.id == r.id }) { if r.rank > out[j].rank { out[j] = r } } else { out.append(r) }
        }
        return out
    }
}

/// Which voice a card names and whom: the label of the voice, the name and the address, and the one saved person
/// they surely are, or a new person. The name and the address must agree, or the model asks the owner.
public struct NameVoiceTarget: Equatable, Sendable {
    public var key: String
    public var label: String
    public var name: String
    public var email: String?
    public var personID: String?

    public static func resolve(label: String, name typed: String, email: String?, record r: CallRecord, people: [Person]) -> Result<NameVoiceTarget, NameVoiceError> {
        let shown = MarkdownWriter.displayNames(r)
        let keys = shown.filter { $0.value.caseInsensitiveCompare(label) == .orderedSame }.map(\.key)
        guard keys.count == 1, let key = keys.first else {
            return .failure(NameVoiceError(text: keys.isEmpty ? "\(r.title) has no voice called \(label)." : "Two voices of \(r.title) are called \(label); name it on the meeting."))
        }
        let refs = PersonReferences(people: people)
        func id(_ s: String) -> String? { refs.id(for: s).map(refs.canonical).flatMap { refs.person($0)?.isLive == true ? $0 : nil } }
        let byName = typed.contains(" ") ? id(typed) : nil
        let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nonBlank
        let byEmail = email.flatMap(id)
        if let byEmail {
            let owner = refs.name(of: byEmail) ?? "someone else"
            if let byName, byName != byEmail {
                return .failure(NameVoiceError(text: "the name is \(refs.name(of: byName) ?? typed) and the address is \(owner)'s. Ask the owner which person it is."))
            }
            if byName == nil, owner.caseInsensitiveCompare(typed) != .orderedSame {
                return .failure(NameVoiceError(text: "that address is \(owner)'s, not \(typed)'s. Ask the owner which person it is."))
            }
        }
        let target = byEmail ?? byName
        return .success(NameVoiceTarget(key: key, label: shown[key] ?? label, name: target.flatMap(refs.name(of:)) ?? typed, email: email, personID: target))
    }

    /// At the click: the voice still has the label the card showed and the person is still the one it named.
    /// Gives the exact name and address to apply; nil when anything changed.
    public static func check(_ r: ChatActionRequest, record: CallRecord, people: [Person]) -> (name: String, email: String?)? {
        guard let key = r.speakerKey, let label = r.speakerLabel, let name = r.text,
              MarkdownWriter.displayNames(record)[key] == label else { return nil }
        let refs = PersonReferences(people: people)
        if let id = r.personID {
            let id = refs.canonical(id)
            guard let p = refs.person(id), p.isLive else { return nil }
            // The address is still nobody's or this person's.
            if let email = r.email, let holder = refs.id(for: email).map(refs.canonical), holder != id { return nil }
            return (p.displayName, r.email)
        }
        // A new person: still no saved person by that name or address.
        guard refs.id(for: name) == nil, r.email.flatMap({ refs.id(for: $0) }) == nil else { return nil }
        return (name, r.email)
    }
}

public struct NameVoiceError: Error, Equatable, Sendable { public var text: String }
