import Foundation

public struct VoiceProfile: Codable, Equatable, Sendable {
    public var name: String
    public var isOwner: Bool
    /// Newest last; at most `VoiceLibrary.maxEmbeddings`.
    public var embeddings: [[Float]]
    /// Picked by the owner from the call's attendees when naming the speaker, or the invite's address of a voice
    /// named from the invite.
    public var email: String? = nil
    /// The call whose invite named this voice, while that is all the proof there is. Nil once the owner named the
    /// voice or another call confirmed it. An older build reads the profile as firm.
    public var provisional: String? = nil
}

/// Known voices, stored as `voices.json` in the Voices directory.
public final class VoiceLibrary: @unchecked Sendable {
    static let maxEmbeddings = 20

    private let url: URL
    private let lock = NSLock()
    private var storage: [VoiceProfile]
    public var matchThreshold: Float = 0.65

    /// Set when `voices.json` was there and could not be read; a damaged file is moved aside first.
    public let loadError: Error?

    public init(directory: URL) {
        url = directory.appendingPathComponent("voices.json")
        do {
            storage = try StoredFile.load([VoiceProfile].self, from: url, recovery: .local) ?? []
            loadError = nil
        } catch {
            // Unreadable is not empty: a read error keeps the file, and saves are refused until a restart reads it.
            storage = []
            loadError = error
        }
    }

    /// The people and the samples that follow this library, once the app has them. Without it the library works
    /// as before, on `voices.json` alone.
    public var identity: VoiceIdentity? {
        get { lock.withLock { attached } }
        set { lock.withLock { attached = newValue } }
    }
    private var attached: VoiceIdentity?

