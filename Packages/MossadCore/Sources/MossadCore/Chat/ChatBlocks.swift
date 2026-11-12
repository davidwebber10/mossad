import Foundation

public struct ChatListItem: Equatable, Sendable {
    /// "•", or the number with its dot.
    public var marker: String
    public var text: String
    /// 0 at the margin, 1 for an item indented under another.
    public var level: Int

    public init(marker: String, text: String, level: Int) {
        self.marker = marker
        self.text = text
        self.level = level
    }
}

/// A quote from a transcript: the words, and who said them when, when the answer says.
public struct ChatQuote: Equatable, Sendable {
    public var speaker: String?
    /// "12:40", as the answer wrote it.
    public var time: String?
    /// The moment's `mossad://` link.
    public var link: String?
    public var text: String

    public init(speaker: String?, time: String?, link: String?, text: String) {
        self.speaker = speaker
        self.time = time
        self.link = link
        self.text = text
    }
}

public enum ChatBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, items: [ChatListItem])
    case quote(ChatQuote)
    case code(language: String?, text: String)
    case table(header: [String], rows: [[String]])
    case rule
}

/// A chat answer's Markdown as blocks. Inline marks (bold, links, code) stay in each block's text. It reads a
/// half-written answer too, so an answer keeps its form while it streams.
public enum ChatBlocks {
    public static func parse(_ text: String) -> [ChatBlock] {
        var out: [ChatBlock] = []
        var paragraph: [String] = []
        var items: [ChatListItem] = []
        var ordered = false
        var quote: [String] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        func flushParagraph() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        func flushList() {
            if !items.isEmpty { out.append(.list(ordered: ordered, items: items)) }
            items = []
        }
        func flushQuote() {
            if !quote.isEmpty { out.append(.quote(Self.quote(quote.joined(separator: " ")))) }
            quote = []
        }
        func flush() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            i += 1
            if line.hasPrefix("```") {
                flush()
                let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                out.append(.code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n")))
                continue
            }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("|"), i < lines.count, isSeparator(lines[i]) {
                flush()
                let header = cells(line)
                i += 1
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i]))
                    i += 1
                }
                out.append(.table(header: header, rows: rows))
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                flushList()
                quote.append(line.drop { $0 == ">" }.trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()
            if line.count >= 3, Set(line).count == 1, let c = line.first, "-*_".contains(c) {
                flush()
                out.append(.rule)
                continue
            }
            if line.hasPrefix("#") {
                flush()
                let level = min(3, line.prefix { $0 == "#" }.count)
                out.append(.heading(level: level, text: line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                continue
            }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count >= 2 ? 1 : 0
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushParagraph()
                if !items.isEmpty, ordered, indent == 0 { flushList() }
                if items.isEmpty { ordered = false }
                items.append(ChatListItem(marker: "•", text: String(line.dropFirst(2)), level: indent))
                continue
            }
            if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }), !line[..<dot].isEmpty, line[..<dot].allSatisfy(\.isNumber),
               line[line.index(after: dot)...].hasPrefix(" ") {
                flushParagraph()
                if !items.isEmpty, !ordered, indent == 0 { flushList() }
                if items.isEmpty { ordered = true }
                items.append(ChatListItem(marker: line[..<dot] + ".", text: line[line.index(dot, offsetBy: 2)...].trimmingCharacters(in: .whitespaces),
                                          level: indent))
                continue
            }
            if !items.isEmpty, indent > 0 {
                // A wrapped line of the last item.
                items[items.count - 1].text += " " + line
                continue
            }
            flushList()
            paragraph.append(line)
        }
        flush()
        return out
    }

    private static func isSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Quotes

    private static let time = #"\[(\d{1,2}:\d{2}(?::\d{2})?)\](?:\((mossad://[^)\s]+)\))?"#
    /// "[12:40](link) Sam Carter: words"
    private static let leading = try! NSRegularExpression(pattern: "^" + time + #"\s*(?:([^:"\x{201C}]{1,40}):\s*)?(.+)$"#)
    /// "words, Sam, [12:40](link)" after a dash
    private static let trailing = try! NSRegularExpression(pattern: #"^(.+?)(?:\s*[\x{2014}\x{2013}]\s*|\s+--?\s+)([^,\[\]\x{2014}\x{2013}]{1,40}?),?\s*"# + time + "$")

    static func quote(_ text: String) -> ChatQuote {
        let ns = text as NSString
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r).trimmingCharacters(in: .whitespaces)
        }
        if let m = leading.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            return ChatQuote(speaker: group(m, 3), time: group(m, 1), link: group(m, 2), text: unquoted(group(m, 4) ?? ""))
        }
        if let m = trailing.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            return ChatQuote(speaker: group(m, 2), time: group(m, 3), link: group(m, 4), text: unquoted(group(m, 1) ?? ""))
        }
        return ChatQuote(speaker: nil, time: nil, link: nil, text: text)
    }

    private static func unquoted(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D} "))
    }

    // MARK: Times

    private static let bare = try! NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{2})(?::(\d{2}))?\](?!\()"#)

    /// "[12:04]" with no link becomes a link to that moment of `callID`, so it shows as a chip too.
    public static func linkTimes(_ text: String, callID: String?) -> String {
        guard let callID else { return text }
        let ns = text as NSString
        var out = text
        for m in bare.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let parts = (1...3).compactMap { i -> Int? in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : Int(ns.substring(with: r))
            }
            let seconds: Int
            if parts.count == 3 {
                guard parts[1] < 60, parts[2] < 60 else { continue }
                seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
            } else {
                guard parts[1] < 60 else { continue }
                seconds = parts[0] * 60 + parts[1]
            }
            let label = ns.substring(with: m.range).dropFirst().dropLast()
            let range = Range(m.range, in: out)!
            out.replaceSubrange(range, with: "[\(label)](mossad://call/\(callID)?t=\(seconds))")
        }
        return out
    }
}
