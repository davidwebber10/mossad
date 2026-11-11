import Foundation

/// What only this Mac keeps about people, by person id: `~/Mossad/People/local.json`. Today the owner's matches to
/// the org file. It never syncs. `org-matches.json` stays next to it, by name, for older builds.
public struct PeopleLocal: Codable, Equatable, Sendable {
    public static let fileName = "local.json"
    public static let currentVersion = 1

    public var version = PeopleLocal.currentVersion
    /// Person id to an id of the org file, or `OrgMatches.outside`.
    public var org: [String: String] = [:]

    public init(org: [String: String] = [:]) { self.org = org }

    enum CodingKeys: String, CodingKey { case version, org }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        org = try c.decodeIfPresent([String: String].self, forKey: .org) ?? [:]
    }

    static func url(_ paths: Paths) -> URL { paths.people.appendingPathComponent(fileName) }

    /// Nil when there is no file. A file that does not decode, or one from a newer build, is nil too, and it is
    /// never written over: `isWritable` says so.
    public static func load(paths: Paths) -> PeopleLocal? {
        (try? Data(contentsOf: url(paths))).flatMap { try? JSONDecoder().decode(PeopleLocal.self, from: $0) }
    }

    /// False when a file is there that this build cannot read or that a newer build wrote.
    public static func isWritable(paths: Paths) -> Bool {
        guard let data = try? Data(contentsOf: url(paths)) else { return true }
        guard let local = try? JSONDecoder().decode(PeopleLocal.self, from: data) else { return false }
        return local.version <= currentVersion
    }

    public func save(paths: Paths) throws {
        try FileManager.default.createDirectory(at: paths.people, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(paths), options: .atomic)
    }
}

extension OrgMatches {
    /// The matches by person id, from the matches by name: each live person whose name no other live person has.
    /// A person with no match by the name of now keeps no entry; an entry of another id stays as it is.
    public func byPerson(_ people: [Person], keeping old: [String: String] = [:]) -> [String: String] {
        var out = old
        let live = people.filter(\.isLive)
        let counts = Dictionary(grouping: live, by: { OrgChart.normalize($0.displayName) }).mapValues(\.count)
        for p in live where counts[OrgChart.normalize(p.displayName)] == 1 {
            out[p.id.rawValue] = byName[OrgChart.normalize(p.displayName)]
        }
        return out
    }

    /// The matches by name with the matches by id over them, under each person's name of now: a renamed person
    /// keeps the match.
    public mutating func overlay(_ local: PeopleLocal, people: [Person]) {
        let all = Dictionary(people.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
        let live = people.filter(\.isLive)
        let counts = Dictionary(grouping: live, by: { OrgChart.normalize($0.displayName) }).mapValues(\.count)
        // A merged id points to the person that took it in; that person's own entry comes last and wins.
        for (id, value) in local.org.sorted(by: { (all[$0.key]?.mergedInto == nil ? 1 : 0, $0.key) < (all[$1.key]?.mergedInto == nil ? 1 : 0, $1.key) }) {
            var current = id
            var seen: Set<String> = [id]
            while let next = all[current]?.mergedInto?.rawValue, seen.insert(next).inserted { current = next }
            guard let p = all[current], p.isLive, counts[OrgChart.normalize(p.displayName)] == 1 else { continue }
            if value == Self.outside { setOutside(p.displayName) } else { set(p.displayName, to: value) }
        }
    }
}
