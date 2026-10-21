import Foundation

public struct VoiceProfile: Codable, Equatable, Sendable {
    public var name: String
    public var isOwner: Bool
    /// Newest last; at most `VoiceLibrary.maxEmbeddings`.
    public var embeddings: [[Float]]
}

/// Known voices, stored as `voices.json` in the Voices directory.
public final class VoiceLibrary: @unchecked Sendable {
    static let maxEmbeddings = 20

    private let url: URL
    private let lock = NSLock()
    private var storage: [VoiceProfile]
    public var matchThreshold: Float = 0.65

    public init(directory: URL) {
        url = directory.appendingPathComponent("voices.json")
        storage = (try? JSONDecoder().decode([VoiceProfile].self, from: Data(contentsOf: url))) ?? []
    }

    public var profiles: [VoiceProfile] { lock.withLock { storage } }
    public var owner: VoiceProfile? { profiles.first { $0.isOwner } }

    /// The closest profile by cosine similarity to its centroid, when above the threshold.
    public func bestMatch(_ embedding: [Float]) -> (name: String, score: Float)? {
        let scored = profiles.compactMap { p -> (String, Float)? in
            guard let centroid = Self.centroid(p.embeddings) else { return nil }
            return (p.name, Self.cosine(embedding, centroid))
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= matchThreshold else { return nil }
        return best
    }

    public func add(_ embedding: [Float], to name: String, isOwner: Bool = false) throws {
        try lock.withLock {
            if let i = storage.firstIndex(where: { $0.name == name }) {
                storage[i].embeddings.append(embedding)
                storage[i].embeddings = Array(storage[i].embeddings.suffix(Self.maxEmbeddings))
                if isOwner { storage[i].isOwner = true }
            } else {
                storage.append(VoiceProfile(name: name, isOwner: isOwner, embeddings: [embedding]))
            }
            try save()
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(storage).write(to: url, options: .atomic)
    }

    static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == sum.count {
            for i in v.indices { sum[i] += v[i] }
        }
        return normalized(sum)
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        let na = normalized(a), nb = normalized(b)
        return zip(na, nb).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
