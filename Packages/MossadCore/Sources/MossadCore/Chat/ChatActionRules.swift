import Foundation

/// Where a point goes when the owner names a person or a meeting: "my and Jeff's next meeting". The next upcoming
/// meeting with exactly that person (its series when it has one, else a point for the person, shown before that
/// meeting), else the one series they usually come to, else the person. Two that fit is a question, never a guess.
public enum PointTarget {
    public enum Outcome: Equatable, Sendable {
        case series(MeetingSeries, UpcomingMeeting?)
        case person(id: String, name: String, UpcomingMeeting?)
        /// Several fit: the owner chooses.
        case choose([String])
        case notFound(String)
    }

    public static func resolve(with words: String, people: [Person], upcoming: [UpcomingMeeting], series: [MeetingSeries], now: Date) -> Outcome {
        let q = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .notFound("Say the person or the meeting.") }
        let refs = PersonReferences(people: people)
        switch who(q, people: people, refs: refs) {
        case .one(let id):
            let name = refs.name(of: id) ?? q
            let owner = people.first { $0.isOwner && $0.isLive }?.id.rawValue
            return target(person: id, name: name, owner: owner, refs: refs, upcoming: upcoming, series: series, now: now)
        case .several(let names):
            return .choose(names)
        case .none:
            break
        }
        let titled = NextTimeAdd.series(q, in: series)
        if titled.count == 1 { return .series(titled[0], titled[0].next) }
        if titled.count > 1 { return .choose(titled.map(\.title)) }
        return .notFound("No saved person or recurring meeting is surely \u{201C}\(q)\u{201D}.")
    }

    enum Who { case one(String), several([String]), none }

    /// A person_id, an address, or a whole name: the identity rules. One word is also a first name or a
    /// nickname, but only of exactly one saved person; two who fit are a question.
    static func who(_ q: String, people: [Person], refs: PersonReferences) -> Who {
        let live = people.filter { $0.isLive && !$0.isOwner }
        if !q.contains(" "), !q.contains("@"), !refs.knows(q) {
            let word = q.lowercased()
            let names = Nicknames.variants(of: word).union([word])
            let hits = live.filter { p in
                guard let first = p.displayName.split(separator: " ").first?.lowercased() else { return false }
                return names.contains(first)
            }
            if hits.count == 1 { return .one(hits[0].id.rawValue) }
            if hits.count > 1 { return .several(hits.map(\.displayName).sorted()) }
        }
        guard let id = refs.id(for: q).map(refs.canonical), let p = refs.person(id), !p.isOwner, p.isLive else { return .none }
        return .one(id)
    }

    static func target(person id: String, name: String, owner: String?, refs: PersonReferences, upcoming: [UpcomingMeeting], series: [MeetingSeries],
                       now: Date) -> Outcome {
        // The next meeting of the two of them: everyone invited other than the owner is this one person.
        let theirs = upcoming.filter { $0.end > now }.sorted { $0.start < $1.start }.first { u in
            let others = u.attendees.filter { a in refs.id(for: a).map(refs.canonical) != owner }
            return others.count == 1 && others.allSatisfy { refs.id(for: $0).map(refs.canonical) == id }
        }
        if let u = theirs {
            if let s = SeriesCatalog.series(of: u, in: series) ?? u.seriesID.flatMap({ id in series.first { $0.keys.contains("cal:\(id)") } }) {
                return .series(s, u)
            }
            return .person(id: id, name: name, u)
        }
        let usual = series.filter { s in s.usualPeople.contains { $0 == name || refs.id(for: $0).map(refs.canonical) == id } }
        if usual.count == 1 { return .series(usual[0], usual[0].next) }
        if usual.count > 1 { return .choose(usual.map(\.title)) }
        return .person(id: id, name: name, nil)
    }
}

/// The rules of one owner message, in code: only the owner's own words are a reason to act, at most 3 actions run,
/// the riskier class waits for a click, and during a call only light writes run.
public struct ActionTurn: Sendable {
    public static let limit = 3

    public enum Admission: Equatable, Sendable {
        case run
        /// A card in the thread: nothing happens before the owner's click.
        case propose(String)
        case refuse(String)
        /// Over the limit: it joins one card with the others over it.
        case later
    }

    let words: Set<String>
    let live: Bool
    private(set) var ran = 0

    /// `message` is the owner's own message: text from a meeting, an invite, a chat, or a tool's result is data and
    /// never a reason to act. `live`: a call records now.
    public init(message: String, live: Bool) {
        words = Set(message.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init))
        self.live = live
    }

    public mutating func admit(_ r: ChatActionRequest) -> Admission {
        if r.kind.needsClick {
            return live ? .refuse("That waits for the end of the call.") : .propose("It waits for the owner's click.")
        }
        if r.kind == .bookmarkNow, !live { return .refuse("No call records now. To mark a moment of a past meeting, give its call_id and the second.") }
        guard ActionIntent.asks(r.kind, words) else { return .propose("The owner's message did not ask for this, so it waits for a click.") }
        guard ran < Self.limit else { return .later }
        ran += 1
        return .run
    }
}

/// Whether the owner's own words ask for an action of this kind. A word list, so it can be tested; it decides only
/// between running at once and a card, never whether an action may happen at all.
enum ActionIntent {
    static let words: [ChatActionRequest.Family: Set<String>] = [
        .points: ["add", "note", "notes", "point", "points", "raise", "bring", "discuss", "agenda", "remind", "edit", "change", "update", "reword",
                  "remove", "drop", "delete", "tick", "check", "done", "reopen", "save", "put", "next"],
        .tasks: ["task", "tasks", "todo", "to-do", "remind", "promise", "promised", "owe", "due", "deadline", "done", "finished", "finish", "complete",
                 "completed", "reopen", "open", "add", "move", "push", "track"],
        .bookmarks: ["bookmark", "bookmarks", "mark", "flag", "star", "moment"],
    ]

