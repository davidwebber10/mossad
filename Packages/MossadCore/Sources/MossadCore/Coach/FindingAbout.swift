import Foundation

/// Whether a coach's card is about a person other than the owner. Where the reads of people may not go (the switch
/// for other AI apps), no such card goes: a trait, a conclusion about someone, or a card whose words name another
/// person. Pure. Each unknown is about a person: a conclusion whose question is gone removes a card. A name of one
/// word is a name in the coach's words only with a capital letter ("Will asked", not "you will"); a capital at the
/// start of a sentence or a word in capitals still removes a card, the safe side.
public enum FindingAbout {
    /// The names a card's words may hold: each written form of each saved person other than the owner, and the
    /// call's voices.
    public static func names(people: [Person], voices: [String]) -> [String] {
        people.filter { !$0.isOwner && $0.deleted == nil }.flatMap { [$0.displayName] + $0.forms.map(\.text) } + voices
    }

    /// The forms of a set of names, made one time and read for each card.
    public struct Rule {
        /// One word of letters and numbers: found as a word of the card that starts with a capital letter.
        let words: Set<String>
        /// A form of more words, or with a character that is no letter or number ("J.R.", "D'Angelo"), by its first
        /// run of letters: found in any case, as a whole.
        let phrases: [String: [String]]
        let isOwner: (String) -> Bool

        public init(names: [String], isOwner: @escaping (String) -> Bool) {
            self.isOwner = isOwner
            var words = Set<String>(), phrases: [String: Set<String>] = [:]
            for name in Set(names) where !FindingAbout.mine(name, isOwner) {
                for form in FindingAbout.forms(of: name) where form.count >= 2 {
                    if form.allSatisfy({ $0.isLetter || $0.isNumber }) { words.insert(form) }
                    else if let key = FindingAbout.runs(form).first { phrases[key, default: []].insert(form) }
                }
            }
            self.words = words
            self.phrases = phrases.mapValues(Array.init)
        }

        public func about(_ card: CoachFinding, question: CoachQuestion?) -> Bool {
            FindingAbout.byKind(card, question: question, isOwner: isOwner) || names(in: card)
        }

        /// Whether the card's words hold one of the names.
        public func names(in card: CoachFinding) -> Bool {
            let raw = [card.text, card.say, card.why, card.detail, card.number, card.usual, card.quote].compactMap { $0 }.joined(separator: "\n")
                .folding(options: .diacriticInsensitive, locale: nil)
            var any = Set<String>()
            for run in FindingAbout.runs(raw, folded: false) {
                let lower = run.lowercased()
                if run.first?.isUppercase == true, words.contains(lower) { return true }
                any.insert(lower)
            }
            guard !phrases.isEmpty else { return false }
            let folded = raw.lowercased()
            for key in any { for p in phrases[key] ?? [] where FindingAbout.mentions(folded, p) { return true } }
            return false
        }
    }

    /// `names`: the other people's names (`names(people:voices:)`). `isOwner`: whether a name is the owner's own.
    public static func person(_ card: CoachFinding, question: CoachQuestion?, names: [String], isOwner: @escaping (String) -> Bool) -> Bool {
        Rule(names: names, isOwner: isOwner).about(card, question: question)
    }

    /// A trait, a card with a person, or a conclusion about someone (or with its question gone).
    static func byKind(_ card: CoachFinding, question: CoachQuestion?, isOwner: (String) -> Bool) -> Bool {
        if card.kind == .trait || card.person != nil { return true }
        guard card.kind == .learning else { return false }
        guard let q = question else { return true }
        if q.kind == .relationship || q.kind == .role { return true }
        if let about = q.about?.trimmingCharacters(in: .whitespaces), !about.isEmpty, !mine(about, isOwner) { return true }
        return false
    }

    static func mine(_ name: String, _ isOwner: (String) -> Bool) -> Bool {
        isOwner(name) || ["you", "me", "the owner", "owner"].contains(name.lowercased())
    }

    /// A name's forms, folded: the whole name; its first and last word as split at spaces ("J.R.", "D'Angelo"); its
    /// first and last run of letters; and the short forms of the first name only. In "Carter, Sam" the word after
    /// the comma is the first name.
    static func forms(of name: String) -> Set<String> {
        let whole = fold(name).trimmingCharacters(in: .whitespaces)
        let spaced = whole.split(separator: " ").map(String.init)
        var out: Set<String> = [whole]
        var first = spaced.first
        if let i = spaced.firstIndex(where: { $0.hasSuffix(",") }), i + 1 < spaced.count { first = spaced[i + 1] }
        for w in [spaced.first, spaced.last].compactMap({ $0 }) { out.insert(w.trimmingCharacters(in: CharacterSet(charactersIn: ","))) }
        let letters = runs(whole)
        if let a = letters.first { out.insert(a) }
        if let b = letters.last { out.insert(b) }
        if let first, let given = runs(first).first { out.formUnion(Nicknames.variants(of: given)) }
        return out.filter { !$0.isEmpty }
    }

    static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }

    /// The runs of letters and numbers of a text, folded unless `folded` is false.
    static func runs(_ s: String, folded: Bool = true) -> [String] {
        (folded ? fold(s) : s).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func mentions(_ text: String, _ name: String) -> Bool {
        guard text.contains(name) else { return false }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
