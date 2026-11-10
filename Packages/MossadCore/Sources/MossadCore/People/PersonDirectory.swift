import Foundation

/// The saved people, for turning a name or an email written in a meeting into the person it stands for.
///
/// There are two questions, with two answers. `link` says whose profile a click on the name opens: only a sure
/// match, because a wrong profile is worse than no link. `match` says which saved person an invited name is: it
/// may read a short form, but only among the people of the meeting, and only when one of them fits.
public struct PersonDirectory: Sendable, Equatable {
    public struct Person: Sendable, Equatable {
        public var name: String
        public var email: String?

        public init(name: String, email: String?) {
            self.name = name
            self.email = email
        }
    }

    public let people: [Person]
    private let byEmail: [String: String]
    /// Nil for a name that two saved people have.
    private let byName: [String: String?]

    public init(_ people: [Person] = []) {
        self.people = people
        byEmail = Dictionary(people.compactMap { p in p.email.map { (Self.emailKey($0), p.name) } }, uniquingKeysWith: { a, _ in a })
        var byName: [String: String?] = [:]
        for p in people {
            let key = PeopleDuplicates.normalized(p.name)
            byName[key] = byName[key] == nil ? .some(p.name) : .some(nil)
        }
        self.byName = byName
    }

    public init(profiles: [VoiceProfile]) {
        self.init(profiles.map { Person(name: $0.name, email: $0.email) })
    }

    private static func emailKey(_ email: String) -> String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// Lowercase words without the period of an initial: "Sam C." gives "sam", "c".
    private static func words(_ name: String) -> [String] {
        name.lowercased().split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }.filter { !$0.isEmpty }
    }

    /// The one saved person with exactly this name, in any case and spacing.
    private func exact(_ text: String) -> String? { byName[PeopleDuplicates.normalized(text)] ?? nil }

    /// Whether `written` can be a form of the name `full`: the same first name or its short form, and, when
    /// `written` has more words, the same last name or its initial.
    private static func fits(_ written: [String], _ full: [String]) -> Bool {
        guard let first = written.first, let theirFirst = full.first, first == theirFirst || Nicknames.shortAndFull(first, theirFirst) else { return false }
        guard written.count > 1, let last = written.last else { return true }
        guard full.count > 1, let theirLast = full.last else { return false }
        return last == theirLast || (last.count == 1 && theirLast.hasPrefix(last))
    }

    /// Whether a name as someone wrote it ("Sam", "Sam C.") can stand for the full name `full`. A label such as
    /// "Speaker C" and an email are not names.
    public static func isForm(_ written: String, of full: String) -> Bool {
        guard !written.contains("@"), !written.hasPrefix("Speaker ") else { return false }
        let short = words(written)
        return !short.isEmpty && fits(short, words(full))
    }

    // MARK: Links

    /// The saved person whose profile `text` may open: the person with that email, or the one saved person with
    /// exactly that name of two words or more. A first name, a short form, an initial, or a person saved under
    /// one word ("Sam") opens nothing.
    public func link(for text: String, in meeting: [String] = []) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("@") { return byEmail[Self.emailKey(text)] }
        // "Speaker C" is a label, not a name.
        guard !text.hasPrefix("Speaker "), let person = exact(text) else { return nil }
        // A name of one word is never sure: another person with that first name can be invited by email only, or
        // be a voice with no name, and neither shows in the meeting's names.
        return Self.words(text).count > 1 ? person : nil
    }

    // MARK: Matching

    /// The saved person that an invited name or email is. In this order: their email; the one saved person with
    /// exactly that name of two words or more; then, only among `meeting` (the speakers and the other invited
    /// people, saved or not), the one person the name can be a form of ("Sam" or "Sam C." for Sam Carter, "Sam
    /// Reed" for Samuel Reed), when that person is saved. Two who fit, or one who is not saved, is nobody.
    public func match(_ text: String, among meeting: [String] = []) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("@") { return byEmail[Self.emailKey(text)] }
        guard !text.hasPrefix("Speaker ") else { return nil }
        let words = Self.words(text)
        guard !words.isEmpty else { return nil }
        if words.count > 1, let person = exact(text) { return person }
        var seen: Set<String> = []
        let near = meeting.filter { name in
            guard !name.contains("@"), !name.hasPrefix("Speaker "), seen.insert(PeopleDuplicates.normalized(name)).inserted else { return false }
            // The text itself, as an invited entry, is not a second person.
            return Self.fits(words, Self.words(name)) && (PeopleDuplicates.normalized(name) != PeopleDuplicates.normalized(text) || exact(name) != nil)
        }
        if near.count == 1 { return exact(near[0]) }
        // A person saved under one word, in a meeting where nobody else can be meant.
        return near.isEmpty && words.count == 1 ? exact(text) : nil
    }
}
