import Foundation

/// Whether a coach's card is about a person other than the owner. Where the reads of people may not go (the switch
/// for other AI apps), no such card goes: a trait, a conclusion about someone, or a card on the owner's behavior whose
/// words name another person. Pure. Unknown is about a person: a conclusion whose question is gone is left out.
public enum FindingAbout {
    /// `names`: the other people's names that the card's words may hold (saved people and the call's voices).
    /// `isOwner`: whether a name is the owner's own, which is not another person.
    public static func person(_ card: CoachFinding, question: CoachQuestion?, names: [String], isOwner: (String) -> Bool) -> Bool {
        if card.kind == .trait || card.person != nil { return true }
        let words = [card.text, card.say, card.why, card.detail].compactMap { $0 }.joined(separator: "\n")
        func mine(_ name: String) -> Bool { isOwner(name) || ["you", "me", "the owner", "owner"].contains(name.lowercased()) }
        if card.kind == .learning {
            guard let q = question else { return true }
            if q.kind == .relationship || q.kind == .role { return true }
            if let about = q.about?.trimmingCharacters(in: .whitespaces), !about.isEmpty, !mine(about) { return true }
        }
        return names.contains { name in
            guard !mine(name) else { return false }
            let parts = [name] + (name.split(separator: " ").first.map { [String($0)] } ?? [])
            return parts.contains { $0.count >= 2 && mentions(words, $0) }
        }
    }

    static func mentions(_ text: String, _ name: String) -> Bool {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
