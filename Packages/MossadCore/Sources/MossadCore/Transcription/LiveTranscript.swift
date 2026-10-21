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
}
