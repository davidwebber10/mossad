import Foundation

/// What was said so far in the call, from the streaming transcription. Only for display while the call
/// runs; the note still uses the full transcription of the recording after the call.
public struct LiveTranscript: Equatable, Sendable {
    public struct Line: Equatable, Sendable, Identifiable {
        public var source: Track
        public var order: Int
        public var text: String
        public var isFinal: Bool
        /// Seconds into the call when the line began.
        public var time: TimeInterval
        public var id: String { "\(source.rawValue)-\(order)" }
    }

    public private(set) var lines: [Line] = []

    public init() {}

    /// Applies one server message from a source's stream. Returns whether the lines changed.
    @discardableResult
    public mutating func apply(_ message: Data, source: Track, at time: TimeInterval) -> Bool {
        struct Turn: Decodable {
            let type: String
            let turn_order: Int?
            let end_of_turn: Bool?
            let transcript: String?
        }
        guard let turn = try? JSONDecoder().decode(Turn.self, from: message), turn.type == "Turn",
              let order = turn.turn_order, let text = turn.transcript, !text.isEmpty else { return false }
        if let i = lines.firstIndex(where: { $0.source == source && $0.order == order }) {
            // A final line does not go back to a draft.
            guard !lines[i].isFinal || turn.end_of_turn == true else { return false }
            lines[i].text = text
            lines[i].isFinal = turn.end_of_turn ?? false
        } else {
            lines.append(Line(source: source, order: order, text: text, isFinal: turn.end_of_turn ?? false, time: time))
            lines.sort { $0.time < $1.time }
        }
        return true
    }

    public mutating func reset() { lines = [] }

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
