import Foundation

/// The behaviors the coach speaks about, as a fixed list of keys. The model tags each piece of advice with one
/// key, the schema allows no other, and the same key is the same advice whatever the words are. A behavior that
/// no key fits is `other` with a short label.
///
/// Add a key at the end and raise `version`: a memory with an older version is read against the list again.
public enum CoachSkill: String, Codable, Sendable, CaseIterable {
    case commitmentDates = "commitment-dates"
    case answerFirst = "answer-first"
    case roomInOneOnOnes = "room-in-1on1s"
    case longTurns = "long-turns"
    case questions
    case interruptions
    case closingWithNextSteps = "closing-with-next-steps"
    case pace
    case fillerWords = "filler-words"
    case other

    public static let version = 1

    /// The name the owner reads.
    public var title: String {
        switch self {
        case .commitmentDates: "Give a day with each commitment"
        case .answerFirst: "Answer first"
        case .roomInOneOnOnes: "Room in 1:1s"
        case .longTurns: "Shorter turns"
        case .questions: "Ask before you tell"
        case .interruptions: "Let people finish"
        case .closingWithNextSteps: "Close with next steps"
        case .pace: "Pace"
        case .fillerWords: "Filler words"
        case .other: "Other"
        }
    }

    /// What the key covers, for the model.
    var hint: String {
        switch self {
        case .commitmentDates: "a day or a date for what they promise, take, or hand over"
        case .answerFirst: "the answer or the ask before the background"
        case .roomInOneOnOnes: "talk less and let the other person lead in a 1:1"
        case .longTurns: "shorter turns in any meeting"
        case .questions: "ask before telling; ask the question that matters"
        case .interruptions: "let people finish; give the floor back"
        case .closingWithNextSteps: "end a topic or a meeting with owners and next steps"
        case .pace: "speed of speech"
        case .fillerWords: "um, uh, and similar"
        case .other: "anything else, named in skill_label"
        }
    }

    /// The number the app counts for a skill, when it has one.
    public var measure: CoachMeasure? { self == .commitmentDates ? .commitmentDay : nil }

    /// The owner does not want these coached: a note about them is dropped. Pace is coached only as a focus.
    var isCoached: Bool { self != .fillerWords && self != .pace }

    /// The skill of an id: "commitment-dates", or `other` for "other:name the risk". Nil for a line that is
    /// not about a skill, such as "number:talkShare".
    public init?(id: String) {
        if let known = CoachSkill(rawValue: id) { self = known } else if id.hasPrefix("other:") { self = .other } else { return nil }
    }

    /// One text for a skill, as the log compares it: the key, or "other:" and the label without case and
    /// punctuation. A label that the list has a key for becomes that key, so "other: date your items" is
    /// "commitment-dates". An unknown key is `other`.
    public static func id(key: String?, label: String?, text: String = "") -> String {
        if let key, let known = CoachSkill(rawValue: key.trimmingCharacters(in: .whitespaces).lowercased()), known != .other { return known.rawValue }
        let name = label?.nonBlank ?? text
        if let known = infer(name) { return known.rawValue }
        return "other:" + AdviceRules.key(name)
    }

    /// The name of an id for the owner: the key's title, or the label of an `other`.
    public static func title(of id: String) -> String {
        if let known = CoachSkill(rawValue: id), known != .other { return known.title }
        let label = id.hasPrefix("other:") ? String(id.dropFirst(6)) : id
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    // MARK: Older reviews

    /// Words that name a day by themselves.
    private static let dates: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "tomorrow", "date", "dates",
                                             "dated", "deadline", "deadlines", "due"]
    /// What a "day" is for: a day in "the other day" is not a commitment.
    private static let promised: Set<String> = [
        "item", "items", "commitment", "commitments", "commit", "promise", "promises", "take", "taking", "took", "own", "owner", "owners", "action",
        "actions", "task", "tasks", "deliver", "send", "hand", "handing", "assign", "follow", "yours", "piece", "work", "claim", "pick", "accept", "give",
        // What the owner does with the day: "say your part, and then the day".
        "say", "name", "state", "tell", "add", "attach", "put",
    ]

    /// The key for advice that was written before the list, from its words, by fixed rules. Nil when no rule
    /// fits; such advice is an `other` of its own. The rules are in order: a day for an item is
    /// `commitmentDates` also when the sentence speaks of the end of the meeting.
    static func infer(_ text: String) -> CoachSkill? {
        let plain = " " + AdviceRules.key(text) + " "
        let words = Set(plain.split(separator: " ").map(String.init))
        func has(_ phrases: String...) -> Bool { phrases.contains { plain.contains(" \($0) ") || plain.contains(" \($0)s ") } }
        if !words.isDisjoint(with: dates) || has("by when", "end of week", "end of the week", "end of day") { return .commitmentDates }
        if has("with a day", "with the day", "say the day", "name the day", "give a day", "give the day", "which day", "what day") { return .commitmentDates }
        if has("day"), !words.isDisjoint(with: promised), !has("every day", "all day", "other day", "one day", "same day") { return .commitmentDates }
        if has("next step", "recap", "wrap up", "before the call ends", "before the meeting ends", "close the meeting", "close the call", "end the meeting",
               "end the call", "who owns", "name the owner", "name an owner") { return .closingWithNextSteps }
        if has("interrupt", "interrupting", "cut in", "cutting in", "talk over", "talks over", "talking over", "let them finish", "finish the sentence", "floor back") { return .interruptions }
        if has("answer first", "bottom line", "lead with", "start with the answer", "the answer first", "conclusion first", "headline first", "the ask first",
               "open with the answer", "say the answer") { return .answerFirst }
        if has("1 1", "one on one", "talk less", "let them lead", "more room", "talk share", "leave room", "make room") { return .roomInOneOnOnes }
        if has("shorter turn", "long turn", "monologue", "two minutes", "2 minutes", "stop after", "pause after") { return .longTurns }
        if has("slow down", "slower", "pace", "words per minute") { return .pace }
        if has("filler", "um", "uh") { return .fillerWords }
        if has("ask", "asking", "question") { return .questions }
        return nil
    }
}
