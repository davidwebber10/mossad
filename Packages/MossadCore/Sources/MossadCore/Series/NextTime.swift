import Foundation

/// Something the owner wants to raise the next time: at the next meeting of a series, at one meeting that is not part
/// of a series, or the next time they see a person. The owner's own list; the coach's suggestions stay apart
/// (`SeriesSuggestion`) until the owner keeps one. A point is in one list only: its series when it has one, else its
/// person, else its meeting (`isForMeeting`).
public struct NextTimePoint: Codable, Equatable, Sendable, Identifiable, Hashable {
    /// Where a point was marked done.
    public struct Discussed: Codable, Equatable, Sendable, Hashable {
        public var callID: String?
        /// The second of the call of the quoted line.
        public var at: TimeInterval?
        /// The words of the call, as the transcript has them. Nil for a point the owner marked done by hand.
        public var quote: String?
        public var date: Date
        /// True when the owner marked it, false when the check after the call found it.
        public var byOwner: Bool

        public init(callID: String?, at: TimeInterval?, quote: String?, date: Date, byOwner: Bool) {
            self.callID = callID
            self.at = at
            self.quote = quote
            self.date = date
            self.byOwner = byOwner
        }
    }

    /// Where a point came up in a meeting the owner missed. The point stays open: the owner has not raised it.
    public struct Mention: Codable, Equatable, Sendable, Hashable {
        public var callID: String
        /// The second of the call of the quoted line.
        public var at: TimeInterval
        /// The words of the call, as the transcript has them.
        public var quote: String
        /// When the meeting was.
        public var date: Date

        public init(callID: String, at: TimeInterval, quote: String, date: Date) {
            self.callID = callID
            self.at = at
            self.quote = quote
            self.date = date
        }
    }

    public var id = UUID()
    public var text: String
    /// The series it is for: its id, the keys it had when the point was saved, and its title then.
    public var seriesID: String?
    public var seriesKeys: [String]?
    public var seriesTitle: String?
    /// The person it is for, by the id in `people.json`, and their name then.
    public var personID: String?
    public var personName: String?
    /// The order in its list: lower first.
    public var rank: Double
    public var done: Discussed?
    /// The meetings of its series it stayed open in, oldest first: each one carried it to the next.
    public var carried: [String]?
    /// Meetings whose "discussed" the owner took back: the check never marks it from them again.
    public var reopened: [String]?
    /// The meetings the owner missed in which it came up, oldest first. Added to and never rewritten: an older
    /// build that saves the point leaves this out, and the next merge brings it back from the copy that has it.
    public var mentions: [Mention]?
    /// The one meeting it was saved for, when that meeting had no series. Kept when the point moves to a person or a
    /// series, as where it came from. The book holds only its recordings; this Mac's detail of it is in
    /// `MeetingPointsLocal`. An older build that saves the point leaves this out, and the next merge brings it back
    /// from the copy that has it; until then the older build shows the point in no list, never in a wrong one.
    public var meeting: NextTimeMeeting?
    /// The suggestion it came from, when the owner kept one.
    public var suggestion: String?
    public var deleted = false
    public var created: Date
    /// The last change on any device; the newer copy wins when devices merge.
    public var updated: Date

    public init(text: String, series: MeetingSeries? = nil, personID: String? = nil, personName: String? = nil, rank: Double, created: Date = Date()) {
        self.text = text
        seriesID = series?.id
        seriesKeys = series?.savedKeys
        seriesTitle = series?.title
        self.personID = personID
        self.personName = personName
        self.rank = rank
        self.created = created
        updated = created
    }

    public var isOpen: Bool { !deleted && done == nil }
    /// The newest meeting the owner missed in which it came up.
    public var lastMention: Mention? { mentions?.max { $0.date < $1.date } }
    public var isForPerson: Bool { personID != nil && seriesID == nil }
    /// For one meeting with no series, and not moved to a person or a series since.
    public var isForMeeting: Bool { meeting != nil && seriesID == nil && personID == nil }

    public func belongs(to s: MeetingSeries) -> Bool { s.matches(id: seriesID, keys: seriesKeys) }
}

