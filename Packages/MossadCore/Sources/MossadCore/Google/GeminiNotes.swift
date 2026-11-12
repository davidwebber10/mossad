import Foundation

/// The "Notes by Gemini" document that Google Meet attaches to a calendar event.
public enum GeminiNotes {
    static let docType = "application/vnd.google-apps.document"

    /// The event's Gemini notes: a Google Doc whose title names them.
    public static func attachment(in event: CalendarEventInfo) -> EventAttachment? {
        event.attachments.first { a in
            a.mimeType == docType && a.fileID?.isEmpty == false && a.title.range(of: "Notes by Gemini", options: .caseInsensitive) != nil
        }
    }
}

/// A Google Doc with its tabs, as the Docs API gives it with `includeTabsContent`. Only the text and the paragraph
/// styles are kept.
public struct GeminiDoc: Equatable, Sendable {
    public struct Paragraph: Equatable, Sendable {
        /// The named style, such as "HEADING_3" or "NORMAL_TEXT".
        public var style: String
        public var text: String
        /// The bold text at the start of the paragraph, when there is some: Gemini writes each speaker's name in bold.
        public var boldLead: String?

        public init(style: String, text: String, boldLead: String? = nil) {
            self.style = style
            self.text = text
            self.boldLead = boldLead
        }
    }

    public struct Tab: Equatable, Sendable {
        public var title: String
        public var paragraphs: [Paragraph]
    }

    public var id: String
    public var title: String
    /// Every tab, a child after its parent.
    public var tabs: [Tab]

    public static func url(documentID: String) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        let id = documentID.addingPercentEncoding(withAllowedCharacters: allowed) ?? documentID
        return URL(string: "https://docs.googleapis.com/v1/documents/\(id)?includeTabsContent=true")!
    }

    private struct Answer: Decodable {
        struct TextStyle: Decodable { var bold: Bool? }
        struct Run: Decodable {
            var content: String?
            var textStyle: TextStyle?
        }
        /// A smart chip: a person, a link, or a date, which is not a text run.
        struct Person: Decodable {
            struct Props: Decodable { var name: String?; var email: String? }
            var personProperties: Props?
        }
        struct RichLink: Decodable {
            struct Props: Decodable { var title: String?; var uri: String? }
            var richLinkProperties: Props?
        }
        struct DateChip: Decodable {
            struct Props: Decodable { var displayText: String? }
            var dateElementProperties: Props?
        }
        struct Element: Decodable {
            var textRun: Run?
            var person: Person?
            var richLink: RichLink?
            var dateElement: DateChip?

            var text: String {
                textRun?.content ?? person?.personProperties.flatMap { $0.name ?? $0.email }
                    ?? richLink?.richLinkProperties.flatMap { $0.title ?? $0.uri } ?? dateElement?.dateElementProperties?.displayText ?? ""
            }
        }
        struct Style: Decodable { var namedStyleType: String? }
        struct Para: Decodable {
            var elements: [Element]?
            var paragraphStyle: Style?
        }
        struct Structural: Decodable { var paragraph: Para? }
        struct Body: Decodable { var content: [Structural]? }
        struct DocTab: Decodable { var body: Body? }
        struct Props: Decodable { var title: String? }
        final class TabNode: Decodable {
            var tabProperties: Props?
            var documentTab: DocTab?
            var childTabs: [TabNode]?
        }

        var documentId: String?
        var title: String?
        var tabs: [TabNode]?
        /// A document read without tabs.
        var body: Body?
    }

    public static func parse(_ data: Data) throws -> GeminiDoc {
        guard let a = try? JSONDecoder().decode(Answer.self, from: data) else { throw GoogleError.unexpectedAnswer }
        func paragraphs(_ body: Answer.Body?) -> [Paragraph] {
            (body?.content ?? []).compactMap(\.paragraph).map { p in
                let elements = p.elements ?? []
                let text = elements.map(\.text).joined()
                // The leading runs that are bold, as one text.
                var lead = ""
                for e in elements {
                    guard let run = e.textRun, run.textStyle?.bold == true, let content = run.content else { break }
                    lead += content
                }
                return Paragraph(style: p.paragraphStyle?.namedStyleType ?? "NORMAL_TEXT", text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                 boldLead: lead.trimmingCharacters(in: .whitespacesAndNewlines).nonBlank)
            }
        }
        var tabs: [Tab] = []
        func walk(_ nodes: [Answer.TabNode]) {
            for n in nodes {
                tabs.append(Tab(title: n.tabProperties?.title ?? "", paragraphs: paragraphs(n.documentTab?.body)))
                walk(n.childTabs ?? [])
            }
        }
        walk(a.tabs ?? [])
        if tabs.isEmpty, a.body != nil { tabs = [Tab(title: "", paragraphs: paragraphs(a.body))] }
        return GeminiDoc(id: a.documentId ?? "", title: a.title ?? "", tabs: tabs)
    }

    func tab(_ title: String) -> Tab? { tabs.first { $0.title.caseInsensitiveCompare(title) == .orderedSame } }

    /// The transcript's lines; empty when the document has no Transcript tab.
    public var transcript: [GeminiLine] {
        tab("Transcript").map { GeminiTranscript.parse($0.paragraphs) } ?? []
    }

    /// Whether the transcript has Gemini's end line: the document is complete.
    public var transcriptEnded: Bool {
        tab("Transcript")?.paragraphs.contains { GeminiTranscript.endLine($0.text) != nil } ?? false
    }

    /// Gemini's own notes as plain text: "Full notes", else "Quick notes", else the first tab that is not the
    /// transcript. Nil when there is none.
    public var notesText: String? {
        let t = tab("Full notes") ?? tab("Quick notes") ?? tabs.first { $0.title.caseInsensitiveCompare("Transcript") != .orderedSame }
        return t.map { $0.paragraphs.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n") }?.nonBlank
    }
}

