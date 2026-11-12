import Foundation

public struct VoiceProfile: Codable, Equatable, Sendable {
    public var name: String
    public var isOwner: Bool
    /// Newest last; at most `VoiceLibrary.maxEmbeddings`.
    public var embeddings: [[Float]]
    /// Picked by the owner from the call's attendees when naming the speaker, or the invite's address of a voice
    /// named from the invite: the first address, which older builds read.
    public var email: String? = nil
    /// The person's other addresses, after `email`.
    public var moreEmails: [String]? = nil
    /// The call whose invite named this voice, while that is all the proof there is. Nil once the owner named the
    /// voice or another call confirmed it. An older build reads the profile as firm.
    public var provisional: String? = nil
    /// When the call that made a provisional voice started: only a meeting on another day confirms it.
    public var provisionalStart: Date? = nil

    /// Every address, the first one first.
    public var emails: [String] { (email.map { [$0] } ?? []) + (moreEmails ?? []) }

    mutating func setEmails(_ list: [String]) {
        email = list.first
        moreEmails = list.count > 1 ? Array(list.dropFirst()) : nil
    }
}

/// What an added address did.
public enum EmailAddResult: Equatable, Sendable {
    case added, alreadyTheirs
    /// Another person has it: an address is one person's only, so the owner chooses to merge or not.
    case belongsTo(String)
    case notAnAddress
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
                let invited = source?.origin == .inviteInference
                storage.append(VoiceProfile(name: name, isOwner: isOwner, embeddings: [embedding],
                                            provisional: invited ? source?.callID ?? "" : nil,
                                            provisionalStart: invited ? source?.recorded : nil))
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
            p.provisionalStart = source.recorded
            return true
        }
        guard let made = p.provisional else { return false }
        switch source.origin.kind {
        case VoiceSample.Origin.ownerNamed.kind:
            if let centroid = Self.centroid(p.embeddings), Self.cosine(embedding, centroid) < matchThreshold { p.embeddings = [] }
        case "autoMatch":
            // Another record of the same meeting, or the join of its parts, is the same proof again.
            guard source.callID != made, let start = p.provisionalStart, let at = source.recorded,
                  !Calendar.current.isDate(at, inSameDayAs: start) else { return false }
        default:
            return false
        }
        p.provisional = nil
        p.provisionalStart = nil
        return true
    }

    /// A join of two profiles where one is provisional: the invite's samples that are not the other voice go, and
    /// the joined profile is as firm as the firm one.
    private static func joined(_ survivor: inout VoiceProfile, _ absorbed: VoiceProfile, threshold: Float) {
        let (guess, firm) = survivor.provisional != nil ? (survivor.embeddings, absorbed.embeddings) : (absorbed.embeddings, survivor.embeddings)
        guard survivor.provisional != nil || absorbed.provisional != nil else {
            survivor.embeddings = Array((survivor.embeddings + absorbed.embeddings).suffix(maxEmbeddings))
            return
        }
        if survivor.provisional != nil, absorbed.provisional != nil {
            survivor.embeddings = Array((survivor.embeddings + absorbed.embeddings).suffix(maxEmbeddings))
            return
        }
        let kept = centroid(firm).map { c in guess.filter { cosine($0, c) >= threshold } } ?? guess
        survivor.embeddings = Array((firm + kept).suffix(maxEmbeddings))
        survivor.provisional = nil
        survivor.provisionalStart = nil
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
            if storage[i].embeddings.isEmpty { storage[i].provisional = nil; storage[i].provisionalStart = nil }
            try save()
            attached.sync(storage[i], among: storage)
        }
    }

    /// The first address of a person, as the edit sheet sets it. A blank one clears the first address; the others
    /// stay. An address the person has already becomes the first, and none goes. An address another person has
    /// stays theirs: the answer says whose, and nothing changes. A name with no profile gets one without voice
    /// samples, so the address is kept even when voice fingerprints are off.
    @discardableResult
    public func setEmail(_ email: String?, for name: String, actor: String = "owner") throws -> EmailAddResult {
        let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed?.isEmpty == false ? trimmed : nil
        if let value, CompanyDomains.split(value) == nil { return .notAnAddress }
        return try lock.withLock {
            let i: Int
            if let known = storage.firstIndex(where: { $0.name == name }) {
                i = known
                let mine = storage[i].emails
                if let value {
                    if let at = mine.firstIndex(where: { $0.lowercased() == value.lowercased() }) {
                        guard at > 0 else { return .alreadyTheirs }
                        storage[i].setEmails([mine[at]] + mine.enumerated().filter { $0.offset != at }.map(\.element))
                        try save()
                        attached?.emailChanged(storage[i], actor: actor)
                        return .alreadyTheirs
                    }
                    if let other = holder(of: value, except: name, profile: storage[i]) { return .belongsTo(other) }
                    storage[i].setEmails([value] + mine.dropFirst())
                } else {
                    guard !mine.isEmpty else { return .alreadyTheirs }
                    storage[i].setEmails(Array(mine.dropFirst()))
                }
            } else if let value {
                if let other = holder(of: value, except: name, profile: nil) { return .belongsTo(other) }
                i = storage.count
                storage.append(VoiceProfile(name: name, isOwner: false, embeddings: [], email: value))
            } else {
                return .alreadyTheirs
            }
            try save()
            attached?.emailChanged(storage[i], actor: actor)
            return .added
        }
    }

    /// The person other than `name` who has an address: another profile, else another saved person.
    public func holder(of address: String, except name: String) -> String? {
        lock.withLock { holder(of: address, except: name, profile: storage.first { $0.name == name }) }
    }

    /// Who else has an address: another profile, else another saved person. Call it inside the lock.
    private func holder(of address: String, except name: String, profile: VoiceProfile?) -> String? {
        let a = EmailIdentity.normalized(address)
        if let other = storage.first(where: { $0.name != name && $0.emails.contains { $0.lowercased() == a } }) { return other.name }
        if let other = attached?.holder(of: a, for: profile), other != name { return other }
        return nil
    }

    /// The profile name stored with this email, any of a profile's addresses, ignoring case.
    public func name(forEmail email: String) -> String? {
        let key = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return profiles.first { $0.emails.contains { $0.lowercased() == key } }?.name
    }

    /// One more address for a person. An address is one person's only: one that another profile or another saved
    /// person has is left where it is, and the answer says whose it is.
    public func addEmail(_ email: String, for name: String, actor: String = "owner") throws -> EmailAddResult {
        let address = EmailIdentity.normalized(email)
        guard CompanyDomains.split(address) != nil else { return .notAnAddress }
        return try lock.withLock {
            let i = storage.firstIndex { $0.name == name }
            if let i, storage[i].emails.contains(where: { $0.lowercased() == address }) { return .alreadyTheirs }
            if let other = holder(of: address, except: name, profile: i.map { storage[$0] }) { return .belongsTo(other) }
            let j: Int
            if let i {
                j = i
                storage[j].setEmails(storage[j].emails + [address])
            } else {
                j = storage.count
                storage.append(VoiceProfile(name: name, isOwner: false, embeddings: [], email: address))
            }
            try save()
            attached?.emailChanged(storage[j], actor: actor)
            return .added
        }
    }

    public func removeEmail(_ email: String, for name: String) throws {
        let address = EmailIdentity.normalized(email)
        try lock.withLock {
            guard let i = storage.firstIndex(where: { $0.name == name }), storage[i].emails.contains(where: { $0.lowercased() == address }) else { return }
            storage[i].setEmails(storage[i].emails.filter { $0.lowercased() != address })
            try save()
            attached?.emailChanged(storage[i])
        }
    }

    public func rename(_ from: String, to: String) throws {
        try lock.withLock {
            guard let i = storage.firstIndex(where: { $0.name == from }) else { return }
            if let j = storage.firstIndex(where: { $0.name == to }), j != i {
                let wasOwner = storage[i].isOwner
                Self.joined(&storage[j], storage[i], threshold: matchThreshold)
                storage[j].isOwner = storage[j].isOwner || storage[i].isOwner
                let kept = storage[j].emails.map { $0.lowercased() }
                storage[j].setEmails(storage[j].emails + storage[i].emails.filter { !kept.contains($0.lowercased()) })
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

    /// Fills the people from Google's directory and contacts. Returns how many people changed.
    @discardableResult
    public func applyDirectory(_ directory: [GoogleProfile]) throws -> Int {
        guard let people = identity?.people else { return 0 }
        let before = Dictionary(people.people.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let changed = try people.applyDirectory(directory)
        // A person with a voice whose name the directory gave: the voice takes the name too, so one person keeps one
        // name and the next save of the voice finds them.
        for p in people.people where p.isLive && !p.isOwner {
            guard let old = before[p.id], old != p.displayName, profiles.contains(where: { $0.name == old }) else { continue }
            guard !profiles.contains(where: { $0.name == p.displayName }) else {
                Log.info("Google People: a directory name is already another voice's; the voice keeps its name")
                continue
            }
            try rename(old, to: p.displayName)
        }
        return changed
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