/// The owner's answer to a suggestion: kept (yes), dismissed, or never this kind again. A plain dismissal hides that
/// one suggestion and teaches nothing; "Dismiss suggestions like this" is a dismissal with `lowers`.
public struct SuggestionAnswer: Codable, Equatable, Sendable, Hashable, Identifiable {
    public enum Verdict: String, Codable, Sendable { case keep, dismiss, never }
    public var id = UUID()
    /// The suggestion's `key`: its kind and its source.
    public var key: String
    public var kind: String
    public var verdict: Verdict
    public var date: Date
    /// When the owner took it back. The answer stays as a mark, so a sync with an older copy cannot bring it back.
    public var withdrawn: Date?
    /// True for "Dismiss suggestions like this": the dismissal also lowers its kind. Nil for a plain dismissal and for
    /// every answer saved before the field, which an older build reads and ignores; a new verdict would stop it
    /// reading the whole book.
    public var lowers: Bool?

    /// The time of its last change, which wins when devices merge.
    public var changed: Date { max(date, withdrawn ?? .distantPast) }
    public var counts: Bool { withdrawn == nil }
    /// Whether it teaches the coach about its kind: a keep, a never, or a dismissal that lowers.
    public var trains: Bool { verdict != .dismiss || lowers == true }

    public init(key: String, kind: String, verdict: Verdict, date: Date, lowers: Bool? = nil) {
        self.key = key
        self.kind = kind
        self.verdict = verdict
        self.date = date
        self.lowers = verdict == .dismiss && lowers == true ? true : nil
    }
}

/// Every point and every answer to a suggestion. Lives in `~/Mossad/NextTime`, syncs both ways like the tasks.
public struct NextTimeBook: Codable, Equatable, Sendable {
    public static let fileName = "next-time.json"
    /// A file from a later build has a higher version: it is read, and never saved over.
    public static let currentVersion = 1
    public var version = NextTimeBook.currentVersion

    public var points: [NextTimePoint] = []
    public var answers: [SuggestionAnswer] = []
    /// Calls already checked for the points, so each call is read once.
    public var checked: Set<String> = []
    /// Calls that left this profile: no point names one, and a merge with an older copy does not bring one back. Nil
    /// when there are none, and then the file is written as before.
    public var movedCalls: [String]?
    /// True when this Mac's detail file (`MeetingPointsLocal`) comes from a newer build: it is read and never saved.
    var localFrozen = false

    public init() {}

