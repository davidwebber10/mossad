import Foundation
import Synchronization

/// When a voice is worth another fingerprint. A fingerprint reads up to 60 s of audio and runs the voice model on
/// each 10 s of it, so a voice is fingerprinted again only when it said half as much again, up to that minute.
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
    /// A fingerprint that failed this many times in a row waits for more speech.
    static let failuresBeforeWait = 3

    private let library: VoiceLibrary
    private let identifier: SpeakerIdentifier
    /// In a room, one stream hears everyone, the owner too.
    private let room: Bool
    /// One namer lives for one call, across its pauses, and remembers what it tried and what it heard.
    private let memory = Memory()

    struct Heard: Sendable {
        var vector: [Float]
        var seconds: TimeInterval
        var mixed: Bool
        /// Two voices for the rest of the call: no more fingerprints of this key.
        var settledMixed: Bool
    }

    private final class Memory: Sendable {
        struct State {
            var tries = LiveNamingTries()
            var heard: [String: Heard] = [:]
            var failures: [String: Int] = [:]
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
            // The speech a fingerprint would use, so a try is made only when it can give a name.
            let speech = SpeakerIdentifier.speechUsed(utterances)
            guard speech >= LiveVoiceRules.minimumSpeech,
                  memory.withLock({ $0.heard[key]?.settledMixed != true && $0.tries.isDue(key, speech: speech) }) else { continue }
            guard let pieces = try? await identifier.pieceVectors(for: utterances, in: themURL),
                  let f = SpeakerIdentifier.fingerprint(of: pieces) else {
                // A read that failed is tried again on the next tick, a few times, before it waits for more speech.
                memory.withLock { m in
                    m.failures[key, default: 0] += 1
                    if m.failures[key, default: 0] >= Self.failuresBeforeWait { m.tries.tried(key, speech: speech); m.failures[key] = nil }
                }
                continue
            }
            let halves = LiveVoiceRules.halves(pieces)
            if let halves { Log.info(String(format: "Live names: the two halves of a voice agree at %.2f over %.0f s", halves.cosine, f.seconds)) }
            memory.withLock { m in
                m.tries.tried(key, speech: speech)
                m.failures[key] = nil
                let mixed = halves?.mixed == true
                m.heard[key] = Heard(vector: f.vector, seconds: f.seconds, mixed: mixed, settledMixed: mixed && halves?.settled == true)
            }
        }
        let (heard, tries) = memory.withLock { ($0.heard, $0.tries) }
        let voices = heard.map { key, h in
            LiveVoiceRules.Voice(key: key, scores: library.ranked(h.vector), seconds: h.seconds, mixed: h.mixed, vector: h.vector,
                                 final: !tries.isDue(key, speech: .greatestFiniteMagnitude))
        }
        let roster = invite.map { InviteRoster(invite: $0, profiles: library.profiles, people: library.identity?.people.people ?? []) }
        let outcome = LiveVoiceRules.decide(voices, current: transcript.names, roster: roster, owner: library.owner?.name,
                                            provisional: library.provisional, room: room, matchThreshold: library.matchThreshold)
        if outcome.names != transcript.names { Log.info(outcome.logLine) }
        return outcome.names
    }
}
