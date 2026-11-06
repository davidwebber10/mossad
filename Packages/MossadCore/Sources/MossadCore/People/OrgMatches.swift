import Foundation

/// The owner's own matches of saved people to the org file, kept in `org-matches.json`.
/// Keys are normalized saved names; a value is a person id in the file, or `outside`.
public struct OrgMatches: Codable, Equatable, Sendable {
    public static let outside = "outside"

    public private(set) var byName: [String: String] = [:]

    public init() {}

    public func personID(for name: String) -> String? {
        byName[OrgChart.normalize(name)].flatMap { $0 == Self.outside ? nil : $0 }
    }

    public func isOutside(_ name: String) -> Bool { byName[OrgChart.normalize(name)] == Self.outside }

    public mutating func set(_ name: String, to personID: String) { byName[OrgChart.normalize(name)] = personID }
    public mutating func setOutside(_ name: String) { byName[OrgChart.normalize(name)] = Self.outside }
    public mutating func clear(_ name: String) { byName[OrgChart.normalize(name)] = nil }

    static func url(_ paths: Paths) -> URL { paths.people.appendingPathComponent("org-matches.json") }

    public static func load(paths: Paths) -> OrgMatches {
        (try? Data(contentsOf: url(paths))).flatMap { try? JSONDecoder().decode(OrgMatches.self, from: $0) } ?? OrgMatches()
    }

    public func save(paths: Paths) throws {
        try FileManager.default.createDirectory(at: paths.people, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(paths), options: .atomic)
    }
}
