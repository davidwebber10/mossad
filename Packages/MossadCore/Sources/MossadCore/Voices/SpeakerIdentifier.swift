import Foundation

public struct SpeakerIdentification: Sendable, Equatable {
    /// Speaker key (`me:A`, `them:B`) → name, for recognised speakers.
    public var names: [String: String] = [:]
    /// Speaker keys with no match, in order of first appearance.
    public var unknown: [String] = []
    /// Voice fingerprints per speaker key (missing when the speaker had too little clear speech).
    public var embeddings: [String: [Float]] = [:]
    /// How much clear speech each fingerprint was made from, and how good it is.
    public var details: [String: SpeakerSampleDetail] = [:]
}

/// Puts names on diarized speakers using the voice library.
public struct SpeakerIdentifier: Sendable {
    static let minimumSegment: TimeInterval = 2
    static let maximumSpeechPerSpeaker: TimeInterval = 60
    static let maximumPiece: TimeInterval = 10
    /// Only confident automatic matches teach the library, so one wrong match cannot drift a profile.
    static let learnThreshold: Float = 0.8
    /// Echo can trail the other side's speech by a moment; mic speech this close to theirs does not count.
    static let echoMargin: TimeInterval = 0.5
    /// Clean mic speech needed before a voice is enrolled as the owner.
    static let minimumOwnerSpeech: TimeInterval = 5

    private let library: VoiceLibrary
    private let provider: EmbeddingProvider
    private let ownerName: String

    public init(library: VoiceLibrary, provider: EmbeddingProvider, ownerName: String = "Me") {
        self.library = library
        self.provider = provider
        self.ownerName = ownerName
    }

    /// `call` is the call's id and start, kept with each voice sample that the call teaches.
    public func identify(utterances: [Utterance], meURL: URL, themURL: URL, call: (id: String, start: Date)? = nil) async throws -> SpeakerIdentification {
        var result = SpeakerIdentification()
        var keys: [String] = []
        for u in utterances where !keys.contains(u.speakerKey) { keys.append(u.speakerKey) }

        // Only count mic time when the other side is quiet, so echo of the other side on the mic is known.
        let them = utterances.filter { $0.track == .them }
        let clean = { (key: String) in
            utterances.filter { $0.speakerKey == key }.reduce(0.0) { sum, u in
                let overlap = them.reduce(0.0) {
                    $0 + max(0, min(u.end, $1.end + Self.echoMargin) - max(u.start, $1.start - Self.echoMargin))
                }
                return sum + max(0, u.end - u.start - overlap)
            }
        }
        let total = { (key: String) in utterances.filter { $0.speakerKey == key }.reduce(0.0) { $0 + $1.end - $1.start } }

        for key in keys {
            let own = utterances.filter { $0.speakerKey == key }
            let url = own[0].track == .me ? meURL : themURL
            guard let f = try await fingerprint(for: own, in: url) else { continue }
            result.embeddings[key] = f.vector
            let echo = key.hasPrefix("me:") && total(key) > 0 ? 1 - clean(key) / total(key) : 0
            result.details[key] = SpeakerSampleDetail(seconds: f.seconds, quality: VoiceSample.quality(seconds: f.seconds, coherence: f.coherence, echoShare: echo))
        }
        func source(_ key: String, _ origin: VoiceSample.Origin) -> VoiceSampleSource? {
            guard let call else { return nil }
            return VoiceSampleSource(callID: call.id, speakerKey: key, recorded: call.start, seconds: result.details[key]?.seconds,
                                     quality: result.details[key]?.quality, origin: origin)
        }

        // Without an enrolled owner, the speaker who talks most on the mic is David.
        if library.owner == nil {
            let meKeys = keys.filter { $0.hasPrefix("me:") }
            // The fingerprint uses all of the speaker's audio, so most of it must be clean too.
            if let dominant = meKeys.max(by: { clean($0) < clean($1) }), clean(dominant) >= Self.minimumOwnerSpeech,
               clean(dominant) >= total(dominant) / 2 {
                result.names[dominant] = ownerName
                if let e = result.embeddings[dominant] { try library.add(e, to: ownerName, isOwner: true, source: source(dominant, .ownerEnrollment)) }
            }
        }

        for key in keys where result.names[key] == nil {
            guard let e = result.embeddings[key], let match = library.bestMatch(e) else {
                result.unknown.append(key)
                continue
            }
            result.names[key] = match.name
            if match.score >= Self.learnThreshold { try library.add(e, to: match.name, source: source(key, .autoMatch(match.score))) }
        }
        return result
    }

    /// A fingerprint with what it was made from.
    struct Fingerprint {
        var vector: [Float]
        /// The clear speech used.
        var seconds: TimeInterval
        /// How near the pieces are to their average, as a mean cosine; nil for one piece.
        var coherence: Double?
    }

    /// The pieces of a speaker's speech that a fingerprint is made from: the longest clear segments (each ≥ 2 s),
    /// in pieces of up to 10 s, up to 60 s in total.
    static func pieces(_ utterances: [Utterance]) -> [(start: TimeInterval, end: TimeInterval)] {
        let segments = utterances.filter { $0.end - $0.start >= minimumSegment }.sorted { ($0.end - $0.start) > ($1.end - $1.start) }
        var used: TimeInterval = 0
        var out: [(start: TimeInterval, end: TimeInterval)] = []
        for s in segments where used < maximumSpeechPerSpeaker {
            var start = s.start
            while start + minimumSegment <= s.end, used < maximumSpeechPerSpeaker {
                let end = min(s.end, start + maximumPiece)
                out.append((start, end))
                used += end - start
                start = end
            }
        }
        return out
    }

    /// The seconds of speech a fingerprint of these lines is made from, for a sample from before this was kept.
    static func speechUsed(_ utterances: [Utterance]) -> TimeInterval {
        pieces(utterances).reduce(0) { $0 + $1.end - $1.start }
    }

    /// Averages fingerprints over the speaker's longest clear segments (each ≥ 2 s, up to 60 s in total).
    func embedding(for utterances: [Utterance], in url: URL) async throws -> [Float]? {
        try await fingerprint(for: utterances, in: url)?.vector
    }

    func fingerprint(for utterances: [Utterance], in url: URL) async throws -> Fingerprint? {
        var vectors: [[Float]] = []
        var seconds: TimeInterval = 0
        for piece in Self.pieces(utterances) {
            let samples = try AudioSamples.read(url, from: piece.start, to: piece.end)
            if samples.count >= Int(Self.minimumSegment * TrackWriter.sampleRate) {
                vectors.append(try await provider.embedding(for: samples))
                seconds += piece.end - piece.start
            }
        }
        guard let centroid = VoiceLibrary.centroid(vectors) else { return nil }
        let coherence = vectors.count > 1 ? Double(vectors.reduce(Float(0)) { $0 + VoiceLibrary.cosine($1, centroid) }) / Double(vectors.count) : nil
        return Fingerprint(vector: centroid, seconds: seconds, coherence: coherence)
    }
}
