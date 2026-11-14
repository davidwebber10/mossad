import Foundation

/// Whether a coach's card is about a person other than the owner. Where the reads of people may not go (the switch
/// for other AI apps), no such card goes: a trait, a conclusion about someone, or a card on the owner's behavior whose
/// words name another person. Pure. Each unknown and each doubt is about a person: a conclusion whose question is
/// gone, and a name that is also a usual word ("Will"), remove a card; nothing keeps one.
public enum FindingAbout {
    /// The names a card's words may hold: each written form of each saved person other than the owner, and the
    /// call's voices.
    public static func names(people: [Person], voices: [String]) -> [String] {
        people.filter { !$0.isOwner && $0.deleted == nil }.flatMap { [$0.displayName] + $0.forms.map(\.text) } + voices
    }

    /// `names`: the other people's names (`names(people:voices:)`). `isOwner`: whether a name is the owner's own.
    public static func person(_ card: CoachFinding, question: CoachQuestion?, names: [String], isOwner: (String) -> Bool) -> Bool {
        if card.kind == .trait || card.person != nil { return true }
        func mine(_ name: String) -> Bool { isOwner(name) || ["you", "me", "the owner", "owner"].contains(name.lowercased()) }
        if card.kind == .learning {
            guard let q = question else { return true }
            if q.kind == .relationship || q.kind == .role { return true }
            if let about = q.about?.trimmingCharacters(in: .whitespaces), !about.isEmpty, !mine(about) { return true }
        }
        let words = fold([card.text, card.say, card.why, card.detail, card.number, card.usual].compactMap { $0 }.joined(separator: "\n"))
        return names.contains { name in
            guard !mine(name) else { return false }
            return forms(of: name).contains { $0.count >= 2 && mentions(words, $0) }
        }
    }

    /// A name, its first and last words, and the first word's nicknames ("Robert Lane": "robert", "lane", "bob").
    static func forms(of name: String) -> Set<String> {
        let parts = fold(name).split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var out: Set<String> = [fold(name)]
        if let first = parts.first {
            out.insert(first)
            out.formUnion(Nicknames.variants(of: first))
        }
        // "Carter, Sam" puts the last name first: both ends are names.
        if let last = parts.last { out.insert(last); out.formUnion(Nicknames.variants(of: last)) }
        return out
    }

    static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }

    static func mentions(_ text: String, _ name: String) -> Bool {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
