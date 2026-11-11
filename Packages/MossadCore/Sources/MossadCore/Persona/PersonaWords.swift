import Foundation

/// The rules for the words of a trait, checked by code before a sentence is saved:
/// - a verb of an act that you can hear (asks, says, decides), not "is", "feels", or an adjective of character;
/// - no topic term, no number, and no third person's name: the topic stays in the evidence;
/// - no type, diagnosis, protected trait, feeling, or motive;
/// - 20 words at most, and a "so do this" of 16 words at most.
public enum PersonaWords {
    public static let statementWords = 20
    public static let soDoThisWords = 16

    /// Verbs of acts that a transcript shows, in their third-person form.
    static let acts: Set<String> = [
        "asks", "says", "decides", "returns", "interrupts", "names", "agrees", "objects", "questions", "requests", "wants", "needs",
        "tests", "checks", "challenges", "pushes", "proposes", "suggests", "sends", "replies", "answers", "explains", "opens", "starts",
        "cuts", "waits", "stops", "brings", "compares", "refers", "defers", "involves", "looks", "accepts", "rejects", "declines",
        "approves", "commits", "follows", "takes", "gives", "talks", "speaks", "listens", "summarizes", "repeats", "praises", "thanks",
        "goes", "moves", "raises", "frames", "points", "presses", "probes", "digs", "drills", "focuses", "steers", "leads", "closes",
        "confirms", "insists", "counters", "doubts", "holds", "puts", "lists", "walks", "uses", "keeps", "makes", "sets", "turns",
        "expects", "prefers", "chooses", "picks", "drops", "skips", "flags", "admits", "reports", "shares", "comes", "runs", "offers",
        "agree", "ask", "say", "decide", "object",
    ]

    /// Words that never go into a trait: types, diagnosis, protected traits and their stand-ins, feelings and
    /// motives, verdicts on character, and tactics against a person.
    /// A word ends a match at a word's edge; "*" marks a stem ("manipulat*"); a phrase has a space.
    static let banned: [String] = [
        "mbti", "introvert", "extrovert", "extravert", "intj", "entj", "infp", "enneagram", "big five", "neurotic*", "skeptic", "follower",
        "charismatic", "narcissis*", "anxious", "anxiety", "insecure", "insecurity", "passive-aggressive", "passive aggressive", "spectrum",
        "autis*", "adhd", "depress*", "bipolar", "ocd", "paranoid", "mental", "mentally", "diagnos*", "disorder", "therapy", "health", "sick",
        "illness", "pregnan*", "disabled", "disability", "family", "kids", "children", "wife", "husband", "divorce*", "religio*", "church",
        "faith", "accent", "native speaker", "foreign", "ethnic*", "race", "racial", "gender", "woman", "man", "female", "male", "age",
        "old", "young", "elderly", "millennial", "boomer", "culture", "cultural", "nationality", "sexual*", "political", "politics",
        "emotional*", "feels", "feeling", "afraid", "fear*", "angry", "frustrat*", "upset", "happy", "sad", "nervous", "stressed",
        "ego", "wants to look", "look good", "likes you", "does not like", "dislikes", "hates", "lazy", "stupid", "incompetent", "weak",
        "dishonest", "liar", "lies", "manipulat*", "easy to push", "pushover", "push around", "exploit*", "weakness", "conflict-averse",
        "conflict averse", "difficult", "toxic", "aggressive", "arrogant", "rude",
    ]

    /// The first banned word or phrase in a text, at a word's edge.
    static func bannedWord(in text: String) -> String? {
        let lower = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let tokens = lower.split { !$0.isLetter && $0 != "-" && $0 != "'" }.map(String.init)
        let spaced = " " + tokens.joined(separator: " ") + " "
        for entry in banned {
            if entry.contains(" ") {
                if spaced.contains(" \(entry) ") { return entry }
            } else if entry.hasSuffix("*") {
                let stem = String(entry.dropLast())
                if tokens.contains(where: { $0.hasPrefix(stem) }) { return entry }
            } else if tokens.contains(entry) {
                return entry
            }
        }
        return nil
    }

    static let stateVerbs: Set<String> = ["is", "are", "was", "were", "seems", "feels", "appears"]

    /// The reasons a sentence fails, empty when it passes. `topicTerms` are words of the calls' titles and tags;
    /// `names` are other people's names (first names and whole names).
    public static func problems(statement: String, soDoThis: String, topicTerms: Set<String> = [], names: Set<String> = [], person: String = "") -> [String] {
        var out: [String] = []
        let words = statement.split(whereSeparator: \.isWhitespace)
        if words.isEmpty { out.append("empty") }
        if words.count > statementWords { out.append("long") }
        if soDoThis.split(whereSeparator: \.isWhitespace).count > soDoThisWords || soDoThis.nonBlank == nil { out.append("so do this") }
        let both = statement + " " + soDoThis
        if both.contains(where: \.isNumber) { out.append("number") }
        if let word = bannedWord(in: both) { out.append("banned: \(word)") }
        let tokens = statement.lowercased().split { !$0.isLetter && $0 != "'" && $0 != "-" }.map(String.init)
        if !tokens.contains(where: { acts.contains($0) }) { out.append("no act") }
        // "Sam is direct": a state verb right after the subject, with no act in the sentence, is a verdict.
        if let first = tokens.firstIndex(where: { stateVerbs.contains($0) }), !tokens[..<first].contains(where: { acts.contains($0) }),
           !tokens[first...].dropFirst().prefix(1).contains(where: { ["given", "asked", "shown", "told", "offered", "presented"].contains($0) }) {
            out.append("state")
        }
        let content = Set((statement + " " + soDoThis).lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let topics = topicTerms.map { $0.lowercased() }.filter { $0.count >= 4 && !common.contains($0) }
        if let t = topics.first(where: { content.contains($0) }) { out.append("topic: \(t)") }
        let own = Set(person.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        for name in names {
            let parts = name.lowercased().split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.count >= 2 && !own.contains($0) }
            if let hit = parts.first(where: { content.contains($0) }) { out.append("name: \(hit)"); break }
        }
        return out
    }

    public static func passes(statement: String, soDoThis: String, topicTerms: Set<String> = [], names: Set<String> = [], person: String = "") -> Bool {
        problems(statement: statement, soDoThis: soDoThis, topicTerms: topicTerms, names: names, person: person).isEmpty
    }

    /// Words of a title or a tag that are no topic: "weekly", "sync", "call".
    static let common: Set<String> = [
        "weekly", "sync", "call", "meeting", "with", "and", "the", "for", "review", "update", "check", "chat", "team", "monthly", "daily",
        "standup", "catch", "plan", "planning", "about", "from", "into", "next", "last", "first", "this", "that", "your", "their", "time",
        "quick", "follow", "talk", "number", "numbers", "answer", "data", "risk", "cost", "costs", "customer", "customers", "quality",
        "owner", "decision", "decide", "options", "trial", "detail", "details", "question", "questions", "proposal", "change", "changes",
        "before", "after", "options", "early", "later", "group", "room", "notice",
    ]

    /// The words of the calls' titles and tags, as topic terms.
    public static func topicTerms(_ records: [CallRecord]) -> Set<String> {
        var out: Set<String> = []
        for r in records {
            for text in [r.title] + r.tags + r.topics.map(\.title) {
                for w in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where w.count >= 4 { out.insert(String(w)) }
            }
        }
        return out
    }
}