/// One line of a Gemini transcript, with its time in seconds from the start of the meeting.
public struct GeminiLine: Equatable, Sendable {
    public var name: String
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
}

/// Reads the Transcript tab: a HEADING_3 time such as 00:01:13 every minute or two, then "Name: text" lines. Pure.
/// Gemini gives no time for each line, so each line gets one from its place: the words of a block share the time
/// to the next heading.
public enum GeminiTranscript {
    /// The pace that times a block with no next heading: 150 words a minute.
    static let wordsPerSecond = 2.5

    public static func parse(_ paragraphs: [GeminiDoc.Paragraph]) -> [GeminiLine] {
        struct Pending { var name: String; var text: String; var block: Int }
        var blocks: [TimeInterval] = [0]
        var lines: [Pending] = []
        var ended: TimeInterval?
        // After an end line, only a new time heading continues the transcript (a restart); the note under the end
        // line is no one's words.
        var afterEnd = false
        // When the names are bold, only a bold name is a name: "One more thing: the date" stays a line of text.
        let boldNames = paragraphs.contains { p in p.boldLead.map { speaker(bold: $0, in: p.text) != nil } ?? false }
        for p in paragraphs {
            let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if p.style.hasPrefix("HEADING") {
                if let t = seconds(text) {
                    afterEnd = false
                    if lines.isEmpty { blocks[0] = t } else { blocks.append(t) }
                }
                continue
            }
            if let end = endLine(text) {
                ended = max(ended ?? 0, end)
                afterEnd = true
                continue
            }
            guard !afterEnd else { continue }
            let found = boldNames ? p.boldLead.flatMap { speaker(bold: $0, in: text) } : speaker(text)
            if let (name, said) = found {
                lines.append(Pending(name: name, text: said, block: blocks.count - 1))
            } else if !lines.isEmpty {
                lines[lines.count - 1].text += " " + text
            }
        }
        // Keep each block's time after the one before it, whatever the headings say.
        for i in blocks.indices.dropFirst() where blocks[i] < blocks[i - 1] { blocks[i] = blocks[i - 1] }
        var out: [GeminiLine] = []
        for (b, start) in blocks.enumerated() {
            let mine = lines.filter { $0.block == b }
            guard !mine.isEmpty else { continue }
            let counts = mine.map { Double(words($0.text)) }
            let total = max(1, counts.reduce(0, +))
            let next = b + 1 < blocks.count ? blocks[b + 1] : nil
            let end = next ?? max(ended ?? 0, start + total / wordsPerSecond)
            let span = max(0, end - start)
            var done = 0.0
            for (i, line) in mine.enumerated() {
                let s = start + span * done / total
                done += counts[i]
                out.append(GeminiLine(name: line.name, text: line.text, start: s, end: start + span * done / total))
            }
        }
        return out
    }

    /// A bold lead such as "Dr. Sam Carter:" names the speaker whatever marks the name has.
    static func speaker(bold: String, in text: String) -> (String, String)? {
        guard bold.hasSuffix(":") || text.dropFirst(bold.count).hasPrefix(":") else { return nil }
        let name = bold.trimmingCharacters(in: CharacterSet(charactersIn: ": ")).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 80, text.hasPrefix(name) else { return nil }
        var rest = text.dropFirst(name.count).drop { $0 == ":" || $0.isWhitespace }
        rest = rest.drop { $0.isWhitespace }
        let said = String(rest).trimmingCharacters(in: .whitespaces)
        return said.isEmpty ? nil : (name, said)
    }

    static func words(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    /// "00:01:13", "1:02:03", or "12:30" as seconds; nil for anything else.
    static func seconds(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(\.isNumber) }) else { return nil }
        let n = parts.compactMap { Double($0) }
        return n.count == 3 ? n[0] * 3600 + n[1] * 60 + n[2] : n[0] * 60 + n[1]
    }

    /// "Transcription ended after 00:45:12".
    static func endLine(_ text: String) -> TimeInterval? {
        let prefix = "Transcription ended after "
        guard text.hasPrefix(prefix) else { return nil }
        return seconds(String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters).subtracting(CharacterSet(charactersIn: ":"))))
    }

    /// "Sam Carter: text": a name of at most 6 words with no sentence marks, a colon, and what they said.
    static func speaker(_ text: String) -> (String, String)? {
        guard let colon = text.range(of: ": ") else { return nil }
        let name = String(text[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
        let said = String(text[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !said.isEmpty, name.count <= 60, words(name) <= 6, name.first?.isLetter == true,
              !name.contains(where: { ".?!/:;\"()[]".contains($0) }),
              // A name's longer words start with a capital: "One more thing: the date" is not a speaker.
              name.split(separator: " ").allSatisfy({ $0.count <= 3 || $0.first?.isUppercase == true }) else { return nil }
        return (name, said)
    }
}
