import Foundation

/// Something the owner promised in a call, or added by hand. Separate from action items: these are theirs.
public struct Commitment: Codable, Equatable, Sendable, Identifiable, Hashable {
    public enum Status: Sendable { case overdue, dueToday, upcoming, noDate, done }

    public var id = UUID()
    public var text: String
    /// Who it was promised to, when the call says.
    public var to: String?
    public var callID: String?
    public var callTitle: String?
    /// When it was said: the call's start plus the moment.
    public var madeAt: Date
    /// The moment in the call, in seconds from its start.
    public var at: TimeInterval?
    public var quote: String?
    /// The day it is due, at the start of that day.
    public var due: Date?
    public var done: Date?
    /// Kept as a marker, so a sync from another device does not bring it back.
    public var deleted = false
    public var created: Date
    /// The last change on any device; the newer copy wins when devices merge.
    public var updated: Date

    public init(text: String, to: String?, callID: String?, callTitle: String?, madeAt: Date, at: TimeInterval? = nil,
                quote: String? = nil, due: Date?, created: Date = Date()) {
        self.text = text
        self.to = to
        self.callID = callID
        self.callTitle = callTitle
        self.madeAt = madeAt
        self.at = at
        self.quote = quote
        self.due = due
        self.created = created
        updated = created
    }

    public func status(now: Date = Date(), calendar: Calendar = .current) -> Status {
        if done != nil { return .done }
        guard let due else { return .noDate }
        let today = calendar.startOfDay(for: now), day = calendar.startOfDay(for: due)
        return day < today ? .overdue : day == today ? .dueToday : .upcoming
    }
}

/// Every commitment, and which calls were already read for them. Lives in `~/Mossad/Commitments`.
public struct CommitmentBook: Codable, Equatable, Sendable {
    public static let fileName = "commitments.json"

    public var items: [Commitment] = []
    /// Calls already read, so each call is read once.
    public var checked: Set<String> = []

    public init() {}

    public var visible: [Commitment] { items.filter { !$0.deleted } }

    /// Adds what was found in a call, without repeating a commitment already there for that call.
    public mutating func add(found: [Commitment], callID: String, at date: Date) {
        for c in found {
            let key = c.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, !items.contains(where: { $0.callID == c.callID && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key }) else { continue }
            var c = c
            c.text = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
            c.updated = date
            items.append(c)
        }
        checked.insert(callID)
    }

    public mutating func update(_ id: UUID, at date: Date = Date(), _ change: (inout Commitment) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        items[i].updated = date
    }

    public mutating func delete(_ id: UUID, at date: Date = Date()) {
        update(id, at: date) { $0.deleted = true }
    }

    /// Both devices' changes: the newer copy of each commitment, and every checked call.
    public func merged(with other: CommitmentBook) -> CommitmentBook {
        var out = CommitmentBook()
        var byID: [UUID: Commitment] = [:]
        var order: [UUID] = []
        for c in items + other.items {
            if let old = byID[c.id] { if c.updated > old.updated { byID[c.id] = c } } else { byID[c.id] = c; order.append(c.id) }
        }
        out.items = order.compactMap { byID[$0] }
        out.checked = checked.union(other.checked)
        return out
    }

