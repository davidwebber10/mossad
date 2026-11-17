import CryptoKit
import Foundation

/// The content hashes of imported files, each with the id of its recording, so a file shared again is known whatever
/// its dates. Kept in `Recordings/imported.json` while the recording is in the outbox or the meetings.
public struct ImportMemory: Codable, Equatable, Sendable {
    public static let fileName = "imported.json"

    private var ids: [String: String] = [:]

    public init() {}

    public func id(of hash: String) -> String? { ids[hash] }

    public mutating func remember(hash: String, id: String) { ids[hash] = id }

    /// Forgets each file whose recording is gone, so the owner can add it again.
    /// A meeting that came back as `<id>-iphone` keeps its file, as `CallImport.plan` reads ids.
    public mutating func keep(only ids: Set<String>) {
        let bare = Set(ids.map(CallImport.bare))
        self.ids = self.ids.filter { bare.contains($0.value) }
    }

    /// SHA-256 as hex, read in chunks so a long recording never sits whole in memory.
    public static func hash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A missing or unreadable file is an empty memory.
    public static func load(from file: URL) -> ImportMemory {
        guard let data = try? Data(contentsOf: file), let memory = try? JSONDecoder().decode(ImportMemory.self, from: data) else { return ImportMemory() }
        return memory
    }

    public func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}
