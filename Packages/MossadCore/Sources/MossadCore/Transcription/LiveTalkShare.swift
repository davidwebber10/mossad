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
    }

    /// Seconds of speech per voice, the owner first and then the others in the order they were first heard:
    /// the menu bar's talk-share strip. A line's word times give its length; a line without them counts its
    /// words at an ordinary pace.
    public var talkShares: [TalkShare] {
        var order: [Voice] = []
        var seconds: [Voice: TimeInterval] = [:]
        for line in visibleLines {
            let voice: Voice
            if line.source == .me {
                voice = .owner
            } else if let key = line.speakerKey {
                voice = names[key].map(Voice.named) ?? .speaker(key)
            } else {
                continue
            }
            if seconds[voice] == nil { order.append(voice) }
            seconds[voice, default: 0] += Self.length(of: line)
        }
        if let i = order.firstIndex(of: .owner) { order.insert(order.remove(at: i), at: 0) }
        return order.map { TalkShare(voice: $0, seconds: seconds[$0] ?? 0) }
    }

    static let wordsPerSecond = 2.5

    private static func length(of line: Line) -> TimeInterval {
        if let start = line.audioStart, let end = line.audioEnd, end > start { return end - start }
        return Double(words(line.text).count) / wordsPerSecond
    }
}
