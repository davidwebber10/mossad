import XCTest
@testable import MossadCore

/// Fixed ids and dates, so a test reads as a table.
func testPerson(_ id: String, _ name: String, email: String? = nil, seenEmail: String? = nil, owner: Bool = false) -> Person {
    let at = Date(timeIntervalSince1970: 1_780_000_000)
    var p = Person(id: PersonID(rawValue: id), displayName: name, isOwner: owner, origin: .migration, at: at)
    if let email { p.addEmail(email, state: .verified, source: .owner, at: at) }
    if let seenEmail { p.addEmail(seenEmail, state: .seen, source: .calendar, at: at) }
    return p
}

/// One test for each rule, the order of the rules, and the three conflict rules.
final class PersonResolverTests: XCTestCase {
    private let sam = PersonID(rawValue: "sam"), dana = PersonID(rawValue: "dana"), reed = PersonID(rawValue: "reed")
    private var people: [Person] {
        [testPerson("sam", "Sam Carter", email: "sam.carter@example.com"), testPerson("dana", "Dana Lee", seenEmail: "dana@example.com"),
         testPerson("reed", "Michael Reed"), testPerson("jo", "Jo")]
    }
    private var resolver: PersonResolver { PersonResolver(people: people) }

    private func resolve(_ name: String? = nil, email: String? = nil, roster: [PersonID]? = nil, others: [String] = [], in people: [Person]? = nil) -> Resolution {
        PersonResolver(people: people ?? self.people).resolve(Observation(name: name, email: email), in: roster.map { ResolutionContext(roster: $0, otherNames: others) })
    }

    // MARK: Rule 0

    func testARejectedEmailBlocksThatPersonForEachRule() {
        var people = self.people
        people[0].emails = [EmailIdentity(address: "shared@example.com", state: .rejected, source: .owner, at: Date())]
        XCTAssertEqual(resolve("Carter, Sam", email: "shared@example.com", in: people), .unknown, "the owner said this address is not Sam's")
        XCTAssertEqual(resolve("Carter, Sam", email: "other@example.com", in: people).person, sam)
    }

    func testAFormTheOwnerGaveIsCertain() {
        var people = self.people
        people[2].addForm("Mick the Reed", kind: .alias, source: .owner, confirmed: true, at: Date())
        XCTAssertEqual(resolve("mick the reed", in: people), .resolved(reed, rule: .ownerLink, confidence: .certain))
    }

    // MARK: Rules 1 and 1b

    func testAVerifiedEmailResolvesInAnyCase() {
        XCTAssertEqual(resolve(email: " Sam.Carter@Example.com "), .resolved(sam, rule: .verifiedEmail, confidence: .certain))
        XCTAssertEqual(PersonResolver(people: people).resolve(Observation(text: "sam.carter@example.com")).person, sam)
        XCTAssertEqual(PersonResolver(people: people).resolve(Observation(text: "Someone <sam.carter@example.com>")).person, sam)
        XCTAssertEqual(resolve(email: "nobody@example.com"), .unknown)
    }

    func testAVerifiedEmailOfTwoPeopleIsNobody() {
        let twins = [testPerson("a", "Sam Carter", email: "team@example.com"), testPerson("b", "Dana Lee", email: "team@example.com")]
        XCTAssertEqual(resolve("Sam Carter", email: "team@example.com", in: twins),
                       .ambiguous([PersonID(rawValue: "a"), PersonID(rawValue: "b")], rule: .verifiedEmail), "and the name makes no link after that")
    }

    func testASharedAddressNeverIdentifiesAPerson() {
        var people = self.people
        people[0].emails[0].shared = true
        XCTAssertEqual(resolve(email: "sam.carter@example.com", in: people), .unknown)
    }

    func testASeenEmailResolvesWhileOnePersonHasIt() {
        XCTAssertEqual(resolve(email: "dana@example.com"), .resolved(dana, rule: .seenEmail, confidence: .strong))
        let two = people + [testPerson("x", "Riley Chen", seenEmail: "dana@example.com")]
        XCTAssertEqual(resolve(email: "dana@example.com", in: two), .ambiguous([dana, PersonID(rawValue: "x")], rule: .seenEmail))
    }

    // MARK: Rule 2

    func testAnExternalIDResolves() {
        let id = SourceIdentity(source: SourceKind(rawValue: "googleChat"), account: "acme", kind: "userID", value: "users/42", state: .verified, at: Date())
        var people = self.people
        people[1].identities = [id]
        let r = PersonResolver(people: people)
        XCTAssertEqual(r.resolve(Observation(name: "Somebody Else", identity: id)), .resolved(dana, rule: .externalID, confidence: .certain))
        var other = id
        other.account = "another"
        XCTAssertEqual(r.resolve(Observation(identity: other)), .unknown, "the same value in another account is another key")
    }

