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
/// It only reads the library: the full identification after the call is what teaches it. Each voice is
/// fingerprinted again as its speech grows (`LiveNamingTries`), and `LiveVoiceRules` decides all the names again
/// each time, so a name can change or go, and the earlier lines of that voice follow it.
public struct LiveSpeakerNamer: Sendable {
    private let library: VoiceLibrary
    private let identifier: SpeakerIdentifier
    /// In a room, one stream hears everyone, the owner too.
    private let room: Bool
    /// One namer lives for one call and remembers what it tried and what it heard.
    private let memory = Memory()

    struct Heard: Sendable {
        var vector: [Float]
        var seconds: TimeInterval
        var mixed: Bool
    }

    private final class Memory: Sendable {
        struct State {
            var tries = LiveNamingTries()
            var heard: [String: Heard] = [:]
        }
        private let state = Mutex(State())
        func withLock<T>(_ body: (inout State) -> T) -> T { state.withLock { body(&$0) } }
    }

    public init(library: VoiceLibrary, provider: EmbeddingProvider, room: Bool = false) {
        self.library = library
        self.room = room
        identifier = SpeakerIdentifier(library: library, provider: provider)
    }

    /// The names of the call-audio speakers, all of them: a name can be new, changed, or gone. `invite` is the
    /// call's invite as `CallInvite.live` matches it, nil when it has none.
    public func names(for transcript: LiveTranscript, themURL: URL, invite: CallInvite? = nil) async -> [String: String] {
        var lines: [String: [Utterance]] = [:]
        for line in transcript.lines where line.source == .them && line.isFinal {
            guard let key = line.speakerKey, let start = line.audioStart, let end = line.audioEnd, end > start else { continue }
            lines[key, default: []].append(Utterance(track: .them, speakerLabel: key, start: start, end: end, text: line.text))
        }
        for (key, utterances) in lines.sorted(by: { $0.key < $1.key }) {
            let speech = utterances.reduce(0) { $0 + $1.end - $1.start }
            guard speech >= LiveVoiceRules.minimumSpeech, memory.withLock({ $0.tries.isDue(key, speech: speech) }) else { continue }
            memory.withLock { $0.tries.tried(key, speech: speech) }
            guard let pieces = try? await identifier.pieceVectors(for: utterances, in: themURL),
                  let f = SpeakerIdentifier.fingerprint(of: pieces) else { continue }
            // Two voices under one key stay two voices for the rest of the call: no later try makes it one.
            memory.withLock { m in
                let mixed = m.heard[key]?.mixed == true || LiveVoiceRules.mixed(pieces) == true
                m.heard[key] = Heard(vector: f.vector, seconds: f.seconds, mixed: mixed)
            }
        }
        let heard = memory.withLock { $0.heard }
        let voices = heard.map { LiveVoiceRules.Voice(key: $0.key, scores: library.ranked($0.value.vector), seconds: $0.value.seconds, mixed: $0.value.mixed) }
        let roster = invite.map { InviteRoster(invite: $0, profiles: library.profiles, people: library.identity?.people.people ?? []) }
        return LiveVoiceRules.names(voices, current: transcript.names, roster: roster, owner: library.owner?.name,
                                    provisional: library.provisional, room: room, matchThreshold: library.matchThreshold)
    }
}