    public var profiles: [VoiceProfile] { lock.withLock { storage } }
    public var owner: VoiceProfile? { profiles.first { $0.isOwner } }
    /// Each provisional voice with the call that made it.
    public var provisional: [String: String] {
        Dictionary(profiles.compactMap { p in p.provisional.map { (p.name, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// The closest profile by cosine similarity to its centroid, when above the threshold.
    public func bestMatch(_ embedding: [Float]) -> (name: String, score: Float)? {
        guard let best = ranked(embedding).first, best.score >= matchThreshold else { return nil }
        return (best.name, best.score)
    }

    /// Every profile with a voice by cosine similarity to its centroid, best first.
    public func ranked(_ embedding: [Float]) -> [VoiceScore] {
        profiles.compactMap { p -> VoiceScore? in
            guard let centroid = Self.centroid(p.embeddings) else { return nil }
            return VoiceScore(name: p.name, score: Self.cosine(embedding, centroid))
        }.sorted { $0.score > $1.score }
    }

    /// `source` says which call and speaker the sample came from. With it, a sample learned again from the same
    /// call replaces the one before, and the sample can be taken back when the owner corrects that speaker.
    public func add(_ embedding: [Float], to name: String, isOwner: Bool = false, source: VoiceSampleSource? = nil) throws {
        try lock.withLock {
            let i: Int
            if let known = storage.firstIndex(where: { $0.name == name }) {
                i = known
                let firmed = settle(&storage[i], embedding, source)
                // The same call identified again ("Transcribe again") gives the same sample; one copy is enough.
                if storage[i].embeddings.contains(embedding) {
                    if isOwner, !storage[i].isOwner { storage[i].isOwner = true; try save() } else if firmed { try save() }
                    if let source { attached?.sync(storage[i], new: (embedding, source), among: storage) }
                    return
                }
                // A new transcript gives a fingerprint that is a little different: it replaces that call's old one.
                if let attached, let source {
                    let old = attached.replaced(by: embedding, in: storage[i], source: source)
                    storage[i].embeddings.removeAll { old.contains($0) }
                }
                storage[i].embeddings.append(embedding)
                storage[i].embeddings = Array(storage[i].embeddings.suffix(Self.maxEmbeddings))
                if isOwner { storage[i].isOwner = true }
            } else {
                i = storage.count
                storage.append(VoiceProfile(name: name, isOwner: isOwner, embeddings: [embedding],
                                            provisional: source?.origin == .inviteInference ? source?.callID ?? "" : nil))
            }
            try save()
            attached?.sync(storage[i], new: (embedding, source ?? VoiceSampleSource(origin: .migrated)), among: storage)
        }
    }

    /// What a new sample does to a provisional voice. The owner's name for a voice makes it firm, and when that voice
    /// is not the one the invite gave, the invite's sample goes. A sure match on another call makes it firm. A voice
    /// with no sample named from the invite becomes provisional. True when the profile changed here.
    private func settle(_ p: inout VoiceProfile, _ embedding: [Float], _ source: VoiceSampleSource?) -> Bool {
        guard let source else { return false }
        if p.embeddings.isEmpty {
            guard source.origin == .inviteInference, p.provisional == nil else { return false }
            p.provisional = source.callID ?? ""
            return true
        }
        guard let made = p.provisional else { return false }
        switch source.origin.kind {
        case VoiceSample.Origin.ownerNamed.kind:
            if let centroid = Self.centroid(p.embeddings), Self.cosine(embedding, centroid) < matchThreshold { p.embeddings = [] }
        case "autoMatch":
            guard source.callID != made else { return false }
        default:
            return false
        }
        p.provisional = nil
        return true
    }

    /// Takes back what was learned from one speaker of one call, when the owner says that speaker is someone
    /// else. `voice` is the fingerprint the call has for that speaker now: only a sample of that voice goes. Needs
    /// the samples' own record of where they came from; without it, or with no fingerprint, nothing changes.
    public func forget(callID: String, speakerKey: String, from name: String, voice: [Float]?) throws {
        try lock.withLock {
            guard let attached, let voice, let i = storage.firstIndex(where: { $0.name == name }) else { return }
            let gone = attached.vectors(of: storage[i], callID: callID, speakerKey: speakerKey, voice: voice)
            guard storage[i].embeddings.contains(where: { gone.contains($0) }) else { return }
            storage[i].embeddings.removeAll { gone.contains($0) }
            if storage[i].embeddings.isEmpty { storage[i].provisional = nil }
            try save()
            attached.sync(storage[i], among: storage)
        }
    }

    /// A blank email clears it. A name with no profile gets one without voice samples, so the email is kept
    /// even when voice fingerprints are off.
    public func setEmail(_ email: String?, for name: String, actor: String = "owner") throws {
        let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed?.isEmpty == false ? trimmed : nil
        try lock.withLock {
            let i: Int
            if let known = storage.firstIndex(where: { $0.name == name }) {
                i = known
                storage[i].email = value
            } else if let value {
                i = storage.count
                storage.append(VoiceProfile(name: name, isOwner: false, embeddings: [], email: value))
            } else {
                return
            }
            try save()
            attached?.emailChanged(storage[i], actor: actor)
        }
    }

    /// The profile name stored with this email, ignoring case.
    public func name(forEmail email: String) -> String? {
        let key = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return profiles.first { $0.email?.lowercased() == key }?.name
    }

    public func rename(_ from: String, to: String) throws {
        try lock.withLock {
            guard let i = storage.firstIndex(where: { $0.name == from }) else { return }
            if let j = storage.firstIndex(where: { $0.name == to }), j != i {
                let wasOwner = storage[i].isOwner
                storage[j].embeddings = Array((storage[j].embeddings + storage[i].embeddings).suffix(Self.maxEmbeddings))
                storage[j].isOwner = storage[j].isOwner || storage[i].isOwner
                storage[j].email = storage[j].email ?? storage[i].email
                let joined = storage[j]
                storage.remove(at: i)
                try save()
                attached?.merged(from, wasOwner: wasOwner, into: joined, among: storage)
            } else {
                storage[i].name = to
                try save()
                if from != to { attached?.renamed(from: from, to: storage[i], among: storage) }
            }
        }
    }

    /// Moves `name`'s voice samples into `target` (one person split into two profiles).
    public func merge(_ name: String, into target: String) throws {
        try rename(name, to: target)
    }

    public func deleteAll() throws {
        try lock.withLock {
            storage = []
            try save()
            attached?.deletedAll()
        }
    }

    public func delete(_ name: String) throws {
        try lock.withLock {
            let gone = storage.filter { $0.name == name }
            storage.removeAll { $0.name == name }
            try save()
            for profile in gone { attached?.deleted(profile, among: storage) }
        }
    }

    private func save() throws {
        // A file that is still there but could not be read must not be replaced by what this copy knows.
        if let loadError, (loadError as? UnreadableFile)?.kept == nil { throw loadError }
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