    // MARK: Rule 3

    func testAKnownFormOfTwoWordsResolves() {
        XCTAssertEqual(resolve("sam  CARTER"), .resolved(sam, rule: .nameForm, confidence: .strong))
        XCTAssertEqual(resolve("Sam Carter (Acme)"), .resolved(sam, rule: .nameForm, confidence: .strong))
        var people = self.people
        people[0].addForm("Carter, Sam", kind: .seen, source: .calendar, confirmed: false, at: Date())
        XCTAssertEqual(resolve("carter sam", in: people), .resolved(sam, rule: .nameForm, confidence: .strong), "a form seen before needs no proof again")
    }

    func testAFormerNameContinuesToResolve() {
        var people = self.people
        people[1].rename(to: "Dana Park", source: .owner, at: Date())
        XCTAssertEqual(resolve("Dana Lee", in: people).person, dana)
        XCTAssertEqual(resolve("Dana Park", in: people).person, dana)
    }

    func testAProvedOrderResolves() {
        XCTAssertEqual(resolve("Carter, Sam"), .resolved(sam, rule: .provedOrder, confidence: .strong))
        XCTAssertEqual(resolve("CARTER Sam"), .resolved(sam, rule: .provedOrder, confidence: .strong))
        XCTAssertEqual(resolve("Lee, Dana (Acme)"), .resolved(dana, rule: .provedOrder, confidence: .strong))
    }

    func testAMiddleNameOnOneSideResolves() {
        XCTAssertEqual(resolve("Sam A. Carter"), .resolved(sam, rule: .sameName, confidence: .strong))
        XCTAssertEqual(resolve("Dr. Sam Allen Carter Jr."), .resolved(sam, rule: .sameName, confidence: .strong))
        XCTAssertEqual(resolve("Carter, Sam A."), .resolved(sam, rule: .provedOrder, confidence: .strong))
    }

    func testAnUnprovedSwapIsALinkOnlyWhenThatPersonIsThere() {
        XCTAssertEqual(resolve("Carter Sam", roster: [sam, dana]), .resolved(sam, rule: .swappedName, confidence: .probable))
        guard case .suggestion(let id, let rule, let evidence) = resolve("Carter Sam") else { return XCTFail("a suggestion, never a link") }
        XCTAssertEqual(id, sam)
        XCTAssertEqual(rule, .swappedName)
        XCTAssertFalse(evidence.isEmpty)
        guard case .suggestion = resolve("Carter Sam", roster: [dana]) else { return XCTFail("Sam is not known to be there") }
    }

    func testASwapNeverWinsOverTheStraightReading() {
        // Someone is saved as "Carter Sam": the written order is theirs.
        let both = people + [testPerson("x", "Carter Sam")]
        XCTAssertEqual(resolve("Carter Sam", roster: [sam], in: both).person, PersonID(rawValue: "x"))
        XCTAssertEqual(resolve("Sam Carter", in: both).person, sam)
    }

    // MARK: Rules 4 and 4b

    func testANicknameIsALinkOnlyAmongThePeopleWhoAreThere() {
        XCTAssertEqual(resolve("Mike Reed", roster: [reed, sam]), .resolved(reed, rule: .nickname, confidence: .probable))
        guard case .suggestion(let id, .nickname, _) = resolve("Mike Reed") else { return XCTFail("a suggestion") }
        XCTAssertEqual(id, reed)
        guard case .suggestion = resolve("Mike Reed", roster: [sam]) else { return XCTFail("Michael is not there") }
    }

    func testAFirstNameIsALinkOnlyWhenOnePersonThereHasIt() {
        XCTAssertEqual(resolve("Sam"), .unknown, "a first name with no meeting around it can be anyone")
        XCTAssertEqual(resolve("Sam", roster: [sam, dana]), .resolved(sam, rule: .shortName, confidence: .probable))
        XCTAssertEqual(resolve("Sam C.", roster: [sam, dana]), .resolved(sam, rule: .shortName, confidence: .probable))
        XCTAssertEqual(resolve("Sam K.", roster: [sam, dana]), .unknown)
        XCTAssertEqual(resolve("Sam", roster: [dana]), .unknown, "Sam Carter is saved, and not there")
    }

