import Foundation

/// The owner's last searches in the palette, newest first, for the empty field. A search counts once a result
/// was opened from it, so half-typed words never stay.
public struct RecentSearches: Sendable, Equatable {
    public static let limit = 8

    public private(set) var items: [String]

    public init(_ items: [String] = []) {
        self.items = []
        for item in items.reversed() { add(item) }
    }

    /// Puts the search first. The same words in another case, with other accents, or other spaces replace the
    /// older one; a search with no words is not kept.
    public mutating func add(_ query: String) {
        let text = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let key = Self.key(text)
        guard !key.isEmpty else { return }
        items.removeAll { Self.key($0) == key }
        items.insert(text, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
    }

    public mutating func remove(_ query: String) {
        let key = Self.key(query)
        items.removeAll { Self.key($0) == key }
    }

    public mutating func clear() { items = [] }

    /// The words that the search engine reads, with the `#` and `@` that change what it does.
    static func key(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).map { chunk in
            let mark = chunk.first.map { $0 == "#" || $0 == "@" ? String($0) : "" } ?? ""
            let words = SearchTokenizer.terms(String(chunk)).joined(separator: " ")
            return words.isEmpty ? "" : mark + words
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
