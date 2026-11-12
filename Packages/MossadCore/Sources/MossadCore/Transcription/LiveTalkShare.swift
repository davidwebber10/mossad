import Foundation

extension LiveTranscript {
    /// Who spoke in the live transcript, so far.
    public enum Voice: Hashable, Sendable {
        case owner
        /// A voice named from the voice library: one person, whatever its labels across pauses.
        case named(String)
        /// An unnamed voice, by its speaker key ("0A").
        case speaker(String)
    }

    public struct TalkShare: Equatable, Sendable {
        public let voice: Voice
        public let seconds: TimeInterval
        /// The voice's place in the speaker hues, the same as its lines in the live transcript.
        public let hue: Int
    }

    /// The voice a line belongs to. A voice named as the owner is the owner.
    public func voice(of line: Line, owner: String? = nil) -> Voice? {
        if line.source == .me { return .owner }
        guard let key = line.speakerKey else { return nil }
        guard let name = names[key] else { return .speaker(key) }
        return name == owner ? .owner : .named(name)
    }

    /// One speaker keeps one color: the owner is hue 0, and every other voice takes its letter's hue (A is 1,
    /// B is 2), so a voice heard before the owner never takes the owner's. A named voice keeps the hue of the
    /// label it was first heard under, across pauses.
    public func hue(of line: Line, owner: String? = nil) -> Int {
        switch voice(of: line, owner: owner) {
        case .owner: return 0
        case .named(let name):
            let first = visibleLines.first { $0.source == .them && $0.speakerKey.flatMap { names[$0] } == name } ?? line
            return Self.letterHue(first.speaker)
        // A later session's letter is another voice: its own hue, away from the first session's letters.
        case .speaker, nil: return Self.letterHue(line.speaker) + 6 * line.session
        }
    }

    static func letterHue(_ letter: String?) -> Int {
        guard let value = letter?.unicodeScalars.first?.value, value >= 65 else { return 1 }
        return 1 + Int(value) - 65
    }

    /// Seconds of speech per voice, the owner first and then the others in the order they were first heard:
    /// the menu bar's talk-share strip. A line's word times give its length; a line without them counts its
    /// words at an ordinary pace.
    public func talkShares(owner: String? = nil) -> [TalkShare] {
        var order: [Voice] = []
        var seconds: [Voice: TimeInterval] = [:]
        var hues: [Voice: Int] = [:]
        for line in visibleLines {
            guard let voice = voice(of: line, owner: owner) else { continue }
            if seconds[voice] == nil {
                order.append(voice)
                hues[voice] = hue(of: line, owner: owner)
            }
            seconds[voice, default: 0] += Self.length(of: line)
        }
        if let i = order.firstIndex(of: .owner) { order.insert(order.remove(at: i), at: 0) }
        return order.map { TalkShare(voice: $0, seconds: seconds[$0] ?? 0, hue: hues[$0] ?? 1) }
    }

    static let wordsPerSecond = 2.5

    private static func length(of line: Line) -> TimeInterval {
        if let start = line.audioStart, let end = line.audioEnd, end > start { return end - start }
        return Double(words(line.text).count) / wordsPerSecond
    }
}