    enum CodingKeys: String, CodingKey { case version, points, answers, checked, movedCalls }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        points = try c.decodeIfPresent([NextTimePoint].self, forKey: .points) ?? []
        answers = try c.decodeIfPresent([SuggestionAnswer].self, forKey: .answers) ?? []
        checked = Set(try c.decodeIfPresent([String].self, forKey: .checked) ?? [])
        movedCalls = try c.decodeIfPresent([String].self, forKey: .movedCalls)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(points, forKey: .points)
        try c.encode(answers, forKey: .answers)
        try c.encode(checked.sorted(), forKey: .checked)
        try c.encodeIfPresent(movedCalls, forKey: .movedCalls)
    }

    public var visible: [NextTimePoint] { points.filter { !$0.deleted } }

    // MARK: Lists

    /// The points of a series, open ones in their order, then the done ones newest first.
    public func points(of s: MeetingSeries) -> (open: [NextTimePoint], done: [NextTimePoint]) {
        let mine = visible.filter { $0.belongs(to: s) }
        return (mine.filter(\.isOpen).sorted { ($0.rank, $0.created) < ($1.rank, $1.created) },
                mine.filter { $0.done != nil }.sorted { ($0.done?.date ?? .distantPast) > ($1.done?.date ?? .distantPast) })
    }

    /// The open points for one person, in their order. `canonical` gives the id a person has now, so a point
    /// saved for a person who was merged into another still shows.
    public func points(forPerson id: String, canonical: (String) -> String = { $0 }) -> [NextTimePoint] {
        let wanted = canonical(id)
        return visible.filter { p in p.isOpen && p.personID.map(canonical) == wanted }.sorted { ($0.rank, $0.created) < ($1.rank, $1.created) }
    }

    /// The open points for one person by the people as saved now, not as a catalog made earlier saw them: a point
    /// saved for a person merged into this one shows at once.
    public func points(forPerson id: String, people: [Person]) -> [NextTimePoint] {
        let next = Dictionary(people.compactMap { p in p.mergedInto.map { (p.id.rawValue, $0.rawValue) } }, uniquingKeysWith: { a, _ in a })
        return points(forPerson: id) { start in
            var current = start
            var seen: Set<String> = [start]
            while let n = next[current], seen.insert(n).inserted { current = n }
            return current
        }
    }

    /// The open points for an upcoming meeting: its series' first, then its own when it is one meeting (`meeting`),
    /// then the person's when the meeting is a 1:1 with them (`OneOnOne`). A group meeting shows no person's points:
    /// they wait for a 1:1, and the prep page only counts them (`personCounts`).
    public func points(for series: MeetingSeries?, meeting: UpcomingMeeting? = nil, oneOnOne: String?, canonical: (String) -> String = { $0 }) -> [NextTimePoint] {
        let own = (series.map { points(of: $0).open } ?? []) + (meeting.map { points(forMeeting: $0) } ?? [])
        var seen = Set(own.map(\.id))
        var theirs: [NextTimePoint] = []
        if let id = oneOnOne { for p in points(forPerson: id, canonical: canonical) where seen.insert(p.id).inserted { theirs.append(p) } }
        return own + theirs
    }

    /// The points that a meeting discussed: found by the check, or marked by the owner on that meeting.
    public func discussed(in callID: String) -> [NextTimePoint] {
        visible.filter { $0.done?.callID == callID }
    }

    /// The points still open that came up in a meeting the owner may have missed. A closed one is not listed:
    /// what the meeting said of it no longer matters.
    public func mentioned(in callID: String) -> [NextTimePoint] {
        visible.filter { $0.isOpen && $0.mentions?.contains { $0.callID == callID } == true }
    }

    /// Notes that a point came up in a meeting the owner missed, once for each meeting.
    public mutating func mention(_ id: UUID, _ m: NextTimePoint.Mention, at date: Date = Date()) {
        guard let p = points.first(where: { $0.id == id }), !(p.mentions ?? []).contains(where: { $0.callID == m.callID }) else { return }
        update(id, at: date) { $0.mentions = (($0.mentions ?? []) + [m]).sorted { ($0.date, $0.callID) < ($1.date, $1.callID) } }
    }

    // MARK: Changes

    /// Adds a point at the end of its list.
    @discardableResult
    public mutating func add(_ text: String, series: MeetingSeries? = nil, personID: String? = nil, personName: String? = nil,
                             meeting: NextTimeMeeting? = nil, suggestion: String? = nil, at date: Date = Date()) -> NextTimePoint? {
        guard let text = text.nonBlank, series != nil || personID != nil || meeting != nil else { return nil }
        let list = series.map { points(of: $0).open } ?? personID.map { points(forPerson: $0) } ?? meeting.map { points(forMeeting: $0) } ?? []
        var p = NextTimePoint(text: text, series: series, personID: series == nil ? personID : nil, personName: series == nil ? personName : nil,
                              rank: (list.map(\.rank).max() ?? 0) + 1, created: date)
        if series == nil, personID == nil { p.meeting = meeting }
        p.suggestion = suggestion
        points.append(p)
        return p
    }

    public mutating func update(_ id: UUID, at date: Date = Date(), _ change: (inout NextTimePoint) -> Void) {
        guard let i = points.firstIndex(where: { $0.id == id }) else { return }
        change(&points[i])
        points[i].updated = date
    }

    public mutating func delete(_ id: UUID, at date: Date = Date()) { update(id, at: date) { $0.deleted = true } }

    /// Gives each point of a series the keys its series has now, so it keeps finding it after the old keys go.
    /// Returns whether anything changed. Not the owner's change: the time of the last change stays.
    @discardableResult
    public mutating func refreshKeys(_ all: [MeetingSeries]) -> Bool {
        var changed = false
        for i in points.indices where points[i].seriesID != nil && !points[i].deleted {
            guard let s = all.first(where: { points[i].belongs(to: $0) }) else { continue }
            let keys = Array(Set((points[i].seriesKeys ?? []) + s.savedKeys)).sorted()
            if keys != points[i].seriesKeys { points[i].seriesKeys = keys; changed = true }
        }
        return changed
    }

    /// Puts the open points of one list in this order.
    public mutating func reorder(_ ids: [UUID], at date: Date = Date()) {
        for (n, id) in ids.enumerated() { update(id, at: date) { $0.rank = Double(n + 1) } }
    }

    /// A call that Mossad did not keep (skipped, too short) cannot hold a point's "done".
    @discardableResult
    public mutating func reopen(doneIn callID: String, at date: Date = Date()) -> Bool {
        let ids = points.filter { $0.done?.callID == callID }.map(\.id)
        for id in ids { update(id, at: date) { $0.done = nil } }
        return !ids.isEmpty
    }

    /// A meeting that left this profile: a point it closed is open again, and no point names it (carried, reopened,
    /// mentioned, or checked). The id is kept in `movedCalls`, so a merge with a copy that still names it cleans that
    /// copy too. `went`: the ids of the points that went with the meeting and that the target took (the ledger's list,
    /// `MoveOut.points`); exactly those become the empty marker, with this Mac's detail gone, and every other point
    /// keeps its words. Nil for a move whose ledger has no list (a move of an older build, which sent no points): then,
    /// as before, a point of that one meeting (by its recordings, or by `record`'s invite when it is sure) and one of
    /// it that was moved to a person in `gone` is emptied.
    @discardableResult
    public mutating func forget(callID: String, record: CallRecord? = nil, gone: Set<String> = [], went: Set<UUID>? = nil, at date: Date = Date()) -> Bool {
        var changed = false
        for i in points.indices where !Self.forgotten(points[i]) {
            if let went {
                guard went.contains(points[i].id) else { continue }
            } else {
                guard let m = points[i].meeting else { continue }
                let own = Self.ownMeeting(m, callID: callID, record: record)
                guard own, points[i].isForMeeting || (points[i].isForPerson && points[i].personID.map(gone.contains) == true) else { continue }
            }
            Self.empty(&points[i])
            points[i].updated = date
            changed = true
        }
        if reopen(doneIn: callID, at: date) { changed = true }
        for i in points.indices where Self.clean(&points[i], of: [callID]) {
            points[i].updated = date
            changed = true
        }
        if checked.remove(callID) != nil { changed = true }
        let before = answers.count
        answers.removeAll { Self.names($0.key, [callID]) }
        if answers.count != before { changed = true }
        if movedCalls?.contains(callID) != true {
            movedCalls = ((movedCalls ?? []) + [callID]).sorted()
            changed = true
        }
        return changed
    }

    /// Whether a suggestion's key ("openItem:<call id>:<words>") names one of these calls.
    static func names(_ key: String, _ calls: Set<String>) -> Bool {
        let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count >= 2 && calls.contains(String(parts[1]))
    }

    /// A point that `forget` emptied: deleted, with no word left. A delete by hand keeps its words.
    static func forgotten(_ p: NextTimePoint) -> Bool { p.deleted && p.text.isEmpty && p.suggestion == nil }

    /// The book with nothing of these calls: the merge's last step, and what a copy should be.
    func cleaned(of calls: Set<String>) -> NextTimeBook {
        guard !calls.isEmpty else { return self }
        var b = self
        for i in b.points.indices { _ = Self.clean(&b.points[i], of: calls) }
        b.checked.subtract(calls)
        b.answers.removeAll { Self.names($0.key, calls) }
        return b
    }

    /// The copy that came in still names a moved call, or lacks the list this book has: send this book again, so the
    /// store holds the clean copy. A clean copy with the same list sends nothing, so two Macs do not loop.
    public func pushesAgain(after incoming: NextTimeBook) -> Bool {
        guard let moved = movedCalls, !moved.isEmpty else { return false }
        if Set(incoming.movedCalls ?? []) != Set(moved) { return true }
        return incoming.cleaned(of: Set(moved)) != incoming
    }

    /// The empty deleted marker that a merge never brings back.
    static func empty(_ p: inout NextTimePoint) {
        p.deleted = true
        p.text = ""
        p.suggestion = nil
        p.done = nil
        p.personName = nil
        p.meeting?.detail = nil
    }

    /// Takes the calls out of a point: a point kept from a suggestion of one of them is an empty deleted marker. True
    /// when it changed.
    static func clean(_ p: inout NextTimePoint, of calls: Set<String>) -> Bool {
        let before = p
        if let key = p.suggestion, names(key, calls) { empty(&p) }
        if let call = p.done?.callID, calls.contains(call) { p.done = nil }
        p.carried = p.carried.map { $0.filter { !calls.contains($0) } }.flatMap { $0.isEmpty ? nil : $0 }
        p.reopened = p.reopened.map { $0.filter { !calls.contains($0) } }.flatMap { $0.isEmpty ? nil : $0 }
        p.mentions = p.mentions.map { $0.filter { !calls.contains($0.callID) } }.flatMap { $0.isEmpty ? nil : $0 }
        let kept = p.meeting?.calls.map { $0.filter { !calls.contains($0) } }.flatMap { $0.isEmpty ? nil : $0 }
        p.meeting?.calls = kept
        return p != before
    }

    /// The owner marks a point done by hand, or takes a done back. A "discussed" that the check found and the
    /// owner took back is never found again in that meeting.
    public mutating func toggleDone(_ id: UUID, at date: Date = Date()) {
        update(id, at: date) { p in
            if let d = p.done {
                if !d.byOwner, let call = d.callID { p.reopened = (p.reopened ?? []) + [call] }
                p.done = nil
            } else {
                p.done = NextTimePoint.Discussed(callID: nil, at: nil, quote: nil, date: date, byOwner: true)
            }
        }
    }

    public mutating func answer(_ suggestion: SeriesSuggestion, _ verdict: SuggestionAnswer.Verdict, lowersKind: Bool = false, at date: Date = Date()) {
        answers.removeAll { $0.key == suggestion.key }
        answers.append(SuggestionAnswer(key: suggestion.key, kind: suggestion.kind.rawValue, verdict: verdict, date: date, lowers: lowersKind))
    }

    /// Undo of an answer: the suggestion can come again, and a point kept from it goes. The answer stays, marked.
    public mutating func takeBack(_ key: String, at date: Date = Date()) {
        for i in answers.indices where answers[i].key == key && answers[i].counts { answers[i].withdrawn = date }
        for p in points where p.suggestion == key && !p.deleted { delete(p.id, at: date) }
    }

    /// Turns a kind on again: its "never" and its dismissals that lowered it no longer count. A plain dismissal stays:
    /// it hid one suggestion and never turned the kind off.
    public mutating func allowAgain(_ kind: SeriesSuggestion.Kind, at date: Date = Date()) {
        for i in answers.indices where answers[i].kind == kind.rawValue && answers[i].verdict != .keep && answers[i].trains && answers[i].counts { answers[i].withdrawn = date }
    }

    /// Both devices' changes: the newer copy of each point with the mentions of both copies, every answer, and
    /// every checked call. A copy saved by an older build has no mentions and no meeting; the other copy's stay.
    public func merged(with other: NextTimeBook) -> NextTimeBook {
        var out = NextTimeBook()
        var byID: [UUID: NextTimePoint] = [:]
        var order: [UUID] = []
        for p in points + other.points {
            if let old = byID[p.id] {
                // An emptied point wins over any copy, also a newer one from a device that changed it before it
                // heard of the move.
                if Self.forgotten(old) { continue }
                if Self.forgotten(p) { byID[p.id] = p; continue }
                let incomingWins = p.updated > old.updated
                var newer = incomingWins ? p : old
                newer.mentions = Self.union(old.mentions, p.mentions)
                newer.meeting = NextTimeMeeting.merged(newer.meeting, incomingWins ? old.meeting : p.meeting)
                byID[p.id] = newer
            } else {
                byID[p.id] = p
                order.append(p.id)
            }
        }
        out.points = order.compactMap { byID[$0] }
        // One answer for each suggestion: the newer.
        var answers: [String: SuggestionAnswer] = [:]
        for a in self.answers + other.answers where answers[a.key].map({ a.changed > $0.changed }) ?? true { answers[a.key] = a }
        out.answers = answers.values.sorted { ($0.date, $0.key) < ($1.date, $1.key) }
        out.version = max(version, other.version)
        out.localFrozen = localFrozen || other.localFrozen
        out.checked = checked.union(other.checked)
        // A call that left this profile on either copy is cleaned out of the joined points, without a new time: no
        // device changed them.
        let moved = Set((movedCalls ?? []) + (other.movedCalls ?? []))
        if !moved.isEmpty {
            out.movedCalls = moved.sorted()
            out = out.cleaned(of: moved)
        }
        return out
    }

    static func union(_ a: [NextTimePoint.Mention]?, _ b: [NextTimePoint.Mention]?) -> [NextTimePoint.Mention]? {
        var out: [NextTimePoint.Mention] = []
        for m in (a ?? []) + (b ?? []) where !out.contains(where: { $0.callID == m.callID }) { out.append(m) }
        return out.isEmpty ? nil : out.sorted { ($0.date, $0.callID) < ($1.date, $1.callID) }
    }

    // MARK: File

    /// For a page that only shows it: a missing file is an empty book, a file that cannot be read is nil. With this
    /// Mac's detail of each meeting point.
    public static func peek(in dir: URL) -> NextTimeBook? {
        let file = dir.appendingPathComponent(fileName)
        guard !StoredFile.awaitsMerge(file) else { return nil }
        var book: NextTimeBook
        if FileManager.default.fileExists(atPath: file.path) {
            guard let read = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder.coach.decode(NextTimeBook.self, from: $0) }) else { return nil }
            book = read
        } else {
            book = NextTimeBook()
        }
        book.attach(MeetingPointsLocal.peek(in: dir))
        return book
    }

    /// The book with this Mac's detail of each meeting point. A detail file that does not decode is set aside; one of a
    /// newer build is read and never saved.
    public static func load(from dir: URL) throws -> NextTimeBook {
        var book = try StoredFile.load(NextTimeBook.self, from: dir.appendingPathComponent(fileName), decoder: .coach, recovery: .synced) ?? NextTimeBook()
        let local = MeetingPointsLocal.load(in: dir)
        book.attach(local)
        book.localFrozen = (local?.version ?? 0) > MeetingPointsLocal.currentVersion
        return book
    }

    /// The book, which holds nothing of a meeting but its recordings, and this Mac's detail file beside it.
    public func save(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.coach.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
        if !localFrozen { try MeetingPointsLocal.of(self).save(in: dir) }
    }

    /// Loads, changes, and saves in one step. A book that cannot be read is never replaced by an empty one.
    @discardableResult
    public static func change(in dir: URL, _ change: (inout NextTimeBook) -> Void) throws -> NextTimeBook {
        var book = try load(from: dir)
        guard book.version <= currentVersion else { throw NewerFile() }
        change(&book)
        try book.save(to: dir)
        return book
    }
}

/// A file from a later build: this build reads it and never saves over it.
public struct NewerFile: Error, CustomStringConvertible {
    public var description: String { "The points for next time come from a newer Mossad. Update this copy to change them." }
}

/// The saved people of an invite, for the points of each person.
public enum NextTimeInvite {
    /// The ids of the invited people, without the owner: an address, a whole name, or an id, on a sure match only.
    public static func personIDs(_ attendees: [String], people refs: PersonReferences) -> [String] {
        var out: [String] = []
        for a in attendees {
            guard let id = refs.id(for: a).map(refs.canonical), refs.person(id)?.isOwner != true, !out.contains(id) else { continue }
            out.append(id)
        }
        return out
    }
}