    func testAnotherPersonOfThatFirstNameThereMakesItNobody() {
        XCTAssertEqual(resolve("Sam", roster: [sam], others: ["Sam Lee"]).person, nil)
        XCTAssertEqual(resolve("Sam", roster: [sam], others: ["Lee, Sam"]).person, nil, "also when that name is written last name first")
        let two = people + [testPerson("x", "Samuel Park")]
        XCTAssertEqual(resolve("Sam", roster: [sam, PersonID(rawValue: "x")], in: two), .ambiguous([sam, PersonID(rawValue: "x")], rule: .shortName))
        XCTAssertEqual(resolve("Sam", roster: [sam], others: ["Sam"]).person, sam, "the entry itself is not a second person")
    }

    func testAPersonSavedUnderOneWordResolvesOnlyInAMeetingWithNobodyElseOfThatName() {
        let jo = PersonID(rawValue: "jo")
        XCTAssertEqual(resolve("Jo"), .unknown)
        XCTAssertEqual(resolve("Jo", roster: []), .resolved(jo, rule: .shortName, confidence: .probable))
        XCTAssertEqual(resolve("Jo", roster: [], others: ["Jo Park"]), .unknown)
    }

    // MARK: Rule 5

    func testANameALetterOffIsOnlyASuggestion() {
        guard case .suggestion(let id, .similar, _) = resolve("Michael Reid") else { return XCTFail("a suggestion") }
        XCTAssertEqual(id, reed)
        XCTAssertNil(resolve("Michael Reid", roster: [reed]).person, "never a link, in a meeting or out of one")
        XCTAssertEqual(resolve("Riley Chen"), .unknown)
        XCTAssertEqual(resolve("Speaker A"), .unknown)
        XCTAssertEqual(resolve(""), .unknown)
    }

    // MARK: Conflicts and order

    func testTheEmailBeatsTheName() {
        // An assistant sends the invite: the address is Sam's and the name is Dana's.
        XCTAssertEqual(resolve("Dana Lee", email: "sam.carter@example.com"), .resolved(sam, rule: .verifiedEmail, confidence: .certain))
    }

    func testAnUnknownEmailLeavesTheNameToDecide() {
        XCTAssertEqual(resolve("Carter, Sam", email: "sam@other.example.com"), .resolved(sam, rule: .provedOrder, confidence: .strong))
    }

    func testTwoDifferentMiddleNamesAreTwoPeople() {
        let a = [testPerson("a", "Sam A. Carter")]
        XCTAssertEqual(resolve("Sam B. Carter", in: a), .unknown, "a conflict blocks the similar-name suggestion too")
        XCTAssertEqual(resolve("Carter, Sam B.", roster: [PersonID(rawValue: "a")], in: a), .unknown)
        let both = a + [testPerson("b", "Sam B. Carter")]
        XCTAssertEqual(resolve("Sam B. Carter", in: both).person, PersonID(rawValue: "b"))
        XCTAssertEqual(resolve("Sam Carter", in: both), .ambiguous([PersonID(rawValue: "a"), PersonID(rawValue: "b")], rule: .sameName))
    }

    func testTwoPeopleWithOneNameAreNobody() {
        let twins = [testPerson("a", "Sam Carter"), testPerson("b", "sam carter")]
        XCTAssertEqual(resolve("Sam Carter", in: twins), .ambiguous([PersonID(rawValue: "a"), PersonID(rawValue: "b")], rule: .nameForm))
        XCTAssertNil(resolve("Carter, Sam", in: twins).person)
        XCTAssertNil(resolve("Sam", roster: [PersonID(rawValue: "a"), PersonID(rawValue: "b")], in: twins).person)
    }

    func testADeletedOrMergedPersonResolvesNothing() {
        var people = self.people
        people[0].deleted = Date()
        people[1].mergedInto = reed
        XCTAssertEqual(resolve("Sam Carter", in: people), .unknown)
        XCTAssertEqual(resolve(email: "dana@example.com", in: people), .unknown)
    }

    // MARK: The three review cases of the links, on the resolver

    func testASavedFirstNameDoesNotLinkWhenTheMeetingHasAnotherPersonWithIt() {
        let both = [testPerson("one", "Sam"), testPerson("full", "Sam Carter"), testPerson("dana", "Dana Lee")]
        let one = PersonID(rawValue: "one"), full = PersonID(rawValue: "full")
        XCTAssertEqual(resolve("Sam", roster: [full, dana], in: both).person, full, "the meeting's Sam is Sam Carter, not the person saved as Sam")
        XCTAssertEqual(resolve("Sam Carter", roster: [full, dana], in: both).person, full)
        XCTAssertEqual(resolve("Sam", roster: [one, full], in: both), .ambiguous([full, one], rule: .shortName))
    }

