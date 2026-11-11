import Foundation

/// The owner's own matches of saved people to the org file, kept in `org-matches.json`.
/// Keys are normalized saved names; a value is a person id in the file, or `outside`.
public struct OrgMatches: Codable, Equatable, Sendable {
    public static let outside = "outside"

    public private(set) var byName: [String: String] = [:]
    /// The names the owner cleared since the load: only these take a match by id away. A name that is only missing
    /// (a rename after the load) keeps it.
    public private(set) var cleared: Set<String> = []

    enum CodingKeys: String, CodingKey { case byName }

    public init() {}

    public static func == (a: OrgMatches, b: OrgMatches) -> Bool { a.byName == b.byName }

    public func personID(for name: String) -> String? {
        byName[OrgChart.normalize(name)].flatMap { $0 == Self.outside ? nil : $0 }
    }

    public func isOutside(_ name: String) -> Bool { byName[OrgChart.normalize(name)] == Self.outside }

    public mutating func set(_ name: String, to personID: String) { byName[OrgChart.normalize(name)] = personID; cleared.remove(OrgChart.normalize(name)) }
    public mutating func setOutside(_ name: String) { byName[OrgChart.normalize(name)] = Self.outside; cleared.remove(OrgChart.normalize(name)) }
    public mutating func clear(_ name: String) { byName[OrgChart.normalize(name)] = nil; cleared.insert(OrgChart.normalize(name)) }

    static func url(_ paths: Paths) -> URL { paths.people.appendingPathComponent("org-matches.json") }

    /// The matches by name, with the ones by person id in `local.json` over them under each person's name of now.
    public static func load(paths: Paths) -> OrgMatches {
        var matches = loadByName(paths: paths)
        if let local = PeopleLocal.load(paths: paths), let people = PeopleStore.peek(in: paths.people) { matches.overlay(local, people: people) }
        return matches
    }

    /// `org-matches.json` alone, as older builds read it.
    static func loadByName(paths: Paths) -> OrgMatches {
        (try? Data(contentsOf: url(paths))).flatMap { try? JSONDecoder().decode(OrgMatches.self, from: $0) } ?? OrgMatches()
    }

    /// Saves the matches by name, for older builds, and by person id, where the people store has the people.
    public func save(paths: Paths) throws {
        try FileManager.default.createDirectory(at: paths.people, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(paths), options: .atomic)
        try saveByPerson(paths: paths)
    }

    /// At launch and after a rename: `local.json` from the matches, and `org-matches.json` with each renamed
    /// person's match under the name of now too, for older builds (after a copy of the file as it was). Returns
    /// whether a file was written.
    @discardableResult
    public static func linkPeople(paths: Paths) throws -> Bool {
        let matches = load(paths: paths), byName = loadByName(paths: paths)
        guard matches != byName else { return try matches.saveByPerson(paths: paths) }
        guard ReferenceBackup.keep(url(paths), as: "org-matches.json", paths: paths) else { return false }
        try matches.save(paths: paths)
        return true
    }

    /// Writes `local.json` from these matches when the people store has people. Nothing when it is the same, when
    /// there are no people, or when the file there cannot be written over. Returns whether it wrote.
    @discardableResult
    public func saveByPerson(paths: Paths) throws -> Bool {
        guard let people = PeopleStore.peek(in: paths.people), !people.isEmpty, PeopleLocal.isWritable(paths: paths) else { return false }
        let old = PeopleLocal.load(paths: paths)
        let next = PeopleLocal(org: byPerson(people, keeping: old?.org ?? [:]))
        guard next != old, !(old == nil && next.org.isEmpty) else { return false }
        try next.save(paths: paths)
        return true
    }
}
