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

    private let library: VoiceLibrary
    private let provider: EmbeddingProvider
    private let ownerName: String

    public init(library: VoiceLibrary, provider: EmbeddingProvider, ownerName: String = "David Webber") {
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

        // Without an enrolled owner, the speaker who talks most on the mic is David.
        if library.owner == nil {
            let meKeys = keys.filter { $0.hasPrefix("me:") }
            let talk = { (key: String) in utterances.filter { $0.speakerKey == key }.reduce(0) { $0 + $1.end - $1.start } }
            if let dominant = meKeys.max(by: { talk($0) < talk($1) }) {
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
            try library.add(e, to: match.name)
        }
        return result
    }

    /// Averages fingerprints over the speaker's longest clear segments (each ≥ 2 s, up to 60 s in total).
    private func embedding(for utterances: [Utterance], in url: URL) async throws -> [Float]? {
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
