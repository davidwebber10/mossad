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
        entries(owner: owner).filter { $0.time >= (since ?? 0) }.map(\.line).joined(separator: "\n")
    }

    /// The visible lines with who said each: the owner by name, a voice by the name the library gave it, else
    /// "Speaker A" ("Speaker A2" in the second stream session, whose letters start over), else "Others". A draft of
    /// an older session will never end, so it counts as said.
    public func entries(owner: String) -> [LiveEntry] { entries(owner: owner, lines: visibleLines) }

    /// The same for lines whose echo filter already ran, as the live page keeps them.
    public func entries(owner: String, lines: [Line]) -> [LiveEntry] {
        lines.map { line in
            let named = line.speakerKey.flatMap { names[$0] }
            let who = line.source == .me ? owner : named ?? line.speaker.map { Self.label($0, session: line.session) } ?? "Others"
            return LiveEntry(time: line.time, who: who, text: line.text, isFinal: line.isFinal || line.session < session,
                             mine: line.source == .me || named == owner)
        }
    }

    static func label(_ letter: String, session: Int) -> String {
        session == 0 ? "Speaker \(letter)" : "Speaker \(letter)\(session + 1)"
    }

    /// Each named voice by the label it had before its name: "Speaker A2" is Sam Carter.
    public var voiceNames: [String: String] {
        var out: [String: String] = [:]
        for (key, name) in names {
            guard let session = Int(key.prefix { $0.isNumber }) else { continue }
            let letter = String(key.drop { $0.isNumber })
            guard !letter.isEmpty else { continue }
            out[Self.label(letter, session: session)] = name
        }
        return out
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
        var memo = EchoMemo()
        return visibleLines(memo: &memo)
    }

    /// What the echo filter found for the mic lines that cannot change any more, by line ID. The transcript is
    /// published four times a second for the whole call; with this, a pass looks only at the last seconds.
    public struct EchoMemo: Sendable {
        var shown: [String: Bool] = [:]
        public init() {}
    }

    /// The same lines as `visibleLines`. `memo` must belong to this transcript; start a new one after `reset()`.
    public func visibleLines(memo: inout EchoMemo) -> [Line] {
        // The lines are in time order, so the call lines near a mic line are found by halving, and a call line is
        // split into words once, not once for each pair of lines.
        let calls = lines.indices.filter { lines[$0].source == .them }
        var callWords: [Int: Set<String>] = [:]
        let newest = lines.last?.time ?? 0
        return lines.filter { line in
            guard line.source == .me else { return true }
            if let known = memo.shown[line.id] { return known }
            var low = 0, high = calls.count
            while low < high {
                let mid = (low + high) / 2
                if lines[calls[mid]].time < line.time - Self.echoWindow { low = mid + 1 } else { high = mid }
            }
            var shown = true
            // Settled: the line and every call line near it are final, and no new line can still start near it.
            var settled = line.isFinal && newest - line.time > Self.echoWindow * 2
            let mine = Self.words(line.text)
            var c = low
            while c < calls.count, lines[calls[c]].time <= line.time + Self.echoWindow {
                let i = calls[c]
                c += 1
                if !lines[i].isFinal { settled = false }
                guard shown, mine.count >= Self.echoMinimumWords else { continue }
                let words = callWords[i] ?? Set(Self.words(lines[i].text))
                callWords[i] = words
                if Double(mine.filter(words.contains).count) / Double(mine.count) >= Self.echoShare { shown = false }
            }
            if settled { memo.shown[line.id] = shown }
            return shown
        }
    }

    static let echoWindow: TimeInterval = 8
    static let echoShare = 0.6
    static let echoMinimumWords = 3

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }
}