    public static func load(from dir: URL) throws -> CommitmentBook {
        let url = dir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return CommitmentBook() }
        return try JSONDecoder.coach.decode(CommitmentBook.self, from: Data(contentsOf: url))
    }

    public func save(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.coach.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// Reads one call for what the owner promised.
public struct CommitmentFinder: Sendable {
    private let llm: any LanguageModel
    private let ownerName: String

    public init(llm: any LanguageModel, ownerName: String) {
        self.llm = llm
        self.ownerName = ownerName
    }

    static var schema: [String: Any] {
        Schema.object(["commitments": Schema.array(Schema.object([
            "text": Schema.string, "to": Schema.nullableString, "due": Schema.nullableString,
            "quote": Schema.string, "at_seconds": Schema.nullableNumber,
        ]))])
    }

    public func find(in r: CallRecord) async throws -> [Commitment] {
        let day = r.start.formatted(.dateTime.weekday(.wide).year().month(.wide).day())
        let system = """
        You find the commitments \(ownerName) made in a meeting: things they personally promised to do, deliver, \
        decide, send, or follow up on, said in their own words ("I'll send that", "let me check and get back to you", \
        "I can have it by Friday"). Leave out tasks others took, tasks assigned to \(ownerName) that they did not \
        accept, decisions, ideas, and things they said they might do. Several promises about one deliverable are one \
        commitment. text is the commitment as a short task starting with a verb, at most 15 words. to is the person \
        it was promised to when clear, by name as written in the transcript, else null. due is the date in \
        yyyy-MM-dd when a time was said or clearly implied ("by Tuesday" means the next Tuesday after the meeting; \
        "end of week" means that Friday; "tomorrow" means the next day), else null. quote is the exact words, and \
        at_seconds the time of that line ([00:12:40] is 760). The meeting was on \(day). Return an empty list when \
        there are none.
        """
        let out = try await llm.json(system: system, user: "## Transcript\n" + MarkdownWriter.transcript(r), schema: Self.schema,
                                     effort: .medium, purpose: .summary, as: Output.self)
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = .current
        parser.dateFormat = "yyyy-MM-dd"
        return out.commitments.compactMap { c in
            guard let text = c.text.nonBlank else { return nil }
            return Commitment(text: text, to: c.to?.nonBlank, callID: r.id, callTitle: r.title,
                              madeAt: r.start.addingTimeInterval(c.at_seconds ?? 0), at: c.at_seconds, quote: c.quote.nonBlank,
                              due: c.due.flatMap { parser.date(from: $0) })
        }
    }

    private struct Output: Decodable {
        let commitments: [Item]
        struct Item: Decodable {
            let text: String
            let to, due: String?
            let quote: String
            let at_seconds: Double?
        }
    }
}

/// Reads each written call once for commitments, oldest first.
public actor CommitmentRunner {
    private let paths: Paths
    private let finder: CommitmentFinder
    private let since: Date

    public init(paths: Paths, finder: CommitmentFinder, since: Date) {
        self.paths = paths
        self.finder = finder
        self.since = since
    }

    static func pending(_ records: [CallRecord], since: Date, checked: Set<String>) -> [CallRecord] {
        records.filter { $0.status == .written && $0.start >= since && !checked.contains($0.id) && !$0.utterances.isEmpty }
            .sorted { $0.start < $1.start }
    }

    /// Returns how many calls were read. Stops at the first failure; the next run retries it.
    @discardableResult
    public func run() async -> Int {
        let records = ProcessingQueue(paths: paths).allRecords()
        guard let book = try? CommitmentBook.load(from: paths.commitments) else { return 0 }
        var done = 0
        for r in Self.pending(records, since: since, checked: book.checked) {
            do {
                let found = try await UsageContext.$callID.withValue(r.id) { try await finder.find(in: r) }
                // Read again: the owner may have edited a commitment while this one ran.
                var fresh = (try? CommitmentBook.load(from: paths.commitments)) ?? book
                fresh.add(found: found, callID: r.id, at: Date())
                try fresh.save(to: paths.commitments)
                done += 1
            } catch {
                Log.error("Finding commitments in \(r.id) failed: \(error)")
                break
            }
        }
        return done
    }
}

/// Commitments in the order to act on them.
public struct CommitmentGroup: Sendable, Identifiable {
    public enum Kind: Int, Sendable, CaseIterable {
        case overdue, today, thisWeek, later, noDate, done

        public var title: String {
            switch self {
            case .overdue: "Overdue"
            case .today: "Today"
            case .thisWeek: "Next 7 days"
            case .later: "Later"
            case .noDate: "No date"
            case .done: "Done"
            }
        }
    }

    public var id: Kind { kind }
    public var kind: Kind
    public var items: [Commitment]

    public static func make(_ list: [Commitment], now: Date = Date(), calendar: Calendar = .current) -> [CommitmentGroup] {
        let today = calendar.startOfDay(for: now)
        let week = calendar.date(byAdding: .day, value: 7, to: today)!
        func kind(_ c: Commitment) -> Kind {
            if c.done != nil { return .done }
            guard let due = c.due.map({ calendar.startOfDay(for: $0) }) else { return .noDate }
            return due < today ? .overdue : due == today ? .today : due <= week ? .thisWeek : .later
        }
        return Kind.allCases.compactMap { k in
            let items = list.filter { !$0.deleted && kind($0) == k }.sorted {
                k == .done ? ($0.done ?? .distantPast) > ($1.done ?? .distantPast)
                    : ($0.due ?? $0.madeAt, $0.madeAt) < ($1.due ?? $1.madeAt, $1.madeAt)
            }
            return items.isEmpty ? nil : CommitmentGroup(kind: k, items: items)
        }
    }
}
