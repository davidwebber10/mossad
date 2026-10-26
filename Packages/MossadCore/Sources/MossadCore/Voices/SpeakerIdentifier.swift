import Foundation

public struct SpeakerIdentification: Sendable, Equatable {
    /// Speaker key (`me:A`, `them:B`) → name, for recognised speakers.
    public var names: [String: String] = [:]
    /// Speaker keys with no match, in order of first appearance.
    public var unknown: [String] = []
    /// Voice fingerprints per speaker key (missing when the speaker had too little clear speech).
    public var embeddings: [String: [Float]] = [:]
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

    public func identify(utterances: [Utterance], meURL: URL, themURL: URL) async throws -> SpeakerIdentification {
        var result = SpeakerIdentification()
        var keys: [String] = []
        for u in utterances where !keys.contains(u.speakerKey) { keys.append(u.speakerKey) }

        for key in keys {
            let own = utterances.filter { $0.speakerKey == key }
            let url = own[0].track == .me ? meURL : themURL
            if let e = try await embedding(for: own, in: url) { result.embeddings[key] = e }
        }

        // Without an enrolled owner, the speaker who talks most on the mic is David. Only count time
        // when the other side is quiet, so echo of the other side on the mic cannot become the owner.
        if library.owner == nil {
            let meKeys = keys.filter { $0.hasPrefix("me:") }
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
            // The fingerprint uses all of the speaker's audio, so most of it must be clean too.
            if let dominant = meKeys.max(by: { clean($0) < clean($1) }), clean(dominant) >= Self.minimumOwnerSpeech,
               clean(dominant) >= total(dominant) / 2 {
                result.names[dominant] = ownerName
                if let e = result.embeddings[dominant] { try library.add(e, to: ownerName, isOwner: true) }
            }
        }

        for key in keys where result.names[key] == nil {
            guard let e = result.embeddings[key], let match = library.bestMatch(e) else {
                result.unknown.append(key)
                continue
            }
            result.names[key] = match.name
            if match.score >= Self.learnThreshold { try library.add(e, to: match.name) }
        }
        return result
    }

    /// Averages fingerprints over the speaker's longest clear segments (each ≥ 2 s, up to 60 s in total).
    func embedding(for utterances: [Utterance], in url: URL) async throws -> [Float]? {
        let segments = utterances.filter { $0.end - $0.start >= Self.minimumSegment }.sorted { ($0.end - $0.start) > ($1.end - $1.start) }
        var used: TimeInterval = 0
        var vectors: [[Float]] = []
        for s in segments where used < Self.maximumSpeechPerSpeaker {
            var start = s.start
            while start + Self.minimumSegment <= s.end, used < Self.maximumSpeechPerSpeaker {
                let end = min(s.end, start + Self.maximumPiece)
                let samples = try AudioSamples.read(url, from: start, to: end)
                if samples.count >= Int(Self.minimumSegment * TrackWriter.sampleRate) {
                    vectors.append(try await provider.embedding(for: samples))
                }
                used += end - start
                start = end
            }
        }
        return VoiceLibrary.centroid(vectors)
    }
}
