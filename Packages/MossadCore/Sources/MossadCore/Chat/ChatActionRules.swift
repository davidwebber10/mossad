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
        // The next one: a meeting that runs now is this one, not the next.
        let theirs = upcoming.filter { $0.start > now }.sorted { $0.start < $1.start }.first { u in
            let others = u.attendees.filter { a in refs.id(for: a).map(refs.canonical) != owner }
            return others.count == 1 && others.allSatisfy { refs.id(for: $0).map(refs.canonical) == id }
        }
        if let u = theirs {
            if let s = SeriesCatalog.series(of: u, in: series) ?? u.seriesID.flatMap({ id in series.first { $0.keys.contains("cal:\(id)") } }) {
                return .series(s, u)
            }
            return .person(id: id, name: name, u)
        }
        // A series that still meets and is about the two of them; a group or an ended series is not "their" meeting.
        let usual = series.filter { s in
            s.next != nil && s.usualPeople.count <= 2 && s.usualPeople.contains { $0 == name || refs.id(for: $0).map(refs.canonical) == id }
        }
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

    let message: String
    let live: Bool
    private(set) var ran = 0

    /// `message` is the owner's own message: text from a meeting, an invite, a chat, or a tool's result is data and
    /// never a reason to act. `live`: a call records now.
    public init(message: String, live: Bool) {
        self.message = message
        self.live = live
    }

    public mutating func admit(_ r: ChatActionRequest) -> Admission {
        if r.kind.needsClick {
            return live ? .refuse("That waits for the end of the call.") : .propose("It waits for the owner's click.")
        }
        if r.kind == .bookmarkNow, !live { return .refuse("No call records now. To mark a moment of a past meeting, give its call_id and the second.") }
        guard ActionIntent.asks(r.kind, message) else { return .propose("The owner's message did not ask for this, so it waits for a click.") }
        guard ran < Self.limit else { return .later }
        ran += 1
        return .run
    }
}

/// Whether the owner's own words ask for an action of this kind. Conservative, so that pasted or quoted text is
/// never read as the owner's request; when in doubt it is a card (a click), never a refusal of the action:
/// - Only the owner's first line counts, and only in a short message (at most 200 characters, at most 3 lines
///   before a blank line, none quoted with ">").
/// - A message with a greeting, an email header, a transcript line ("[12:04] Sam: …", "Sam Carter: …"), quote marks,
///   or reported speech ("said", "wrote", "asked") is a card.
/// - A question is a card; "Please" and "Can you" before a request word are a request, before a question word not.
/// - A "don't" or "not" before the verb is a card.
/// - The verb must be in the first 6 words, with a thing of its kind after it; a wide word ("me", "this", "it") counts
///   only right after the verb.
enum ActionIntent {
    typealias Kind = ChatActionRequest.Kind
    static let maxCharacters = 200
    static let verbWindow = 6

    struct Rule {
        var verbs: Set<String>
        var things: Set<String>
        /// Wide words that count only right after the verb: "remind me", "bookmark this".
        var nextTo: Set<String> = []
    }

    static let rules: [Kind: Rule] = [
        .addPoint: Rule(verbs: ["add", "save", "put", "note", "raise", "jot"], things: ["point", "points", "note", "notes", "agenda", "discuss"]),
        .editPoint: Rule(verbs: ["change", "edit", "reword", "update", "rewrite"], things: ["point", "points", "note"]),
        .removePoint: Rule(verbs: ["remove", "drop", "delete", "cross", "scrap"], things: ["point", "points", "note"]),
        .tickPoint: Rule(verbs: ["tick", "check", "mark"], things: ["point", "points", "raised", "discussed", "covered"]),
        .reopenPoint: Rule(verbs: ["reopen", "untick", "unmark"], things: ["point", "points"]),
        .addTask: Rule(verbs: ["add", "create", "make", "remind", "track"], things: ["task", "tasks", "todo", "to-do", "reminder"], nextTo: ["me"]),
        .setTaskDone: Rule(verbs: ["mark", "finish", "complete", "close", "tick", "check"], things: ["task", "tasks", "todo"]),
        .setTaskOpen: Rule(verbs: ["reopen", "untick", "unmark"], things: ["task", "tasks", "todo"]),
        .setTaskDue: Rule(verbs: ["move", "push", "change", "set", "shift", "reschedule"], things: ["due", "deadline", "date", "task", "tasks"]),
        .addBookmark: Rule(verbs: ["bookmark", "flag", "star"], things: ["moment", "second", "minute", "bookmark"], nextTo: ["this", "that", "it", "here"]),
        .bookmarkNow: Rule(verbs: ["bookmark", "flag", "star"], things: ["moment", "bookmark"], nextTo: ["this", "that", "it", "here", "now"]),
    ]
    static let questionWords: Set<String> = ["what", "which", "who", "whom", "whose", "when", "where", "why", "how", "did", "does", "do", "is", "are",
                                             "was", "were", "has", "have", "summarize", "summarise", "explain", "tell", "show", "list", "find"]
    static let greetings: Set<String> = ["hi", "hello", "hey", "dear", "thanks", "thank", "regards", "best", "cheers"]
    static let reported: Set<String> = ["said", "says", "wrote", "writes", "asked", "asks", "told", "mentioned"]
    static let negations: Set<String> = ["don't", "dont", "not", "never", "no", "doesn't", "didn't"]

