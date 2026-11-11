import CryptoKit
import Foundation

/// What is known of a voice fingerprint when it is learned: the call, the speaker, and how good it is.
public struct VoiceSampleSource: Equatable, Sendable {
    public var callID: String?
    public var speakerKey: String?
    /// The call's start.
    public var recorded: Date?
    /// Clear speech used.
    public var seconds: Double?
    /// 0 to 1.
    public var quality: Double?
    public var origin: VoiceSample.Origin

    public init(callID: String? = nil, speakerKey: String? = nil, recorded: Date? = nil, seconds: Double? = nil, quality: Double? = nil,
                origin: VoiceSample.Origin) {
        self.callID = callID
        self.speakerKey = speakerKey
        self.recorded = recorded
        self.seconds = seconds
        self.quality = quality
        self.origin = origin
    }
}

/// How much speech a fingerprint was made from, kept in the call record so a speaker named later is learned
/// with it.
public struct SpeakerSampleDetail: Codable, Equatable, Sendable {
    public var seconds: Double
    public var quality: Double?

    public init(seconds: Double, quality: Double?) {
        self.seconds = seconds
        self.quality = quality
    }
}

/// One voice fingerprint of one person, with where it came from. In `~/Mossad/Voices/samples.json`, on this Mac
/// only.
public struct VoiceSample: Codable, Equatable, Sendable, Identifiable {
    /// Why Mossad has the sample.
    public struct Origin: Codable, Equatable, Sendable {
        /// "ownerNamed", "autoMatch", "ownerEnrollment", or "migrated".
        public var kind: String
        /// The match score of an automatic match.
        public var score: Float?

        public init(kind: String, score: Float? = nil) {
            self.kind = kind
            self.score = score
        }

        /// The owner named the speaker.
        public static let ownerNamed = Origin(kind: "ownerNamed")
        /// The voice that talked most on the mic became the owner.
        public static let ownerEnrollment = Origin(kind: "ownerEnrollment")
        /// From the voice library of before, with no more known.
        public static let migrated = Origin(kind: "migrated")
        /// A sure automatic match taught the profile.
        public static func autoMatch(_ score: Float) -> Origin { Origin(kind: "autoMatch", score: score) }
    }

    public var id: UUID
    /// Nil for a voice with no name yet.
    public var personID: PersonID?
    public var vector: [Float]
    /// The model and the size of the fingerprint. Fingerprints of two models do not compare.
    public var model: String
    public var callID: String?
    /// Such as "them:B".
    public var speakerKey: String?
    /// "me" for the mic, "them" for the call audio.
    public var track: String?
    public var recorded: Date?
    public var learned: Date
    public var seconds: Double?
    public var quality: Double?
    public var origin: Origin

    public init(id: UUID = UUID(), personID: PersonID?, vector: [Float], source: VoiceSampleSource, learned: Date) {
        self.id = id
        self.personID = personID
        self.vector = vector
        model = Self.model(of: vector)
        callID = source.callID
        speakerKey = source.speakerKey
        track = source.speakerKey.flatMap { $0.split(separator: ":").first.map(String.init) }
        recorded = source.recorded
        self.learned = learned
        seconds = source.seconds
        quality = source.quality
        origin = source.origin
    }

    /// Mossad has one fingerprint model; the size tells a later one apart.
    public static func model(of vector: [Float]) -> String { "fluidaudio:\(vector.count)" }

    /// Takes the call, the speaker, and the numbers of `source`. The id and the person stay.
    mutating func take(_ source: VoiceSampleSource) {
        callID = source.callID
        speakerKey = source.speakerKey
        track = source.speakerKey.flatMap { $0.split(separator: ":").first.map(String.init) }
        recorded = source.recorded
        seconds = source.seconds
        quality = source.quality
        origin = source.origin
    }

