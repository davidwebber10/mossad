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
                let body = line.drop { $0 == ">" }.trimmingCharacters(in: .whitespaces)
                // A line that starts with a time is the next quote, not more of this one.
                if body.hasPrefix("["), Self.startsWithTime(body) { flushQuote() }
                quote.append(body)
                continue
            }
            flushQuote()
            if line.count >= 3, Set(line).count == 1, let c = line.first, "-*_".contains(c) {
                flush()
                out.append(.rule)
                continue
            }
            if line.hasPrefix("#"), line.drop(while: { $0 == "#" }).first.map({ $0 == " " }) ?? true {
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

    private static let time = #"\[(\d{1,3}:\d{2}(?::\d{2})?)\](?:\((mossad://[^)\s]+)\))?"#
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
            let speaker = group(m, 3)
            // A speaker is a name: four words at most and no digit. Else the colon was part of the words.
            if let speaker, !isName(speaker) {
                let words = ns.substring(from: m.range(at: 2).location == NSNotFound ? m.range(at: 1).upperBound + 1 : m.range(at: 2).upperBound + 1)
                return ChatQuote(speaker: nil, time: group(m, 1), link: group(m, 2), text: unquoted(words.trimmingCharacters(in: .whitespaces)))
            }
            return ChatQuote(speaker: speaker, time: group(m, 1), link: group(m, 2), text: unquoted(group(m, 4) ?? ""))
        }
        if let m = trailing.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            return ChatQuote(speaker: group(m, 2), time: group(m, 3), link: group(m, 4), text: unquoted(group(m, 1) ?? ""))
        }
        return ChatQuote(speaker: nil, time: nil, link: nil, text: text)
    }

    static func isName(_ s: String) -> Bool {
        if s.wholeMatch(of: /Speaker [A-Z]{1,2}\d*/) != nil { return true }
        return s.split(separator: " ").count <= 4 && !s.contains(where: \.isNumber)
    }

    private static func startsWithTime(_ s: String) -> Bool {
        let ns = s as NSString
        return leading.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func unquoted(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D} "))
    }

    // MARK: Times

    private static let moment = try! NSRegularExpression(pattern: #"mossad://call/[^)?\s]+\?t=([0-9]+(?:\.[0-9]+)?)"#)

    /// The whole seconds of each moment link in a block's text, in order: where an answer's time chips point.
    public static func momentSeconds(in text: String) -> [Int] {
        let ns = text as NSString
        return moment.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            Double(ns.substring(with: $0.range(at: 1))).map { Int($0) }
        }
    }

    private static let bare = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?::(\d{2}))?\](?:\((mossad://call/[^)?\s]+)(\?t=[0-9.]+)?\)|(?!\())"#)

    /// Each time in an answer as a chip to its moment. A "[12:04]" with no link gets one to `callID`; a time link
    /// to a moment gets its `t` from the label, so a wrong sum by the model never moves the chip.
    public static func linkTimes(_ text: String, callID: String?) -> String {
        let ns = text as NSString
        var out = text
        for m in bare.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            func value(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            let parts = (1...3).compactMap { value($0).flatMap(Int.init) }
            let seconds: Int
            if parts.count == 3 {
                guard parts[1] < 60, parts[2] < 60 else { continue }
                seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
            } else {
                guard parts.count == 2, parts[1] < 60 else { continue }
                seconds = parts[0] * 60 + parts[1]
            }
            let label = ns.substring(with: m.range(at: 0)).prefix { $0 != "]" }.dropFirst()
            let base: String
            if let linked = value(4) {
                // A link to the whole meeting under a time label is left as the model wrote it.
                guard value(5) != nil else { continue }
                base = linked
            } else if let callID {
                base = "mossad://call/\(callID)"
            } else {
                continue
            }
            let range = Range(m.range, in: out)!
            out.replaceSubrange(range, with: "[\(label)](\(base)?t=\(seconds))")
        }
        return out
    }
}
