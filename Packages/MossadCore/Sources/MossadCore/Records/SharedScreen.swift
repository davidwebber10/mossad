import Foundation

/// One kept frame of a screen that someone shared in the call, with the text that was on it.
public struct SharedScreen: Codable, Equatable, Sendable, Identifiable {
    /// Seconds into the recording.
    public var offset: TimeInterval
    /// The picture's name inside the call folder's `frames/`. The picture can be gone (old audio is removed).
    public var file: String
    public var text: String
    /// Who shared, when the call app showed it. Never a guess.
    public var presenter: String?
    public var window: String?
    /// The time of day, saved when the frame was taken. Nil in records from before it was saved.
    public var time: Date?
    /// The share session's number from the capture; nil in records from before sessions were numbered.
    public var session: Int?

    public var id: String { file }

    public init(offset: TimeInterval, file: String, text: String, presenter: String? = nil, window: String? = nil,
                time: Date? = nil, session: Int? = nil) {
        self.offset = offset
        self.file = file
        self.text = text
        self.presenter = presenter
        self.window = window
        self.time = time
        self.session = session
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        offset = try c.decode(TimeInterval.self, forKey: .offset)
        file = try c.decode(String.self, forKey: .file)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        presenter = try c.decodeIfPresent(String.self, forKey: .presenter)
        window = try c.decodeIfPresent(String.self, forKey: .window)
        time = try c.decodeIfPresent(Date.self, forKey: .time)
        session = try c.decodeIfPresent(Int.self, forKey: .session)
    }

    /// The transcript line for this screen, without the time: `Screen shared by Sam Carter: "…"`.
    public var lineText: String {
        let head = presenter.map { "Screen shared by \($0)" } ?? "Screen"
        return "\(head): \"\(ScreenText.excerpt(text))\""
    }
}

/// Rules for the text read from a frame.
public enum ScreenText {
    /// A line of the transcript holds this much of a screen's text.
    public static let excerptLength = 300
    /// The record keeps this much of a screen's text, for search.
    public static let storedLength = 4_000
    static let minimumWords = 40
    static let minimumSentenceCharacters = 40

    /// A slide or a document has lines of text. A grid of faces has only names and the app's buttons: short lines.
    /// Enough is many words, or some text in lines of four words or more.
    public static func hasEnough(_ text: String) -> Bool {
        var words = 0, sentence = 0
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) || $0.contains(where: \.isNumber) }
            words += parts.count
            if parts.count >= 4 { sentence += parts.reduce(0) { $0 + $1.count } }
        }
        return words >= minimumWords || sentence >= minimumSentenceCharacters
    }

    /// One line, at most `excerptLength` characters, safe inside the quotes of a transcript line.
    public static func excerpt(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").replacingOccurrences(of: "\"", with: "'")
        return line.count > excerptLength ? String(line.prefix(excerptLength)) : line
    }

    public static func stored(_ text: String) -> String {
        text.count > storedLength ? String(text.prefix(storedLength)) : text
    }

    /// The words of a query, as the marks and the grid's filter both use them.
    public static func terms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
    }

    /// True when a screen's text holds every word of the query.
    public static func contains(_ text: String, query: String) -> Bool {
        let terms = terms(query), lower = text.lowercased()
        return !terms.isEmpty && terms.allSatisfy(lower.contains)
    }

    /// The boxes of the words that hold any word of the query, for the marks on a frame.
    public static func matches(_ words: [ScreenWord], query: String) -> [ScreenWord] {
        let terms = terms(query)
        guard !terms.isEmpty else { return [] }
        return words.filter { w in
            let text = w.text.lowercased()
            return terms.contains { text.contains($0) }
        }
    }
}

extension CallRecord {
    /// The screens as transcript lines. Made from `screens` each time, never stored in `markers`.
    public var screenMarkers: [TranscriptMarker] {
        (screens ?? []).map { TranscriptMarker(offset: $0.offset, text: $0.lineText) }
            + (screenGaps ?? []).map { TranscriptMarker(offset: $0.offset, text: $0.text) }
    }

    /// The date at a second of the recording. The seconds leave out the time between the parts of a joined
    /// meeting, so the part's own start counts. Paused time is not known here; a screen carries its own time.
    public func date(atOffset offset: TimeInterval) -> Date {
        guard let part = parts.last(where: { $0.offset <= offset }) else { return start.addingTimeInterval(offset) }
        return part.start.addingTimeInterval(offset - part.offset)
    }

    /// The time of day a screen was on, exact when it was saved with the frame.
    public func date(of screen: SharedScreen) -> Date {
        screen.time ?? date(atOffset: screen.offset)
    }

    /// Lines of the transcript within `seconds` of a moment, with speaker names, for the view next to a screen.
    public func lines(around offset: TimeInterval, within seconds: TimeInterval = 30) -> [(start: TimeInterval, speaker: String, text: String)] {
        let names = MarkdownWriter.displayNames(self)
        return Transcript.interleaved(utterances).filter { $0.end >= offset - seconds && $0.start <= offset + seconds }
            .map { ($0.start, names[$0.speakerKey] ?? $0.speakerKey, $0.text) }
    }

    /// Who talked most in the minute around a moment: shown as "while X was speaking", never as the presenter.
    public func mainSpeaker(around offset: TimeInterval, within seconds: TimeInterval = 30) -> String? {
        var talk: [String: TimeInterval] = [:]
        for u in utterances {
            let overlap = min(u.end, offset + seconds) - max(u.start, offset - seconds)
            if overlap > 0 { talk[u.speakerKey, default: 0] += overlap }
        }
        guard let key = talk.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else { return nil }
        return MarkdownWriter.displayNames(self)[key]
    }
}
