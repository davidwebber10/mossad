import Foundation

/// How two written names relate.
public enum NameFit: Equatable, Sendable {
    /// The same first and family name.
    case same
    /// The same, and only one side has a middle name.
    case sameWithMiddle
    /// The same family name, and one first name is the short form of the other ("Mike", "Michael").
    case nickname
    /// A first name alone, or with an initial ("Sam", "Sam C."), that the other name can be the full form of.
    case short
    /// The same two names in the other order, with no proof of the order ("Carter Sam", "Sam Carter").
    case swapped
    /// The same first and family name with middle names that disagree: two people.
    case conflict
    case none
}

/// A name as someone wrote it, read into its parts. The parts are keys: lowercase, with no diacritics.
public struct ParsedName: Equatable, Sendable {
    /// What shows which word is the family name.
    public enum OrderProof: String, Sendable {
        /// Nothing: the first word is read as the first name.
        case none
        /// "Carter, Sam".
        case comma
        /// "CARTER Sam" or "Sam CARTER".
        case capitals
    }

    public var given: String?
    public var middle: [String]
    /// One word or more: "carter", "de la cruz", "carter reed".
    public var family: String?
    public var suffix: String?
    public var order: OrderProof
    public var raw: String
    /// False for an address, a label such as "Speaker C", and empty text.
    public var isName: Bool

    /// Each word of the name in the order first, middle, family.
    var words: [String] {
        ([given].compactMap { $0 } + middle + [family].compactMap { $0 }).flatMap { $0.contains(" ") ? $0.split(separator: " ").map(String.init) : [$0] }
    }
}

