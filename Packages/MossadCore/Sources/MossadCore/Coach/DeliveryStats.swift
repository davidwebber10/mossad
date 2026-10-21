import Foundation

/// How the owner spoke, measured from the transcript's timing. Claude cannot hear the audio, so these numbers
/// stand in for pace, fillers, and turn-taking.
public struct DeliveryStats: Codable, Equatable, Sendable, Hashable {
    public var talkSeconds: TimeInterval
    /// The owner's part of all speech in the call, 0 to 1.
    public var talkShare: Double
    public var words: Int
    public var wordsPerMinute: Double
    /// The fastest single turn of at least `minimumTurnWords` words.
    public var fastestWordsPerMinute: Double
    public var fillers: Int
    public var fillersPerMinute: Double
    public var longestTurnSeconds: TimeInterval
    public var questions: Int
    /// Times the owner started while someone else was still speaking.
    public var interruptions: Int
    /// Times someone else started while the owner was still speaking.
    public var interrupted: Int
    /// From the audio, when the mic track could be read.
    public var tone: VoiceTone?

    static let minimumTurnWords = 15
    /// An overlap shorter than this is a quick "yeah" or a hand-off, not a cut-in.
    static let overlapGrace: TimeInterval = 1
    static let fillerWords: Set<String> = ["um", "uh", "uhm", "umm", "er", "erm", "hmm", "mm"]

    public init(record r: CallRecord, owner: String) {
        let ownerKeys = Set(r.speakerNames.filter { $0.value == owner }.keys)
        let mine = r.utterances.filter { ownerKeys.contains($0.speakerKey) }
        let others = r.utterances.filter { !ownerKeys.contains($0.speakerKey) }
        func duration(_ u: Utterance) -> TimeInterval { max(0, u.end - u.start) }
        func tokens(_ u: Utterance) -> [String] { u.text.split(whereSeparator: \.isWhitespace).map(String.init) }

        talkSeconds = mine.map(duration).reduce(0, +)
        let all = r.utterances.map(duration).reduce(0, +)
        talkShare = all > 0 ? talkSeconds / all : 0
        words = mine.map { tokens($0).count }.reduce(0, +)
        let minutes = talkSeconds / 60
        wordsPerMinute = minutes > 0 ? Double(words) / minutes : 0
        fastestWordsPerMinute = mine.compactMap { u -> Double? in
            let n = tokens(u).count
            return n >= Self.minimumTurnWords && duration(u) > 0 ? Double(n) / duration(u) * 60 : nil
        }.max() ?? 0
        fillers = mine.flatMap(tokens).filter {
            Self.fillerWords.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters))
        }.count
        fillersPerMinute = minutes > 0 ? Double(fillers) / minutes : 0
        longestTurnSeconds = mine.map(duration).max() ?? 0
        questions = mine.filter { $0.text.contains("?") }.count
        interruptions = mine.filter { u in others.contains { $0.start < u.start && $0.end > u.start + Self.overlapGrace } }.count
        interrupted = others.filter { o in mine.contains { $0.start < o.start && $0.end > o.start + Self.overlapGrace } }.count
    }
}
