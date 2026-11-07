import Foundation

/// The company's reporting tree, read from an HR export with the columns
/// `Last Name, First Name, Position Title, Supervisor` (the supervisor as "Last, First").
/// The file stays on this Mac in `~/Mossad/People/org.csv`.
public struct OrgChart: Sendable {
    public struct Person: Equatable, Sendable, Hashable {
        /// "last, first" lowercased. People who share a name add their title (and supervisor if needed) after a "#",
        /// so an id does not change when a later export lists them in another order.
        public let id: String
        public let first: String
        public let last: String
        public let title: String
        public let managerID: String?

        public var fullName: String { "\(first) \(last)" }
    }

    public struct Match: Equatable, Sendable {
        public enum How: Equatable, Sendable { case exact, nickname, manual }
        public let person: Person
        public let how: How
    }

    public enum ParseError: Error, Equatable { case missingColumns }

    /// One person's part of the tree as the People page draws it: the manager on top, then a column for the
    /// person and each peer, with that column's direct reports stacked beneath.
    public struct Team: Equatable, Sendable {
        public struct Column: Equatable, Sendable {
            public let head: Person
            public let reports: [Person]
        }
        public let focus: String
        public let top: Person?
        public let columns: [Column]
    }

    /// An empty export with the four columns, for someone whose HR system is not Paylocity.
    public static let templateCSV = "Last Name,First Name,Position Title,Supervisor\n"

    public let people: [Person]
    /// The longest chain from the top down, counting both ends; 0 for an empty file.
    public let levels: Int
    private let byID: [String: Person]
    private let byLast: [String: [Person]]
    private let children: [String: [Person]]

    private init(people: [Person]) {
        self.people = people
        let byID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        self.byID = byID
        byLast = Dictionary(grouping: people) { Self.normalize($0.last) }
        children = Dictionary(grouping: people.filter { $0.managerID != nil }) { $0.managerID! }
        levels = people.map { Self.chain(of: $0.id, in: byID).count + 1 }.max() ?? 0
    }

    // MARK: Reading the tree

    public func person(id: String) -> Person? { byID[id] }
    public func manager(of id: String) -> Person? { byID[id]?.managerID.flatMap { byID[$0] } }

    public func reports(of id: String) -> [Person] {
        (children[id] ?? []).sorted { ($0.last, $0.first) < ($1.last, $1.first) }
    }

    public func peers(of id: String) -> [Person] {
        guard let m = byID[id]?.managerID else { return [] }
        return reports(of: m).filter { $0.id != id }
    }

    /// The person's manager, the person and their peers, and each one's reports. A person at the top (or whose
    /// manager is not in the file) is drawn on top with their reports as the columns.
    public func team(around id: String) -> Team {
        guard let person = byID[id] else { return Team(focus: id, top: nil, columns: []) }
        func column(_ p: Person) -> Team.Column { Team.Column(head: p, reports: reports(of: p.id)) }
        if let manager = manager(of: id) {
            return Team(focus: id, top: manager, columns: [column(person)] + peers(of: id).map(column))
        }
        return Team(focus: id, top: person, columns: reports(of: id).map(column))
    }

    /// The ids from the person's manager up to the top. Stops at a loop in the file.
    public func chain(of id: String) -> [String] { Self.chain(of: id, in: byID) }

    private static func chain(of id: String, in byID: [String: Person]) -> [String] {
        var out: [String] = [], seen: Set<String> = [id]
        var next = byID[id]?.managerID
        while let n = next, byID[n] != nil, seen.insert(n).inserted {
            out.append(n)
            next = byID[n]?.managerID
        }
        return out
    }

    // MARK: Matching saved people

