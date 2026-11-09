import Foundation
import Synchronization

/// When a voice with no name is worth another fingerprint. A fingerprint reads up to 60 s of audio and runs the
/// voice model on each 10 s of it; a voice the library does not know never gets a name, so without this the same
/// work was done again every 20 s until the call ended.
public struct LiveNamingTries: Sendable, Equatable {
    /// A new try needs this much more speech than the last one had.
    static let growth = 1.5
    private var speechAtLastTry: [String: TimeInterval] = [:]

    public init() {}

    public func isDue(_ key: String, speech: TimeInterval) -> Bool {
        guard let last = speechAtLastTry[key] else { return true }
        // A fingerprint uses at most this much speech: more of it changes nothing.
        guard last < SpeakerIdentifier.maximumSpeechPerSpeaker else { return false }
        return speech >= min(last * Self.growth, SpeakerIdentifier.maximumSpeechPerSpeaker)
    }

    public mutating func tried(_ key: String, speech: TimeInterval) { speechAtLastTry[key] = speech }
}

/// Puts names on the live transcript's call-audio speakers while the call records, from the voice library.
/// It only reads the library: the full identification after the call is what teaches it.
public struct LiveSpeakerNamer: Sendable {
    /// Clear speech a voice needs before a match is tried.
    static let minimumSpeech: TimeInterval = 4

    private let library: VoiceLibrary
    private let identifier: SpeakerIdentifier
    /// In a room, one stream hears everyone, the owner too.
    private let room: Bool
    /// One namer lives for one call and remembers what it tried.
    private let tries = Tries()

    private final class Tries: Sendable {
        private let state = Mutex(LiveNamingTries())
        func withLock<T>(_ body: (inout LiveNamingTries) -> T) -> T { state.withLock { body(&$0) } }
    }

    public init(library: VoiceLibrary, provider: EmbeddingProvider, room: Bool = false) {
        self.library = library
        self.room = room
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
        for (key, utterances) in lines.sorted(by: { $0.key < $1.key }) {
            let speech = utterances.reduce(0) { $0 + $1.end - $1.start }
            guard speech >= Self.minimumSpeech, tries.withLock({ $0.isDue(key, speech: speech) }) else { continue }
            tries.withLock { $0.tried(key, speech: speech) }
            guard let e = try? await identifier.embedding(for: utterances, in: themURL), let match = library.bestMatch(e),
                  room || match.name != library.owner?.name, !names.values.contains(match.name) else { continue }
            names[key] = match.name
        }
        return names
    }
}
