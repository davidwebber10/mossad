import Foundation

/// What was said so far in the call, from the streaming transcription. For display and for the current_call
/// tool while the call runs; the note still uses the full transcription of the recording after the call.
public struct LiveTranscript: Codable, Equatable, Sendable {
    /// Saved next to call.json while the call records, for Chat and other AI apps; removed when the full
    /// transcription starts.
    public static let fileName = "live.json"

    public struct Line: Codable, Equatable, Sendable, Identifiable {
        public var source: Track
        public var order: Int
        public var text: String
        public var isFinal: Bool
        /// Seconds into the call when the line began.
        public var time: TimeInterval
        /// The streaming service's label for a call-audio voice ("A", "B"); nil until it knows.
        public var speaker: String?
        /// Each pause starts a new streaming session, whose turn numbers and labels start over.
        public var session = 0
        /// Where the line's words are in the track file, in seconds, once the service has final words.
        public var audioStart: TimeInterval?
        public var audioEnd: TimeInterval?
        public var id: String { "\(source.rawValue)-\(session)-\(order)" }
        /// The speaker label with its session, such as "0A": the key for `names`.
        public var speakerKey: String? { speaker.map { "\(session)\($0)" } }
    }

    public private(set) var lines: [Line] = []
    public private(set) var session = 0
    /// Names found from the voice library during the call, by speaker key.
    public var names: [String: String] = [:]

    public init() {}

    /// Applies one server message from a source's stream. Returns whether the lines changed.
    /// `audioOffset` is where this session's audio starts in the track file.
    @discardableResult
    public mutating func apply(_ message: Data, source: Track, at time: TimeInterval, audioOffset: TimeInterval = 0) -> Bool {
        struct Word: Decodable {
            let start, end: Double?
            let word_is_final: Bool?
        }
        struct Turn: Decodable {
            let type: String
            let turn_order: Int?
            let end_of_turn: Bool?
            let transcript: String?
            let speaker_label: String?
            let words: [Word]?
        }
        guard let turn = try? JSONDecoder().decode(Turn.self, from: message), turn.type == "Turn",
              let order = turn.turn_order, let text = turn.transcript, !text.isEmpty else { return false }
        // A turn with under a second of audio comes back PENDING; keep the label it already had.
        let speaker = turn.speaker_label.flatMap { $0.count <= 2 ? $0 : nil }
        let final = (turn.words ?? []).filter { $0.word_is_final == true }
        let audioStart = final.first?.start.map { audioOffset + $0 / 1000 }
        let audioEnd = final.last?.end.map { audioOffset + $0 / 1000 }
        if let i = lines.firstIndex(where: { $0.source == source && $0.session == session && $0.order == order }) {
            // A final line does not go back to a draft.
            guard !lines[i].isFinal || turn.end_of_turn == true else { return false }
            lines[i].text = text
            lines[i].isFinal = turn.end_of_turn ?? false
            if let speaker { lines[i].speaker = speaker }
            if let audioStart, let audioEnd { (lines[i].audioStart, lines[i].audioEnd) = (audioStart, audioEnd) }
        } else {
            lines.append(Line(source: source, order: order, text: text, isFinal: turn.end_of_turn ?? false, time: time, speaker: speaker,
                              session: session, audioStart: audioStart, audioEnd: audioEnd))
            lines.sort { $0.time < $1.time }
        }
        return true
    }

    public mutating func reset() { self = LiveTranscript() }

    public mutating func newSession() { session += 1 }

    /// "[01:05] Speaker A: text" lines, from `since` seconds into the call. The owner's lines use their name.
    public func text(owner: String, since: TimeInterval?) -> String {
        visibleLines.filter { $0.time >= (since ?? 0) }.map { line in
            let t = Int(line.time)
            let who = line.source == .me ? owner : line.speakerKey.flatMap { names[$0] } ?? line.speaker.map { "Speaker \($0)" } ?? "Others"
            return String(format: "[%02d:%02d] ", t / 60, t % 60) + "\(who): \(line.text)" + (line.isFinal ? "" : " (still speaking)")
        }.joined(separator: "\n")
    }

    public func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> LiveTranscript {
        try JSONDecoder().decode(LiveTranscript.self, from: Data(contentsOf: url))
    }

    /// The lines without the mic's echo of the call. The mic is recorded raw, so it also hears the speakers:
    /// a "You" line that repeats a call line from the same few seconds is that echo. Short lines such as
    /// "Yeah." stay, since they are as likely to be the owner's own.
    public var visibleLines: [Line] {
        let calls = lines.filter { $0.source == .them }
        return lines.filter { line in
            guard line.source == .me else { return true }
            let mine = Self.words(line.text)
            guard mine.count >= Self.echoMinimumWords else { return true }
            return !calls.contains { call in
                abs(call.time - line.time) <= Self.echoWindow
                    && Double(mine.filter(Set(Self.words(call.text)).contains).count) / Double(mine.count) >= Self.echoShare
            }
        }
    }

    static let echoWindow: TimeInterval = 8
    static let echoShare = 0.6
    static let echoMinimumWords = 3

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }
}