/// Reads and compares names. Pure: no stored people, no file.
public enum PersonNames {
    private static let titles: Set<String> = ["dr", "mr", "mrs", "ms", "miss", "mx", "prof", "professor", "sir", "rev"]
    private static let suffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv", "phd", "md", "mba", "esq", "cpa", "pe", "dds", "rn", "pmp", "jd"]
    /// Words that begin a family name of more than one word.
    private static let particles: Set<String> = ["de", "del", "della", "di", "da", "dos", "das", "du", "la", "le", "van", "von", "der", "den", "ter", "bin", "ibn", "st"]
    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{2018}", "\u{02BC}", "`"]

    /// The form two spellings of one name share: no case, no diacritics, punctuation as a space, single spaces.
    /// An apostrophe is removed, so "O'Neil" is one word.
    public static func key(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var out = ""
        for c in folded where !apostrophes.contains(c) {
            out.append(c.isLetter || c.isNumber ? c : " ")
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    /// The key of the name in a written entry: "Sam Carter (Acme) <sam@acme.com>" gives "sam carter".
    public static func nameKey(_ text: String) -> String { key(withoutBrackets(text)) }

    /// The name of a written entry with no part in brackets: "Carter, Sam (Acme) <sam@acme.com>" gives "Carter, Sam".
    public static func plain(_ text: String) -> String {
        withoutBrackets(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The address in "Sam Carter <sam@acme.com>", in lowercase.
    public static func email(in text: String) -> String? {
        guard let open = text.firstIndex(of: "<"), let close = text[open...].firstIndex(of: ">") else { return nil }
        let inner = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return inner.contains("@") ? inner.replacingOccurrences(of: "mailto:", with: "") : nil
    }

    /// Without "<...>", "(...)", and "[...]".
    private static func withoutBrackets(_ text: String) -> String {
        var out = "", depth = 0
        for c in text {
            if "<([".contains(c) { depth += 1 } else if ">)]".contains(c) { depth = max(0, depth - 1) } else if depth == 0 { out.append(c) }
        }
        return out
    }

    /// A word of three letters or more, all in capitals.
    private static func isCapitals(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        return letters.count >= 3 && letters.allSatisfy(\.isUppercase)
    }

    private static func hasLowercase(_ word: String) -> Bool { word.contains { $0.isLetter && $0.isLowercase } }

    public static func parse(_ raw: String) -> ParsedName {
        var out = ParsedName(given: nil, middle: [], family: nil, suffix: nil, order: .none, raw: raw, isName: false)
        let text = withoutBrackets(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        // "Speaker C" is a label, and an address goes to the email rule.
        guard !text.isEmpty, !text.contains("@"), !text.hasPrefix("Speaker ") else { return out }
        var parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !key($0).isEmpty }
        // "Carter, Sam, PhD": a last part that is a suffix is not a name part.
        while parts.count > 1, let last = parts.last, suffixes.contains(key(last)) {
            out.suffix = key(last)
            parts.removeLast()
        }
        guard !parts.isEmpty else { return out }

        func tokens(_ part: String) -> [String] { part.split(whereSeparator: \.isWhitespace).map(String.init).filter { !key($0).isEmpty } }
        /// Removes a title at the start and a suffix at the end, while two words stay.
        func trimmed(_ words: [String]) -> [String] {
            var words = words
            while words.count > 2, let last = words.last, suffixes.contains(key(last)) {
                out.suffix = key(last)
                words.removeLast()
            }
            while words.count > 1, let first = words.first, titles.contains(key(first)) { words.removeFirst() }
            return words
        }

        if parts.count >= 2 {
            let family = tokens(parts[0]), rest = trimmedGiven(tokens(parts[1]))
            guard !family.isEmpty, let given = rest.first else { return out }
            out.family = family.map(key).joined(separator: " ")
            out.given = key(given)
            out.middle = rest.dropFirst().map(key)
            out.order = .comma
            out.isName = true
            return out
        }

        let words = trimmed(tokens(parts[0]))
        guard let first = words.first else { return out }
        out.isName = true
        guard words.count > 1 else {
            out.given = key(first)
            return out
        }
        // A family name in capitals next to a first name that is not.
        let capitals = words.map(isCapitals)
        if capitals.contains(true), words.contains(where: hasLowercase) {
            let lead = capitals.prefix { $0 }.count, tail = capitals.reversed().prefix { $0 }.count
            if lead > 0, lead < words.count, !capitals[lead...].contains(true) {
                out.family = words[..<lead].map(key).joined(separator: " ")
                out.given = key(words[lead])
                out.middle = words[(lead + 1)...].map(key)
                out.order = .capitals
                return out
            }
            if tail > 0, tail < words.count, !capitals[..<(words.count - tail)].contains(true) {
                out.family = words[(words.count - tail)...].map(key).joined(separator: " ")
                out.given = key(first)
                out.middle = words[1..<(words.count - tail)].map(key)
                out.order = .capitals
                return out
            }
        }
        // First name first. A particle begins the family name: "Maria De La Cruz".
        let keys = words.map(key)
        let start = keys.indices.dropFirst().dropLast().first { particles.contains(keys[$0]) } ?? keys.count - 1
        out.given = keys[0]
        out.middle = Array(keys[1..<start])
        out.family = keys[start...].joined(separator: " ")
        return out
    }

    /// After a comma: a title before the first name and a suffix after it are not name parts.
    private static func trimmedGiven(_ words: [String]) -> [String] {
        var words = words
        while words.count > 1, let last = words.last, suffixes.contains(key(last)) { words.removeLast() }
        while words.count > 1, let first = words.first, titles.contains(key(first)) { words.removeFirst() }
        return words
    }

    /// Whether two lists of middle names can belong to one person: each pair is equal, or one is the initial of
    /// the other ("a", "allen").
    private static func middlesAgree(_ a: [String], _ b: [String]) -> Bool {
        zip(a, b).allSatisfy { x, y in x == y || (x.count == 1 && y.hasPrefix(x)) || (y.count == 1 && x.hasPrefix(y)) }
    }

    /// The reading with the first word as the family name, for a name of two words or more with no proof.
    private static func swapped(_ p: ParsedName) -> (given: String, middle: [String], family: String)? {
        let words = p.words
        guard p.order == .none, words.count >= 2 else { return nil }
        return (words[1], Array(words[2...]), words[0])
    }

    /// How the written name `a` relates to the name `b`. "Short" is one way: `a` is the short one.
    public static func fit(_ a: ParsedName, _ b: ParsedName) -> NameFit {
        guard a.isName, b.isName, let ag = a.given, let bg = b.given else { return .none }
        let firstFits = ag == bg || Nicknames.shortAndFull(ag, bg)
        guard let af = a.family else {
            return firstFits ? .short : .none
        }
        guard let bf = b.family else { return .none }
        // The same words in the same order: "Zoe Carter Reed" and "Zoë Carter-Reed".
        if a.words == b.words { return .same }
        if af == bf, firstFits {
            if !a.middle.isEmpty, !b.middle.isEmpty, !middlesAgree(a.middle, b.middle) { return .conflict }
            if ag != bg { return .nickname }
            return a.middle.isEmpty != b.middle.isEmpty ? .sameWithMiddle : .same
        }
        // "Sam C." for Sam Carter.
        if af.count == 1, bf.hasPrefix(af), firstFits, a.middle.isEmpty { return .short }
        for (one, other) in [(swapped(a), b), (swapped(b), a)] {
            guard let one, let og = other.given, let of = other.family, one.given == og, one.family == of,
                  one.middle.isEmpty || other.middle.isEmpty || middlesAgree(one.middle, other.middle) else { continue }
            return .swapped
        }
        return .none
    }
}