    static func asks(_ kind: ChatActionRequest.Kind, _ words: Set<String>) -> Bool {
        guard let list = Self.words[kind.family] else { return true }
        return !list.isDisjoint(with: words)
    }
}

/// What one action did: its inverse, and the target as it left it.
public struct ChatActionChange: Sendable {
    public var undo: ChatActionRequest
    public var after: ChatActionTarget
}

/// The changes to the owner's points and tasks, pure. Each returns its inverse; nil when the target is not there
/// or already as asked.
public enum ChatActionApply {
    public static func run(_ r: ChatActionRequest, on book: inout NextTimeBook, now: Date) -> ChatActionChange? {
        if r.kind == .addPoint {
            guard let text = r.text?.nonBlank, r.seriesID != nil || r.personID != nil else { return nil }
            let same = book.visible.filter { $0.isOpen && (r.seriesID != nil ? $0.seriesID == r.seriesID : ($0.seriesID == nil && $0.personID == r.personID)) }
            var p = NextTimePoint(text: text, personID: r.seriesID == nil ? r.personID : nil, personName: r.seriesID == nil ? r.personName : nil,
                                  rank: (same.map(\.rank).max() ?? 0) + 1, created: now)
            p.seriesID = r.seriesID
            p.seriesKeys = r.seriesKeys
            p.seriesTitle = r.seriesTitle
            book.points.append(p)
            var undo = ChatActionRequest(.removePoint)
            undo.pointID = p.id
            return ChatActionChange(undo: undo, after: .point(p))
        }
        guard let id = r.pointID, let before = book.points.first(where: { $0.id == id }) else { return nil }
        var undo = ChatActionRequest(.editPoint)
        undo.pointID = id
        switch r.kind {
        case .editPoint:
            guard let text = r.text?.nonBlank, !before.deleted else { return nil }
            book.update(id, at: now) { $0.text = text }
            undo.text = before.text
        case .removePoint:
            guard !before.deleted else { return nil }
            book.update(id, at: now) { $0.deleted = true }
            undo.kind = .restorePoint
        case .restorePoint:
            guard before.deleted else { return nil }
            book.update(id, at: now) { $0.deleted = false }
            undo.kind = .removePoint
        case .tickPoint:
            guard before.isOpen else { return nil }
            let done = r.discussed ?? NextTimePoint.Discussed(callID: r.callID, at: r.at, quote: nil, date: now, byOwner: true)
            book.update(id, at: now) { $0.done = done }
            undo.kind = .reopenPoint
        case .reopenPoint:
            guard !before.deleted, let done = before.done else { return nil }
            book.update(id, at: now) { $0.done = nil }
            undo.kind = .tickPoint
            undo.discussed = done
        default:
            return nil
        }
        guard let after = book.points.first(where: { $0.id == id }) else { return nil }
        return ChatActionChange(undo: undo, after: .point(after))
    }

    public static func run(_ r: ChatActionRequest, on book: inout CommitmentBook, now: Date) -> ChatActionChange? {
        if r.kind == .addTask {
            guard let text = r.text?.nonBlank else { return nil }
            var c = Commitment(text: text, to: r.personName, callID: r.callID, callTitle: r.callTitle, madeAt: now, at: r.at, due: r.date, created: now)
            c.toID = r.personID
            book.items.append(c)
            var undo = ChatActionRequest(.deleteTask)
            undo.taskID = c.id
            return ChatActionChange(undo: undo, after: .task(c))
        }
        guard let id = r.taskID, let i = book.items.firstIndex(where: { $0.id == id }) else { return nil }
        let before = book.items[i]
        var undo = ChatActionRequest(.setTaskDue)
        undo.taskID = id
        switch r.kind {
        case .setTaskDone:
            guard !before.deleted, before.done == nil else { return nil }
            book.items[i].done = r.date ?? now
            undo.kind = .setTaskOpen
        case .setTaskOpen:
            guard !before.deleted, let done = before.done else { return nil }
            book.items[i].done = nil
            undo.kind = .setTaskDone
            undo.date = done
        case .setTaskDue:
            guard !before.deleted else { return nil }
            let due = r.noDate == true ? nil : r.date
            guard due != before.due else { return nil }
            book.items[i].due = due
            undo.date = before.due
            undo.noDate = before.due == nil
        case .deleteTask:
            guard !before.deleted else { return nil }
            book.items[i].deleted = true
            undo.kind = .deleteTask
        default:
            return nil
        }
        book.items[i].updated = now
        return ChatActionChange(undo: undo, after: .task(book.items[i]))
    }

    /// Whether the target is still as the action left it: only then does Undo run.
    public static func holds(_ after: ChatActionTarget, point: NextTimePoint?) -> Bool {
        guard let point else { return false }
        return ChatActionTarget.point(point) == after
    }

    public static func holds(_ after: ChatActionTarget, task: Commitment?) -> Bool {
        guard let task else { return false }
        return ChatActionTarget.task(task) == after
    }
}

extension CallRecord {
    /// Takes away the bookmark within a second of `offset`: the Undo of a bookmark the chat added.
    @discardableResult
    mutating func removeBookmark(at offset: TimeInterval) -> Bool {
        guard let i = markers.indices.filter({ markers[$0].isBookmark && abs(markers[$0].offset - offset) <= 1 })
            .min(by: { abs(markers[$0].offset - offset) < abs(markers[$1].offset - offset) }) else { return false }
        markers.remove(at: i)
        return true
    }
}
