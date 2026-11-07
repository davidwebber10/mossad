import Foundation

/// Text to show in a result, with the parts that matched the query.
public struct SearchText: Sendable, Equatable, Hashable {
    public var text: String
    /// Ranges in `text` to show in bold.
    public var matches: [Range<String.Index>]

    public init(_ text: String, matches: [Range<String.Index>] = []) {
        self.text = text
        self.matches = matches
    }

    public var matchedStrings: [String] { matches.map { String(text[$0]) } }

    /// The text with the matches strongly emphasized, which SwiftUI's `Text` shows in bold.
    public var attributed: AttributedString {
        var out = AttributedString(text)
        for r in matches {
            if let range = Range(r, in: out) { out[range].inlinePresentationIntent = .stronglyEmphasized }
        }
        return out
    }
}

/// One word of a text: its folded form and where it sits, in UTF-8 offsets.
struct SearchToken: Sendable {
    var term: String
    var range: Range<Int>
}

enum SearchTokenizer {
    /// Splits text into words, lowercased and without accents. An apostrophe inside a word is dropped, so
    /// "don’t" and "don't" both give "dont".
    static func tokens(_ text: String) -> [SearchToken] {
        var out: [SearchToken] = []
        var ascii: [UInt8] = []
        var scalars = String.UnicodeScalarView()
        var isASCII = true
        var start = -1
        var end = 0
        var offset = 0

        func flush() {
            guard start >= 0 else { return }
            let term: String
            if isASCII {
                term = String(decoding: ascii, as: UTF8.self)
            } else {
                term = String(scalars).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            }
            if !term.isEmpty { out.append(SearchToken(term: term, range: start..<end)) }
            ascii.removeAll(keepingCapacity: true)
            scalars.removeAll(keepingCapacity: true)
            isASCII = true
            start = -1
        }

        for s in text.unicodeScalars {
            let v = s.value
            let width = v < 0x80 ? 1 : v < 0x800 ? 2 : v < 0x10000 ? 3 : 4
            defer { offset += width }
            if v < 0x80 {
                let b = UInt8(v)
                let lower: UInt8? = (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) ? b : (b >= 0x41 && b <= 0x5A) ? b | 0x20 : nil
                if let lower {
                    if start < 0 { start = offset }
                    if isASCII { ascii.append(lower) } else { scalars.append(Unicode.Scalar(lower)) }
                    end = offset + width
                } else if b == 0x27, start >= 0 {
                    continue
                } else {
                    flush()
                }
                continue
            }
            let props = s.properties
            let isWord = props.isAlphabetic || props.numericType != nil
            let isMark = props.generalCategory == .nonspacingMark || props.generalCategory == .spacingMark
            if isWord || (isMark && start >= 0) {
                if start < 0 { start = offset }
                if isASCII {
                    isASCII = false
                    scalars.append(contentsOf: ascii.map { Unicode.Scalar($0) })
                    ascii.removeAll(keepingCapacity: true)
                }
                scalars.append(s)
                end = offset + width
            } else if start >= 0, v == 0x2019 || v == 0x2018 || v == 0x02BC {
                continue
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    static func terms(_ text: String) -> [String] { tokens(text).map(\.term) }

    /// A tag as one key, so "#monthlyupdate" and "#monthly" find "Monthly update".
    static func key(_ text: String) -> String { terms(text).joined() }
}

extension String {
    /// The string index for a UTF-8 offset from `SearchTokenizer`.
    func searchIndex(utf8 offset: Int) -> String.Index {
        utf8.index(utf8.startIndex, offsetBy: offset)
    }

    func searchRanges(_ spans: [Range<Int>]) -> [Range<String.Index>] {
        spans.map { searchIndex(utf8: $0.lowerBound)..<searchIndex(utf8: $0.upperBound) }
    }
}

enum Snippet {
    static let length = 120

    /// About `length` characters of `text` centered on the first match, cut at spaces, with an ellipsis where
    /// text was cut. The ranges are moved into the snippet.
    static func make(_ text: String, matches: [Range<String.Index>], length: Int = length) -> SearchText {
        let chars = Array(text)
        let total = chars.count
        let ranges = matches.map { (text.distance(from: text.startIndex, to: $0.lowerBound), text.distance(from: text.startIndex, to: $0.upperBound)) }
        guard total > length else { return SearchText(text, matches: matches) }
        let first = ranges.first ?? (0, 0)
        // A match too long to fit shows from its start.
        let center = first.1 - first.0 >= length ? first.0 + length / 2 : (first.0 + first.1) / 2
        var a = max(0, center - length / 2)
        var b = min(total, a + length)
        a = max(0, b - length)
        // Move inward to whole words, but never past the match.
        // A match longer than the snippet leaves no room on either side.
        if a > 0, a < first.0, let space = chars[a..<min(first.0, b)].firstIndex(where: \.isWhitespace) { a = space + 1 }
        if b < total, first.1 < b, let space = chars[max(first.1, a)..<b].lastIndex(where: \.isWhitespace) { b = space }
        while a < b, chars[a].isWhitespace { a += 1 }
        while b > a, chars[b - 1].isWhitespace { b -= 1 }
        let lead = a > 0 ? "…" : ""
        let snippet = lead + String(chars[a..<b]) + (b < total ? "…" : "")
        let shift = lead.count - a
        let moved = ranges.compactMap { r -> Range<String.Index>? in
            let lo = max(r.0, a), hi = min(r.1, b)
            guard lo < hi else { return nil }
            return snippet.index(snippet.startIndex, offsetBy: lo + shift)..<snippet.index(snippet.startIndex, offsetBy: hi + shift)
        }
        return SearchText(snippet, matches: moved)
    }
}
