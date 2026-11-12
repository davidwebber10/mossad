import Foundation

/// Something the owner wants to raise the next time: at the next meeting of a series, or the next time they see a
/// person. The owner's own list; the coach's suggestions stay apart (`SeriesSuggestion`) until the owner keeps one.
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
    public var isForPerson: Bool { personID != nil && seriesID == nil }

    public func belongs(to s: MeetingSeries) -> Bool { s.matches(id: seriesID, keys: seriesKeys) }
}

/// The owner's answer to a suggestion: kept (yes), dismissed (no), or never this kind again.
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

    /// The time of its last change, which wins when devices merge.
    public var changed: Date { max(date, withdrawn ?? .distantPast) }
    public var counts: Bool { withdrawn == nil }

    public init(key: String, kind: String, verdict: Verdict, date: Date) {
        self.key = key
        self.kind = kind
        self.verdict = verdict
        self.date = date
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

    public init() {}

    enum CodingKeys: String, CodingKey { case version, points, answers, checked }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        points = try c.decodeIfPresent([NextTimePoint].self, forKey: .points) ?? []
        answers = try c.decodeIfPresent([SuggestionAnswer].self, forKey: .answers) ?? []
        checked = Set(try c.decodeIfPresent([String].self, forKey: .checked) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(points, forKey: .points)
        try c.encode(answers, forKey: .answers)
        try c.encode(checked.sorted(), forKey: .checked)
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

    /// The open points for an upcoming meeting: its series' first, then the ones for each invited person.
    /// `people` are the saved ids of the invited people.
    public func points(for series: MeetingSeries?, people: [String], canonical: (String) -> String = { $0 }) -> [NextTimePoint] {
        let own = series.map { points(of: $0).open } ?? []
        var seen = Set(own.map(\.id))
        var theirs: [NextTimePoint] = []
        for id in people { for p in points(forPerson: id, canonical: canonical) where seen.insert(p.id).inserted { theirs.append(p) } }
        return own + theirs
    }

    /// The points that a meeting discussed: found by the check, or marked by the owner on that meeting.
    public func discussed(in callID: String) -> [NextTimePoint] {
        visible.filter { $0.done?.callID == callID }
    }

    // MARK: Changes

    /// Adds a point at the end of its list.
    @discardableResult
    public mutating func add(_ text: String, series: MeetingSeries? = nil, personID: String? = nil, personName: String? = nil,
                             suggestion: String? = nil, at date: Date = Date()) -> NextTimePoint? {
        guard let text = text.nonBlank, series != nil || personID != nil else { return nil }
        let list = series.map { points(of: $0).open } ?? personID.map { points(forPerson: $0) } ?? []
        var p = NextTimePoint(text: text, series: series, personID: series == nil ? personID : nil, personName: series == nil ? personName : nil,
                              rank: (list.map(\.rank).max() ?? 0) + 1, created: date)
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

    public mutating func answer(_ suggestion: SeriesSuggestion, _ verdict: SuggestionAnswer.Verdict, at date: Date = Date()) {
        answers.removeAll { $0.key == suggestion.key }
        answers.append(SuggestionAnswer(key: suggestion.key, kind: suggestion.kind.rawValue, verdict: verdict, date: date))
    }

    /// Undo of an answer: the suggestion can come again, and a point kept from it goes. The answer stays, marked.
    public mutating func takeBack(_ key: String, at date: Date = Date()) {
        for i in answers.indices where answers[i].key == key && answers[i].counts { answers[i].withdrawn = date }
        for p in points where p.suggestion == key && !p.deleted { delete(p.id, at: date) }
    }

    /// Turns a kind on again: its "never" and its dismissals no longer count.
    public mutating func allowAgain(_ kind: SeriesSuggestion.Kind, at date: Date = Date()) {
        for i in answers.indices where answers[i].kind == kind.rawValue && answers[i].verdict != .keep && answers[i].counts { answers[i].withdrawn = date }
    }

    /// Both devices' changes: the newer copy of each point, every answer, and every checked call.
    public func merged(with other: NextTimeBook) -> NextTimeBook {
        var out = NextTimeBook()
        var byID: [UUID: NextTimePoint] = [:]
        var order: [UUID] = []
        for p in points + other.points {
            if let old = byID[p.id] {
                if p.updated > old.updated { byID[p.id] = p }
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
        out.checked = checked.union(other.checked)
        return out
    }

    // MARK: File

    /// For a page that only shows it: a missing file is an empty book, a file that cannot be read is nil.
    public static func peek(in dir: URL) -> NextTimeBook? {
        let file = dir.appendingPathComponent(fileName)
        guard !StoredFile.awaitsMerge(file) else { return nil }
        guard FileManager.default.fileExists(atPath: file.path) else { return NextTimeBook() }
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder.coach.decode(NextTimeBook.self, from: $0) }
    }

    public static func load(from dir: URL) throws -> NextTimeBook {
        try StoredFile.load(NextTimeBook.self, from: dir.appendingPathComponent(fileName), decoder: .coach, recovery: .synced) ?? NextTimeBook()
    }

    public func save(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.coach.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
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
