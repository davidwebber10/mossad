import XCTest
@testable import MossadCore

/// Whether a coach's card is about another person, for the places where the reads of people may not go. An error
/// must remove a card, never keep one; a one-word name in the coach's words is a name only with a capital letter.
final class FindingAboutTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)
    private let owner = OwnerIdentity(name: "Avery Webb")

    private func person(_ id: String, _ name: String, owner: Bool = false) -> Person {
        Person(id: PersonID(rawValue: id), displayName: name, isOwner: owner, origin: owner ? .owner : .migration, at: at)
    }

    private var people: [Person] {
        var robert = person("id-robert", "Robert Lane")
        _ = robert.addForm("Lane, Robert", kind: .seen, source: .migration, confirmed: true, at: at)
        _ = robert.addForm("Robbie Q", kind: .nickname, source: .migration, confirmed: true, at: at)
        return [person("id-owner", "Avery Webb", owner: true), robert, person("id-sam", "Sam Carter"), person("id-will", "Will Grant"),
                person("id-avery", "Avery Stone"), person("id-jose", "José Núñez"), person("id-may", "May Chen"), person("id-linh", "Linh Tô"),
                person("id-dangelo", "D'Angelo Russell"), person("id-jr", "J.R. Smith"), person("id-tj", "T.J. Watt"),
                person("id-jackson", "Mia Jackson")]
    }

    private func card(text: String = "Say the day when you take an item.", number: String? = nil, usual: String? = nil, say: String? = nil,
                      quote: String? = nil) -> CoachFinding {
        CoachFinding(id: "c", callID: "call", date: at, kind: .couldBeBetter, text: text, skill: "commitment-dates", quote: quote, number: number,
                     usual: usual, say: say)
    }

    private func about(_ c: CoachFinding, voices: [String] = [], people: [Person]? = nil) -> Bool {
        FindingAbout.person(c, question: nil, names: FindingAbout.names(people: people ?? self.people, voices: voices), isOwner: owner.isOwner)
    }

    func testTheTable() {
        let rows: [(String, CoachFinding, Bool)] = [
            ("the owner's own behavior", card(), false),
            ("a number with no name", card(text: "You talked most.", number: "81%", usual: "Usually 62 to 70%"), false),
            ("a nickname", card(text: "Ask Bob before you decide."), true),
            ("a written form's nickname", card(text: "Ask Robbie first."), true),
            ("a last name alone", card(text: "Carter waited for an answer."), true),
            ("a name in the usual value", card(text: "You talked most.", number: "81%", usual: "Usually 62 to 70% in your 1:1s with Sam"), true),
            ("a name in the words to say", card(say: "Go on, Will."), true),
            ("a name in the quote", card(text: "You cut in.", quote: "Sam, let me stop you there"), true),
            ("a common word as a first name, at the start of a sentence", card(text: "Will you send the plan by Friday?"), true),
            ("a common word as a first name, as a name", card(text: "Will asked first."), true),
            ("a common word as a first name, in the middle", card(text: "Next time, ask May about it."), true),
            ("a common word in lower case", card(text: "Say what you will do by Friday."), false),
            ("a common word in lower case, may", card(text: "You may want to ask first."), false),
            ("a name that is a short word", card(text: "Give them time to answer."), false),
            ("the owner's first name on another person", card(text: "Avery, say the day."), true),
            ("a name without its accents", card(text: "Thank Jose Nunez for the numbers."), true),
            ("a whole name in lower case", card(text: "you could thank jose nunez."), true),
            ("a name with an apostrophe", card(text: "Let D'Angelo finish."), true),
            ("initials", card(text: "J.R. waited for an answer."), true),
            ("initials in the middle", card(text: "Ask T.J. first."), true),
            ("no short form of a last name", card(text: "Ask Jack first."), false),
            ("a voice of the call that is no saved person", card(text: "Let Jordan finish."), false),
        ]
        for (label, c, expected) in rows { XCTAssertEqual(about(c), expected, label) }
        XCTAssertTrue(about(card(text: "Let Jordan finish."), voices: ["Jordan Price"]), "a voice of the call")
    }

    /// The rule before this one compared the whole name and the first word as split at spaces, in any case. For names
    /// written as names, nothing it removed is kept now.
    func testNothingTheOldRuleRemovedIsKept() {
        func old(_ text: String, _ name: String) -> Bool {
            let words = [name] + (name.split(separator: " ").first.map { [String($0)] } ?? [])
            return words.contains { w in
                text.range(of: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: w) + "(?![\\p{L}\\p{N}])",
                           options: [.regularExpression, .caseInsensitive]) != nil
            }
        }
        let names = ["D'Angelo Russell", "J.R. Smith", "T.J. Watt", "Sam Carter", "Will Grant", "May Chen", "José Núñez", "O'Brien Pat", "Mary-Kate Olsen"]
        let texts = ["Let D'Angelo finish.", "J.R. waited for an answer.", "Ask T.J. first.", "Sam waited.", "Ask Sam Carter.", "Will asked first.",
                     "Thank José.", "O'Brien waited.", "Ask Mary-Kate first.", "Next time, ask May about it.", "Give Sam Carter room."]
        for name in names {
            let one = [person("id-x", name)]
            for text in texts where old(text, name) {
                XCTAssertTrue(about(card(text: text), people: one), "\(name): \(text)")
            }
        }
    }

    /// The forms are made one time for the rule: 2,000 names and 150 cards take well under a second.
    func testTheRuleIsFastForManyNamesAndCards() {
        let names = (0..<2_000).map { "Given\($0) Family\($0)" }
        let rule = FindingAbout.Rule(names: names, isOwner: owner.isOwner)
        let cards = (0..<150).map { card(text: "Card \($0): say the day when you take an item.", usual: "Usually 3 to 4 a meeting") }
        let start = Date()
        var count = 0
        for c in cards where rule.about(c, question: nil) { count += 1 }
        XCTAssertEqual(count, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        XCTAssertTrue(rule.about(card(text: "Ask Given1999 first."), question: nil))
    }

    func testAConclusionWithNoQuestionOrAboutSomeoneIsAboutAPerson() {
        let c = CoachFinding(id: "q", callID: "call", date: at, kind: .learning, text: "This call sets the plan.", skill: "")
        XCTAssertTrue(FindingAbout.person(c, question: nil, names: [], isOwner: owner.isOwner), "unknown is about a person")
        var q = CoachQuestion(statement: "This call sets the plan.", kind: .thisCall, evidence: "e", callID: "call", at: 1, asked: at)
        XCTAssertFalse(FindingAbout.person(c, question: q, names: [], isOwner: owner.isOwner))
        q.about = "Jordan"
        XCTAssertTrue(FindingAbout.person(c, question: q, names: [], isOwner: owner.isOwner))
    }
}