    /// The owner's own lines: up to the first blank line, none quoted with ">"; nil when there are more than 3.
    static func ownLines(_ message: String) -> [String]? {
        var out: [String] = []
        for line in message.split(separator: "\n", omittingEmptySubsequences: false).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.isEmpty { if out.isEmpty { continue } else { break } }
            if line.hasPrefix(">") { return nil }
            out.append(line)
        }
        return out.count <= 3 ? out : nil
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "'" }.map(String.init)
    }

    /// Text that someone else wrote or said: a greeting, a mail header, a transcript line, quote marks, reported speech.
    static func looksPasted(_ lines: [String]) -> Bool {
        for line in lines {
            let w = words(line)
            if let first = w.first, greetings.contains(first) { return true }
            if line.range(of: #"^(from|to|subject|sent|cc|date|re|fwd?)\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
            if line.range(of: #"^\[?\d{1,2}:\d{2}"#, options: .regularExpression) != nil { return true }
            if line.range(of: #"^[A-Z][\p{L}'.-]*( [A-Z][\p{L}'.-]*)?:\s"#, options: .regularExpression) != nil { return true }
            if line.contains("\"") || line.contains("\u{201C}") || line.contains("\u{201D}") { return true }
            if w.contains(where: reported.contains) { return true }
        }
        return false
    }

    static func asks(_ kind: Kind, _ message: String) -> Bool {
        guard let rule = rules[kind], message.count <= maxCharacters, let lines = ownLines(message), let first = lines.first,
              !looksPasted(lines), !lines.contains(where: { $0.hasSuffix("?") && !isRequestOpener(words($0)) }) else { return false }
        var w = words(first)
        // "Please" and "can you" open a request; what follows them is read as the request.
        if w.first == "please" { w.removeFirst() } else if isRequestOpener(w) { w.removeFirst(2) }
        if let head = w.first, questionWords.contains(head) { return false }
        guard let v = w.prefix(verbWindow).firstIndex(where: rule.verbs.contains) else { return false }
        if w[..<v].contains(where: negations.contains) { return false }
        // A verb after a colon is in what follows the colon: someone else's text ("Here is Sam's mail: please add…").
        if let colon = first.firstIndex(of: ":") {
            let before = words(String(first[..<colon])).count
            // `w` may have lost "please" or "can you" at its start.
            let offset = words(first).count - w.count
            if v + offset >= before { return false }
        }
        let after = Array(w[(v + 1)...])
        if let next = after.first, rule.nextTo.contains(next) { return true }
        // A time such as "12:04" is the thing of a bookmark of a past meeting.
        if kind == .addBookmark, first.range(of: #"\d+:\d\d"#, options: .regularExpression) != nil { return true }
        return after.contains(where: rule.things.contains)
    }

    /// "Can you", "could you", "would you", "will you" before the request.
    static func isRequestOpener(_ w: [String]) -> Bool {
        ["can", "could", "would", "will"].contains(w.first ?? "") && w.dropFirst().first == "you"
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
            // The book's own rule: a "discussed" the check found and the owner takes back is never found again there.
            book.toggleDone(id, at: now)
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
            undo.kind = .restoreTask
        case .restoreTask:
            guard before.deleted else { return nil }
            book.items[i].deleted = false
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