    /// Finds a saved person ("First Last") in the file. The owner's matches win, then the same first and last name,
    /// then a short form of the first name with the same last name. A name that fits more than one person is left alone.
    public func person(matching name: String, overrides: OrgMatches) -> Match? {
        if overrides.isOutside(name) { return nil }
        // A saved match to an id the new file lacks stays unmatched; it must not move to another person.
        if let id = overrides.personID(for: name) { return byID[id].map { Match(person: $0, how: .manual) } }
        let words = Self.normalize(name).split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }
        func firstWords(_ p: Person) -> (full: String, word: String) {
            let f = Self.normalize(p.first)
            return (f, f.split(separator: " ").first.map(String.init) ?? f)
        }
        // "Maria De La Cruz" may be first "Maria" and last "De La Cruz", so every split point is tried.
        let splits = (1..<words.count).map { (given: words[..<$0].joined(separator: " "), last: words[$0...].joined(separator: " ")) }
        func find(_ fits: (Person, String, String) -> Bool) -> [Person] {
            var out: [Person] = []
            for s in splits {
                for p in byLast[s.last] ?? [] where fits(p, s.given, words[0]) && !out.contains(p) { out.append(p) }
            }
            return out
        }
        let full = find { p, g, _ in firstWords(p).full == g }
        if !full.isEmpty { return full.count == 1 ? Match(person: full[0], how: .exact) : nil }
        let word = find { p, _, w in firstWords(p).word == w }
        if !word.isEmpty { return word.count == 1 ? Match(person: word[0], how: .exact) : nil }
        let nick = find { p, _, w in Nicknames.related(firstWords(p).word, w) }
        return nick.count == 1 ? Match(person: nick[0], how: .nickname) : nil
    }

    /// "Name, Title" for each matched name, in order; the summary and the coach read these as context.
    public func contextLines(for names: [String], overrides: OrgMatches) -> [String] {
        var seen: Set<String> = []
        return names.compactMap { name in
            guard seen.insert(name).inserted, let m = person(matching: name, overrides: overrides),
                  !m.person.title.isEmpty else { return nil }
            return "\(name), \(m.person.title)"
        }
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Parsing

    public static func parse(csv text: String) throws -> OrgChart {
        var rows = records(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        guard !rows.isEmpty else { throw ParseError.missingColumns }
        let header = rows.removeFirst().map { normalize($0) }
        guard let li = header.firstIndex(of: "last name"), let fi = header.firstIndex(of: "first name"),
              let ti = header.firstIndex(of: "position title"), let si = header.firstIndex(of: "supervisor") else {
            throw ParseError.missingColumns
        }
        struct Row { var first, last, title, supervisor: String }
        let need = max(li, fi, ti, si)
        let parsed: [Row] = rows.compactMap { r in
            guard r.count > need else { return nil }
            let row = Row(first: collapse(r[fi]), last: collapse(r[li]), title: collapse(r[ti]), supervisor: collapse(r[si]))
            return row.first.isEmpty && row.last.isEmpty ? nil : row
        }

        var count: [String: Int] = [:]
        for r in parsed { count["\(normalize(r.last)), \(normalize(r.first))", default: 0] += 1 }
        var ids: [String] = []
        var used: [String: Int] = [:]
        let withTitle = Dictionary(grouping: parsed) { "\(normalize($0.last)), \(normalize($0.first))#\(normalize($0.title))" }
        for r in parsed {
            let base = "\(normalize(r.last)), \(normalize(r.first))"
            var id = base
            if count[base]! > 1 {
                id = "\(base)#\(normalize(r.title))"
                if withTitle[id]!.count > 1 { id += "#\(normalize(r.supervisor))" }
            }
            // Only identical rows still collide; they get an ordinal, which cannot be told apart anyway.
            used[id, default: 0] += 1
            ids.append(used[id]! == 1 ? id : "\(id)#\(used[id]!)")
        }
        // A supervisor name that fits two people cannot say which one, so the manager stays unknown.
        let firstWordIndex = Dictionary(grouping: parsed.indices) { i -> String in
            "\(normalize(parsed[i].last)), \(normalize(parsed[i].first).split(separator: " ").first.map(String.init) ?? "")"
        }
        func manager(_ supervisor: String) -> String? {
            let parts = supervisor.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).map { normalize(String($0)) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            let base = "\(parts[0]), \(parts[1])"
            if let n = count[base] { return n == 1 ? base : nil }
            let hits = firstWordIndex["\(parts[0]), \(parts[1].split(separator: " ").first.map(String.init) ?? "")"] ?? []
            return hits.count == 1 ? ids[hits[0]] : nil
        }
        let people = parsed.enumerated().map { i, r in
            let m = manager(r.supervisor)
            return Person(id: ids[i], first: r.first, last: r.last, title: r.title, managerID: m == ids[i] ? nil : m)
        }
        return OrgChart(people: people)
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Splits CSV text into rows of fields. Quoted fields may hold commas, line breaks, and doubled quotes.
    private static func records(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = String.UnicodeScalarView()
        var quoted = false, pendingQuote = false, any = false
        func endField() { row.append(String(field)); field = String.UnicodeScalarView(); any = true }
        func endRow() {
            if any || !field.isEmpty { endField() }
            if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
            row = []; any = false
        }
        for c in text.unicodeScalars {
            if pendingQuote {
                pendingQuote = false
                if c == "\"" { field.append(c); continue }
                quoted = false
            }
            if quoted {
                if c == "\"" { pendingQuote = true } else { field.append(c) }
                continue
            }
            switch c {
            case "\"": quoted = true; any = true
            case ",": endField()
            case "\n": endRow()
            case "\r": break
            default: field.append(c)
            }
        }
        endRow()
        return rows
    }

    // MARK: On disk

    static func fileURL(_ paths: Paths) -> URL { paths.people.appendingPathComponent("org.csv") }

    private static let cache = ChartCache()

    /// Reads `~/Mossad/People/org.csv`; nil when none was imported. Re-read only when the file changes.
    public static func load(paths: Paths) -> OrgChart? {
        let url = fileURL(paths)
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        if let hit = cache.get(url.path, modified) { return hit }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
              let chart = try? parse(csv: text) else { return nil }
        cache.set(url.path, modified, chart)
        return chart
    }

    /// Checks the file, then copies it to `~/Mossad/People/org.csv`, replacing an earlier one.
    @discardableResult
    public static func `import`(from url: URL, paths: Paths) throws -> OrgChart {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw ParseError.missingColumns }
        let chart = try parse(csv: text)
        try FileManager.default.createDirectory(at: paths.people, withIntermediateDirectories: true)
        try data.write(to: fileURL(paths), options: .atomic)
        return chart
    }

    /// The lines the summary and the coach get for the people in a call; empty with no org file.
    public static func contextLines(for names: [String], paths: Paths) -> [String] {
        guard let chart = load(paths: paths) else { return [] }
        return chart.contextLines(for: names, overrides: OrgMatches.load(paths: paths))
    }
}

private final class ChartCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: (path: String, modified: Date, chart: OrgChart)?

    func get(_ path: String, _ modified: Date) -> OrgChart? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entry, e.path == path, e.modified == modified else { return nil }
        return e.chart
    }

    func set(_ path: String, _ modified: Date, _ chart: OrgChart) {
        lock.lock(); defer { lock.unlock() }
        entry = (path, modified, chart)
    }
}
