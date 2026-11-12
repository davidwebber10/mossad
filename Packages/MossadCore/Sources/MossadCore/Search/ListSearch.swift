import Foundation

/// Where a list row's match was found, so the row can say why it is in the list.
public enum ListMatchSource: Sendable, Equatable {
    /// The row's own title or name: the row needs no line under it.
    case title
    /// Another field, by its label: "Email", "Job title", "Tag", "Summary".
    case field(String)
    /// A transcript line, or the text on a shared screen (speaker "Screen").
    case transcript(speaker: String)
}

/// Why one row of a list matched its search: the title with the query's words marked, and, when the title does
/// not hold every word, the best other place with its words marked, cut to a short snippet.
public struct ListMatch: Sendable, Equatable {
    public var title: SearchText
    public var source: ListMatchSource
    /// Nil when the source is the title.
    public var context: SearchText?
    /// Seconds into the call, to open the meeting there: a transcript line, a screen, a bookmark, a decision.
    public var time: TimeInterval?

    public init(title: SearchText, source: ListMatchSource = .title, context: SearchText? = nil, time: TimeInterval? = nil) {
        self.title = title
        self.source = source
        self.context = context
        self.time = time
    }
}

/// One searchable part of a list row other than its title.
public struct ListField: Sendable, Equatable {
    public var label: String
    public var text: String

    public init(_ label: String, _ text: String) {
        self.label = label
        self.text = text
    }
}

/// The search of a page's own list (People, Tasks, Shares): each word of the query must start a word somewhere in
/// the row, without regard to case or accents, in any order. Small lists only: it reads each row's text each time.
public struct ListSearch: Sendable {
    let words: [String]

    public init(_ query: String) {
        words = Array(SearchTokenizer.terms(query).prefix(ParsedQuery.maxWords))
    }

    /// True when the query has no words: every row matches, with nothing to mark.
    public var isEmpty: Bool { words.isEmpty }

    /// The match of a row, or nil when a word is in none of its fields. The fields come strongest first: a tie on
    /// the number of words goes to the earlier one.
    public func match(title: String, fields: [ListField]) -> ListMatch? {
        guard !isEmpty else { return ListMatch(title: SearchText(title)) }
        let titleTokens = SearchTokenizer.tokens(title)
        let others = fields.filter { !$0.text.isEmpty }.map { ($0, SearchTokenizer.tokens($0.text)) }
        let titleWords = found(in: titleTokens)
        var all = titleWords
        for (_, tokens) in others { all.formUnion(found(in: tokens)) }
        guard all.count == words.count else { return nil }
        let marked = SearchText(title, matches: title.searchRanges(spans(titleTokens)))
        guard titleWords.count < words.count else { return ListMatch(title: marked) }
        // The field that holds the most of the words the title lacks.
        var pick: (ListField, [SearchToken], Int)?
        for (field, tokens) in others {
            let n = found(in: tokens).subtracting(titleWords).count
            if n > (pick?.2 ?? 0) { pick = (field, tokens, n) }
        }
        guard let (field, tokens, _) = pick else { return ListMatch(title: marked) }
        let context = Snippet.make(field.text, matches: field.text.searchRanges(spans(tokens)), length: Self.snippetLength)
        return ListMatch(title: marked, source: .field(field.label), context: context)
    }

    /// Shorter than the palette's: the line sits under a row in a narrow column.
    static let snippetLength = 90

    /// The indexes of the query words that start a word in `tokens`.
    private func found(in tokens: [SearchToken]) -> Set<Int> {
        Set(words.indices.filter { i in tokens.contains { $0.term.hasPrefix(words[i]) } })
    }

    private func spans(_ tokens: [SearchToken]) -> [Range<Int>] {
        tokens.filter { t in words.contains { t.term.hasPrefix($0) } }.map(\.range)
    }
}
