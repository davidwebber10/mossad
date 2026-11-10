import Foundation

/// The saved people, for turning a name or an email written in a meeting into the person it stands for. The
/// meeting page links a name to a profile only when this finds one person, never a guess between two.
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
    private let byName: [String: String]

    public init(_ people: [Person] = []) {
        self.people = people
        byEmail = Dictionary(people.compactMap { p in p.email.map { (Self.emailKey($0), p.name) } }, uniquingKeysWith: { a, _ in a })
        byName = Dictionary(people.map { (PeopleDuplicates.normalized($0.name), $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    public init(profiles: [VoiceProfile]) {
        self.init(profiles.map { Person(name: $0.name, email: $0.email) })
    }

    private static func emailKey(_ email: String) -> String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// The saved person for `text`, in this order: their email; their name in any case and spacing; a short form
    /// of their name ("Sam Reed" for "Samuel Reed", "Sam C." for "Sam Carter"). A first name alone ("Sam") only
    /// matches a person in `context` (the meeting's speakers and invited people), and only when one of them fits.
    public func person(for text: String, among context: [String] = []) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("@") { return byEmail[Self.emailKey(text)] }
        if let exact = byName[PeopleDuplicates.normalized(text)] { return exact }
        // "Speaker C" is a label, not a name.
        guard !text.hasPrefix("Speaker ") else { return nil }
        let words = Self.words(text)
        guard let first = words.first else { return nil }
        let fits = people.filter { p in
            let theirs = Self.words(p.name)
            guard let theirFirst = theirs.first, theirFirst == first || Nicknames.related(theirFirst, first) else { return false }
            guard words.count > 1, let last = words.last else { return true }
            guard theirs.count > 1, let theirLast = theirs.last else { return false }
            return last == theirLast || (last.count == 1 && theirLast.hasPrefix(last))
        }
        let inContext = Set(context.map(PeopleDuplicates.normalized))
        let near = fits.filter { inContext.contains(PeopleDuplicates.normalized($0.name)) }
        if near.count == 1 { return near[0].name }
        // A first name alone needs the meeting to say who it is. So does a name that fits two people.
        guard near.isEmpty, words.count > 1, fits.count == 1 else { return nil }
        return fits[0].name
    }

    /// Lowercase words without the period of an initial: "Sam C." gives "sam", "c".
    private static func words(_ name: String) -> [String] {
        name.lowercased().split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }.filter { !$0.isEmpty }
    }
}
