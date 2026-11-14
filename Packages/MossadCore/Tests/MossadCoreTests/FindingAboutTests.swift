import XCTest
@testable import MossadCore

/// Whether a coach's card is about another person, for the places where the reads of people may not go. An error
/// must remove a card, never keep one.
final class FindingAboutTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private var people: [Person] {
        var robert = Person(id: PersonID(rawValue: "id-robert"), displayName: "Robert Lane", origin: .migration, at: at)
        _ = robert.addForm("Lane, Robert", kind: .seen, source: .migration, confirmed: true, at: at)
        _ = robert.addForm("Robbie Q", kind: .nickname, source: .migration, confirmed: true, at: at)
        return [Person(id: PersonID(rawValue: "id-owner"), displayName: "Avery Webb", isOwner: true, origin: .owner, at: at), robert,
                Person(id: PersonID(rawValue: "id-sam"), displayName: "Sam Carter", origin: .migration, at: at),
                Person(id: PersonID(rawValue: "id-will"), displayName: "Will Grant", origin: .migration, at: at),
                Person(id: PersonID(rawValue: "id-avery"), displayName: "Avery Stone", origin: .migration, at: at),
                Person(id: PersonID(rawValue: "id-jose"), displayName: "José Núñez", origin: .migration, at: at)]
    }

    private func card(text: String = "Say the day when you take an item.", number: String? = nil, usual: String? = nil, say: String? = nil) -> CoachFinding {
        CoachFinding(id: "c", callID: "call", date: at, kind: .couldBeBetter, text: text, skill: "commitment-dates", number: number, usual: usual, say: say)
    }

    private func about(_ c: CoachFinding, voices: [String] = []) -> Bool {
        let owner = OwnerIdentity(name: "Avery Webb")
        return FindingAbout.person(c, question: nil, names: FindingAbout.names(people: people, voices: voices), isOwner: owner.isOwner)
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
            ("a common word that is a first name", card(text: "Will you send the plan by Friday?"), true),
            ("the owner's first name on another person", card(text: "Avery, say the day."), true),
            ("a name without its accents", card(text: "Thank Jose Nunez for the numbers."), true),
            ("a voice of the call that is no saved person", card(text: "Let Jordan finish."), false),
        ]
        for (label, c, expected) in rows { XCTAssertEqual(about(c), expected, label) }
        XCTAssertTrue(about(card(text: "Let Jordan finish."), voices: ["Jordan Price"]), "a voice of the call")
    }

    func testAConclusionWithNoQuestionOrAboutSomeoneIsAboutAPerson() {
        let owner = OwnerIdentity(name: "Avery Webb")
        let c = CoachFinding(id: "q", callID: "call", date: at, kind: .learning, text: "This call sets the plan.", skill: "")
        XCTAssertTrue(FindingAbout.person(c, question: nil, names: [], isOwner: owner.isOwner), "unknown is about a person")
        var q = CoachQuestion(statement: "This call sets the plan.", kind: .thisCall, evidence: "e", callID: "call", at: 1, asked: at)
        XCTAssertFalse(FindingAbout.person(c, question: q, names: [], isOwner: owner.isOwner))
        q.about = "Jordan"
        XCTAssertTrue(FindingAbout.person(c, question: q, names: [], isOwner: owner.isOwner))
    }
}
