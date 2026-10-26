import Foundation

/// Puts names on the live transcript's call-audio speakers while the call records, from the voice library.
/// It only reads the library: the full identification after the call is what teaches it.
public struct LiveSpeakerNamer: Sendable {
    /// Clear speech a voice needs before a match is tried.
    static let minimumSpeech: TimeInterval = 4

    private let library: VoiceLibrary
    private let identifier: SpeakerIdentifier

    public init(library: VoiceLibrary, provider: EmbeddingProvider) {
        self.library = library
        identifier = SpeakerIdentifier(library: library, provider: provider)
    }

    /// Names for the speakers not named yet. A name already in use, and the owner's, are never given again.
    public func names(for transcript: LiveTranscript, themURL: URL) async -> [String: String] {
        var names = transcript.names
        var lines: [String: [Utterance]] = [:]
        for line in transcript.lines where line.source == .them && line.isFinal {
            guard let key = line.speakerKey, names[key] == nil, let start = line.audioStart, let end = line.audioEnd, end > start else { continue }
            lines[key, default: []].append(Utterance(track: .them, speakerLabel: key, start: start, end: end, text: line.text))
        }
        for (key, utterances) in lines.sorted(by: { $0.key < $1.key })
        where utterances.reduce(0, { $0 + $1.end - $1.start }) >= Self.minimumSpeech {
            guard let e = try? await identifier.embedding(for: utterances, in: themURL), let match = library.bestMatch(e),
                  match.name != library.owner?.name, !names.values.contains(match.name) else { continue }
            names[key] = match.name
        }
        return names
    }
}
