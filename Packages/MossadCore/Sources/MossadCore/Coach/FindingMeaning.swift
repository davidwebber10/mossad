import Foundation

/// Why a card about the owner's behavior matters. A card that only says what happened is no insight, so:
///
/// 1. "Did well" names its skill and its effect, tied to evidence: the owner's goal, a skill key of `CoachSkill`,
///    or a number against its usual value. Without one of these it is not a card, also when the model wrote a why.
/// 2. "Did not do" and "Could be better" say what the miss costs, or the better way ("Say:"). Without either it
///    is not a card.
/// 3. The why is the model's when it wrote one. Else code takes it only from the link: the goal's own why, the
///    fixed effect of a skill key, or the fixed effect of a measured number. Code never writes a why of its own.
///
/// Conclusions, traits, and goal offers are not about behavior: they pass as they are.
public enum FindingMeaning {
    /// What a card's why stands on.
    public enum Link: Equatable, Sendable {
        case goal(CoachFocus)
        case number(String)
        case skill(CoachSkill)
    }

    /// The card with its why and its basis, or nil when it is not a card. `goals` are the owner's foci: a card
    /// is about a goal when its skill is the active one's, or when it names the focus by id.
    public static func settle(_ card: CoachFinding, goals: [CoachFocus]) -> CoachFinding? {
        guard card.kind.isBehavior else { return card }
        var card = card
        let link = link(of: card, goals: goals)
        let good = card.kind == .didWell
        if good, link == nil { return nil }
        card.why = card.why?.nonBlank ?? link.flatMap { why(of: $0, good: good) }
        card.basis = link.flatMap(basis)
        if good { return card.why == nil ? nil : card }
        return card.why == nil && card.say == nil ? nil : card
    }

    /// The goal first, then the number, then the skill: the strongest tie to evidence.
    static func link(of card: CoachFinding, goals: [CoachFocus]) -> Link? {
        let key = AdviceRules.key(card.skill)
        if card.skill.hasPrefix("focus:"), let goal = goals.first(where: { "focus:\($0.id.uuidString)" == card.skill }) { return .goal(goal) }
        if !key.isEmpty, let goal = goals.first(where: { $0.status == .active && AdviceRules.key($0.skillID) == key }) { return .goal(goal) }
        if card.usual != nil, let metric = metric(of: card.skill) { return .number(metric) }
        if let skill = CoachSkill(rawValue: card.skill), skill != .other { return .skill(skill) }
        return nil
    }

    /// "number:talkShare" and "progress:oneOnOneShare" are numbers with a known effect.
    static func metric(of skill: String) -> String? {
        let id = skill.hasPrefix("number:") ? String(skill.dropFirst(7)) : skill.hasPrefix("progress:") ? String(skill.dropFirst(9)) : nil
        guard let id else { return nil }
        let metric = id == "oneOnOneShare" ? PersonMetric.talkShare.rawValue : id
        return numberEffect(metric, good: true) == nil ? nil : metric
    }

    static func why(of link: Link, good: Bool) -> String? {
        switch link {
        // A goal of its own words: the plan the owner chose is the effect they want, and the better way.
        case .goal(let focus): CoachSkill(id: focus.skillID).flatMap { good ? $0.effect : $0.cost }
            ?? focus.plan.nonBlank.map { good ? "It is what your goal asks: \($0)" : "Your plan: \($0)" }
        case .number(let metric): numberEffect(metric, good: good)
        case .skill(let skill): good ? skill.effect : skill.cost
        }
    }

    static func basis(_ link: Link) -> String? {
        switch link {
        case .goal(let focus): "Your goal: \(CoachSkill.title(of: focus.skillID))"
        case .number: nil
        case .skill(let skill): skill.title
        }
    }

    /// What a number above or below its usual does, in the direction `FindingRules.kind(ofNumber:)` judges.
    static func numberEffect(_ metric: String, good: Bool) -> String? {
        switch metric {
        case PersonMetric.talkShare.rawValue:
            good ? "Less talk from you leaves the other person room to lead." : "More talk from you leaves the other person less room."
        case PersonMetric.longestTurn.rawValue, PersonMetric.averageTurn.rawValue:
            good ? "Shorter turns let the others come in." : "Long turns keep the others out of the talk."
        case PersonMetric.cutInsPerHour.rawValue:
            good ? "Fewer cut-ins let people finish their thought." : "A cut-in stops a thought before you hear all of it."
        default: nil
        }
    }
}

extension CoachSkill {
    /// What the skill does when the owner shows it: the why of praise that has no words of the model.
    public var effect: String? {
        switch self {
        case .commitmentDates: "A day lets others plan on it and shows when it is late."
        case .answerFirst: "People get your point before the detail, and can act on it."
        case .roomInOneOnOnes: "The other person gets room to lead and to say what they need."
        case .longTurns: "Short turns keep the others in the talk."
        case .questions: "A question first shows you what the other person needs."
        case .interruptions: "People finish their thought, so you hear all of it."
        case .closingWithNextSteps: "Everyone leaves with an owner and a next step."
        case .pace: "A steady pace is easy to follow."
        case .fillerWords: "Fewer filler words make you sound sure."
        case .other: nil
        }
    }

    /// What a miss of the skill costs: the why of advice that has no words of the model.
    public var cost: String? {
        switch self {
        case .commitmentDates: "Without a day, nobody can plan on it or tell when it is late."
        case .answerFirst: "With the background first, people wait for the point and can miss it."
        case .roomInOneOnOnes: "When you talk most of a 1:1, the other person has less room to lead."
        case .longTurns: "Long turns keep the others out of the talk."
        case .questions: "Telling before asking can miss what the other person needs."
        case .interruptions: "A cut-in stops a thought before you hear all of it."
        case .closingWithNextSteps: "Without owners and next steps, work can fall between people."
        case .pace: "A fast pace is hard to follow."
        case .fillerWords: "Filler words make you sound less sure."
        case .other: nil
        }
    }
}