    func testAFirstNameWithAnUnsavedPersonOfThatNameInTheMeetingLinksNobody() {
        XCTAssertNil(resolve("Sam", roster: [sam], others: ["Sam Lee"]).person)
    }

    func testTwoFullNamesWithOneShortFormAreTwoPeople() {
        let d = [testPerson("a", "Alexandra Smith"), testPerson("s", "Samantha Reed"), testPerson("e", "Edward Jones")]
        let ids = d.map(\.id)
        for text in ["Alexander Smith", "Samuel Reed", "Theodore Jones"] { XCTAssertNil(resolve(text, roster: ids, in: d).person, text) }
        XCTAssertEqual(resolve("Sam Reed", roster: ids, in: d).person, PersonID(rawValue: "s"))
        XCTAssertEqual(resolve("Ted Jones", roster: ids, in: d).person, PersonID(rawValue: "e"))
    }

    // MARK: Properties

    private let observations: [(String?, String?)] = [
        ("Sam Carter", nil), ("Carter, Sam", nil), ("Carter Sam", nil), ("Sam", nil), ("Mike Reed", nil), ("Michael Reid", nil),
        (nil, "sam.carter@example.com"), ("Dana Lee", "sam.carter@example.com"), ("Riley Chen", nil), ("Jo", nil), ("Reed, Michael A.", nil),
    ]

    func testTheAnswerDoesNotDependOnTheOrderOfThePeople() {
        let roster = [sam, dana, reed]
        for (name, email) in observations {
            let expected = resolve(name, email: email, roster: roster)
            for _ in 0..<8 {
                XCTAssertEqual(resolve(name, email: email, roster: roster.shuffled(), in: people.shuffled()), expected, name ?? email ?? "")
            }
        }
    }

    func testANewUnrelatedPersonNeverMovesALink() {
        let strangers = ["Riley Chen", "Morgan Blake", "Priya Nair", "Tomas Ruiz", "Wen Li"].enumerated().map { testPerson("z\($0)", $1, email: "p\($0)@example.com") }
        for (name, email) in observations where name != "Riley Chen" {
            for context in [nil, [sam, dana, reed]] as [[PersonID]?] {
                XCTAssertEqual(resolve(name, email: email, roster: context, in: people + strangers), resolve(name, email: email, roster: context), name ?? email ?? "")
            }
        }
    }

    func testAPersonWithTheSameNameTurnsALinkIntoNobodyNotIntoAnotherPerson() {
        for name in ["Sam Carter", "Carter, Sam", "Sam A. Carter"] {
            XCTAssertEqual(resolve(name).person, sam)
            let after = resolve(name, in: people + [testPerson("twin", "Sam Carter")])
            guard case .ambiguous(let ids, _) = after else { return XCTFail("\(name): \(after)") }
            XCTAssertTrue(ids.contains(sam))
        }
    }

    // MARK: Suggestions

    func testSuggestionsArePairsThatAreProbablyOnePerson() {
        let people = [testPerson("a", "Sam Carter", email: "s@example.com"), testPerson("b", "Carter Sam"), testPerson("c", "Michael Reed"),
                      testPerson("d", "Mike Reed"), testPerson("e", "Sam C", email: "S@example.com"), testPerson("f", "Zach Sampson"),
                      testPerson("g", "Zach Samson"), testPerson("h", "Scott Miller"), testPerson("i", "Scott Taylor"),
                      testPerson("j", "Dana A. Lee"), testPerson("k", "Dana B. Lee")]
        let found = PersonResolver(people: people).suggestions()
        func rule(_ x: String, _ y: String) -> Resolution.Rule? {
            found.first { Set([$0.first.rawValue, $0.second.rawValue]) == Set([x, y]) }?.rule
        }
        XCTAssertEqual(rule("a", "b"), .swappedName)
        XCTAssertEqual(rule("c", "d"), .nickname)
        XCTAssertEqual(rule("a", "e"), .verifiedEmail)
        XCTAssertEqual(rule("f", "g"), .similar)
        XCTAssertNil(rule("h", "i"))
        XCTAssertNil(rule("j", "k"), "two middle names that disagree are two people")
        XCTAssertEqual(found.count, 4)
    }

    func testAPairTheOwnerCalledDifferentPeopleDoesNotComeBack() {
        var a = testPerson("a", "Sam Carter"), b = testPerson("b", "Carter Sam")
        a.distinctFrom = [b.id]
        b.rename(to: "Carter Samuel", source: .owner, at: Date())
        XCTAssertTrue(PersonResolver(people: [a, b]).suggestions().isEmpty, "through a rename")
    }
}