    enum CodingKeys: String, CodingKey { case id, personID, vector, model, callID, speakerKey, track, recorded, learned, seconds, quality, origin }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        personID = try c.decodeIfPresent(PersonID.self, forKey: .personID)
        vector = Self.floats(base64: try c.decode(String.self, forKey: .vector))
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? Self.model(of: vector)
        callID = try c.decodeIfPresent(String.self, forKey: .callID)
        speakerKey = try c.decodeIfPresent(String.self, forKey: .speakerKey)
        track = try c.decodeIfPresent(String.self, forKey: .track)
        recorded = try c.decodeIfPresent(Date.self, forKey: .recorded)
        learned = try c.decodeIfPresent(Date.self, forKey: .learned) ?? .distantPast
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds)
        quality = try c.decodeIfPresent(Double.self, forKey: .quality)
        origin = try c.decodeIfPresent(Origin.self, forKey: .origin) ?? .migrated
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(personID, forKey: .personID)
        // The numbers as bytes: less than half the size of decimal text, and exact.
        try c.encode(Self.base64(vector), forKey: .vector)
        try c.encode(model, forKey: .model)
        try c.encodeIfPresent(callID, forKey: .callID)
        try c.encodeIfPresent(speakerKey, forKey: .speakerKey)
        try c.encodeIfPresent(track, forKey: .track)
        try c.encodeIfPresent(recorded, forKey: .recorded)
        try c.encode(learned, forKey: .learned)
        try c.encodeIfPresent(seconds, forKey: .seconds)
        try c.encodeIfPresent(quality, forKey: .quality)
        try c.encode(origin, forKey: .origin)
    }

    /// The numbers as little-endian 32-bit floats.
    static func bytes(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for v in vector { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    static func base64(_ vector: [Float]) -> String { bytes(vector).base64EncodedString() }

    static func floats(base64: String) -> [Float] {
        guard let data = Data(base64Encoded: base64) else { return [] }
        return stride(from: 0, to: data.count - data.count % 4, by: 4).map { i in
            Float(bitPattern: UInt32(littleEndian: data.subdata(in: i..<(i + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        }
    }

    /// A short name for one fingerprint, the same for the same numbers. For lists that must not hold the numbers.
    public static func key(of vector: [Float]) -> String {
        SHA256.hash(data: bytes(vector)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// 0 to 1, from numbers the fingerprint step has: more clear speech is better (30 s is enough), pieces that
    /// agree with one another are better, and echo of the other side on the mic lowers it.
    public static func quality(seconds: Double, coherence: Double?, echoShare: Double = 0) -> Double {
        let length = min(1, max(0, seconds) / 30)
        // One piece cannot agree or disagree with itself.
        let together = coherence.map { max(0, min(1, ($0 - 0.5) * 2)) } ?? 0.5
        return (0.5 * length + 0.5 * together) * (1 - max(0, min(1, echoShare)))
    }
}

/// The rules for the samples of one person.
public enum VoiceSamples {
    /// Two fingerprints of one call this close are one sample.
    public static let sameSample: Float = 0.98

    /// The samples that a new one of the same person replaces: one sample for a person, a call, and a speaker
    /// key. "Transcribe again" can give the speaker another key, so a sample of that call that is nearly the
    /// same counts too. A sample with no call is never replaced.
    public static func replaced(by vector: [Float], callID: String?, speakerKey: String?, among samples: [VoiceSample]) -> [VoiceSample] {
        guard let callID else { return [] }
        return samples.filter { s in
            s.callID == callID && s.vector != vector && ((speakerKey != nil && s.speakerKey == speakerKey) || VoiceLibrary.cosine(s.vector, vector) >= sameSample)
        }
    }
}

/// `samples.json`: each voice fingerprint with its person id and where it came from.
public final class VoiceSampleStore: @unchecked Sendable {
    public static let fileName = "samples.json"
    public static let currentVersion = 1

    private struct File: Codable {
        var version: Int
        var samples: [VoiceSample]

        init(version: Int, samples: [VoiceSample]) {
            self.version = version
            self.samples = samples
        }

        enum CodingKeys: String, CodingKey { case version, samples }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            samples = try c.decodeIfPresent([VoiceSample].self, forKey: .samples) ?? []
        }
    }

    private let url: URL
    private let lock = NSLock()
    private var storage: [VoiceSample]
    /// Set when `samples.json` was there and could not be read; a damaged file is moved aside first.
    public let loadError: Error?
    /// True for a file from a newer build: it is read, and never saved.
    public let isReadOnly: Bool
    private let newerVersion: Int?

    private struct VersionOnly: Decodable { var version: Int? }

    /// The file was written by a newer build. This build reads it and does not save.
    public struct NewerFile: Error, CustomStringConvertible {
        public let version: Int
        public var description: String { "samples.json is from a newer Mossad (version \(version)); this build does not change it" }
    }

    static func version(of data: Data) -> Int? { (try? JSONDecoder().decode(VersionOnly.self, from: data))?.version }

    public init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
        // Newer is not unreadable: a file with a higher version is never moved aside and never replaced.
        if let data = try? Data(contentsOf: url), let v = Self.version(of: data), v > Self.currentVersion {
            isReadOnly = true
            newerVersion = v
            do {
                storage = try JSONDecoder.callRecord.decode(File.self, from: data).samples
                loadError = nil
            } catch {
                storage = []
                loadError = error
            }
            return
        }
        isReadOnly = false
        newerVersion = nil
        do {
            // No note for the owner: the samples are made again from the voice library at the next launch.
            storage = try StoredFile.load(File.self, from: url, decoder: .callRecord)?.samples ?? []
            loadError = nil
        } catch {
            storage = []
            loadError = error
        }
    }

    static func decode(_ data: Data) -> [VoiceSample]? { (try? JSONDecoder.callRecord.decode(File.self, from: data))?.samples }

    public var samples: [VoiceSample] { lock.withLock { storage } }
    public func samples(of person: PersonID) -> [VoiceSample] { samples.filter { $0.personID == person } }

    /// Changes the samples and saves. Nothing is written when nothing changed.
    public func change(_ body: (inout [VoiceSample]) -> Void) throws {
        try lock.withLock {
            var copy = storage
            body(&copy)
            guard copy != storage else { return }
            if let newerVersion { throw NewerFile(version: newerVersion) }
            if let loadError, (loadError as? UnreadableFile)?.kept == nil { throw loadError }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.callRecord.encode(File(version: Self.currentVersion, samples: copy)).write(to: url, options: .atomic)
            storage = copy
        }
    }

    public func replaceAll(_ samples: [VoiceSample]) throws {
        if let newerVersion { throw NewerFile(version: newerVersion) }
        try change { $0 = samples }
    }
}

/// The people and the samples that follow the voice library. The voice library calls it after each of its own
/// saves. A failure here is logged and never fails the voice library: the check at launch brings the two
/// stores in step again.
public final class VoiceIdentity: @unchecked Sendable {
    public let people: PeopleStore
    public let samples: VoiceSampleStore
    private let now: @Sendable () -> Date

    public init(people: PeopleStore, samples: VoiceSampleStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.people = people
        self.samples = samples
        self.now = now
    }

    private func attempt(_ what: String, _ body: () throws -> Void) {
        do { try body() } catch { Log.error("People: \(what) did not reach the people store: \(error)") }
    }

    /// The vectors of this profile that a new sample replaces.
    func replaced(by vector: [Float], in profile: VoiceProfile, source: VoiceSampleSource) -> [[Float]] {
        guard let id = people.id(forVoiceName: profile.name, isOwner: profile.isOwner) else { return [] }
        return VoiceSamples.replaced(by: vector, callID: source.callID, speakerKey: source.speakerKey, among: samples.samples(of: id)).map(\.vector)
    }

    /// The vectors of this profile that one speaker of one call taught, and that are the voice `voice`: the
    /// fingerprint the call has for that speaker now. "Transcribe again" can give the key to another voice, so the
    /// key alone is not proof.
    func vectors(of profile: VoiceProfile, callID: String, speakerKey: String, voice: [Float]) -> [[Float]] {
        guard let id = people.id(forVoiceName: profile.name, isOwner: profile.isOwner) else { return [] }
        return samples.samples(of: id).filter {
            $0.callID == callID && $0.speakerKey == speakerKey && VoiceLibrary.cosine($0.vector, voice) >= VoiceSamples.sameSample
        }.map(\.vector)
    }

    /// Makes the samples of the profile's person the fingerprints of the person's profiles: one sample for each
    /// distinct fingerprint, a fingerprint that left leaves, and one with no sample gets one. `new` is the sample
    /// that was learned just now. `profiles` is the whole library: two profiles can be one person (the owner's
    /// profile under an old name, and a voice named with the new one), and a change of one keeps the other's.
    func sync(_ profile: VoiceProfile, new: (vector: [Float], source: VoiceSampleSource)? = nil, among profiles: [VoiceProfile]) {
        attempt("a voice of \(profile.name)") {
            let id = try people.ensure(voiceName: profile.name, isOwner: profile.isOwner, origin: .voiceNaming)
            let date = now()
            var vectors: [[Float]] = []
            for p in profiles where p.name == profile.name || people.id(forVoiceName: p.name, isOwner: p.isOwner) == id {
                // The voice file can hold one fingerprint two times. It is one sample.
                for v in p.embeddings where !vectors.contains(v) { vectors.append(v) }
            }
            try samples.change { all in
                var mine = all.filter { $0.personID == id }
                all.removeAll { $0.personID == id }
                if let new, let i = mine.firstIndex(where: { $0.vector == new.vector }) {
                    // The same sample learned again: what is known now of its call fills what was not known, and
                    // the owner's word for the name stays when a match comes later.
                    if mine[i].callID == nil, new.source.callID != nil {
                        mine[i].take(new.source)
                    } else if new.source.origin == .ownerNamed, mine[i].origin != .ownerNamed, mine[i].callID == new.source.callID {
                        mine[i].origin = .ownerNamed
                    }
                }
                all += vectors.map { vector in
                    if let known = mine.first(where: { $0.vector == vector }) { return known }
                    if let new, new.vector == vector { return VoiceSample(personID: id, vector: vector, source: new.source, learned: date) }
                    return VoiceSample(personID: id, vector: vector, source: VoiceSampleSource(origin: .migrated), learned: date)
                }
            }
        }
    }

    func emailChanged(_ profile: VoiceProfile) {
        attempt("the email of \(profile.name)") {
            let id = try people.ensure(voiceName: profile.name, isOwner: profile.isOwner, origin: .voiceNaming)
            try people.setEmail(profile.email, for: id)
        }
    }

    func renamed(from old: String, to profile: VoiceProfile, among profiles: [VoiceProfile]) {
        attempt("the new name of \(old)") {
            if let id = people.id(forVoiceName: old, isOwner: profile.isOwner) { try people.rename(id, to: profile.name) }
        }
        sync(profile, among: profiles)
    }

    /// `old` was joined into `profile`. The person of `old` becomes a redirect, and its samples go to the other.
    func merged(_ old: String, wasOwner: Bool, into profile: VoiceProfile, among profiles: [VoiceProfile]) {
        attempt("the merge of \(old)") {
            let survivor = try people.ensure(voiceName: profile.name, isOwner: profile.isOwner && !wasOwner, origin: .voiceNaming)
            guard let absorbed = people.id(forVoiceName: old, isOwner: wasOwner), absorbed != survivor else { return }
            try people.merge(absorbed, into: survivor)
            try samples.change { all in
                for i in all.indices where all[i].personID == absorbed { all[i].personID = survivor }
            }
        }
        sync(profile, among: profiles)
    }

    func deleted(_ profile: VoiceProfile, among profiles: [VoiceProfile]) {
        attempt("the delete of \(profile.name)") {
            guard let id = people.id(forVoiceName: profile.name, isOwner: profile.isOwner) else { return }
            // The owner is a person with or with no voice: their names stay, and so do the samples of another
            // profile of theirs.
            if people.person(id)?.isOwner == true {
                let left = profiles.filter { people.id(forVoiceName: $0.name, isOwner: $0.isOwner) == id }.flatMap(\.embeddings)
                try samples.change { $0.removeAll { $0.personID == id && !left.contains($0.vector) } }
                return
            }
            try samples.change { $0.removeAll { $0.personID == id } }
            try people.delete(id)
        }
    }

    /// "Delete all voices" forgets each voice. The people stay.
    func deletedAll() {
        attempt("the delete of all voices") { try samples.replaceAll([]) }
    }
}
