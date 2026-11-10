import XCTest
@testable import MossadCore

/// The written forms of a name that the parser reads. Each row of the design's table is one case.
final class PersonNamesTests: XCTestCase {
    private func parts(_ text: String) -> [String] {
        let p = PersonNames.parse(text)
        return [p.given ?? "-", p.middle.joined(separator: " "), p.family ?? "-", p.order.rawValue]
    }

    // MARK: The key

    func testTheKeyFoldsCaseDiacriticsAndPunctuation() {
        XCTAssertEqual(PersonNames.key("  Sam   CARTER "), "sam carter")
        XCTAssertEqual(PersonNames.key("Carter, Sam"), "carter sam")
        XCTAssertEqual(PersonNames.key("Sam A. Carter"), "sam a carter")
        XCTAssertEqual(PersonNames.key("Zoë Carter-Reed"), "zoe carter reed")
        XCTAssertEqual(PersonNames.key("Zoë Carter-Reed"), PersonNames.key("Zoe Carter Reed"), "the hyphen is a space in the key")
        XCTAssertEqual(PersonNames.key("José Núñez"), "jose nunez")
        XCTAssertEqual(PersonNames.key(""), "")
    }

    func testApostrophesAreRemovedInTheKey() {
        XCTAssertEqual(PersonNames.key("O'Neil"), "oneil")
        XCTAssertEqual(PersonNames.key("O’Neil"), "oneil")
        XCTAssertEqual(PersonNames.parse("Pat O'Neil").family, "oneil")
        XCTAssertEqual(PersonNames.parse("O’Neil, Pat").family, "oneil")
    }

    // MARK: The parser, row by row

    func testFirstThenLast() {
        XCTAssertEqual(parts("Sam Carter"), ["sam", "", "carter", "none"])
    }

    func testLastCommaFirst() {
        XCTAssertEqual(parts("Carter, Sam"), ["sam", "", "carter", "comma"])
        XCTAssertEqual(parts("carter,sam"), ["sam", "", "carter", "comma"])
    }

    func testLastCommaFirstWithAMiddleInitial() {
        XCTAssertEqual(parts("Carter, Sam A."), ["sam", "a", "carter", "comma"])
    }

    func testAFamilyNameInCapitalsFirst() {
        XCTAssertEqual(parts("CARTER Sam"), ["sam", "", "carter", "capitals"])
        XCTAssertEqual(parts("CARTER Sam Allen"), ["sam", "allen", "carter", "capitals"])
    }

    func testAFamilyNameInCapitalsLast() {
        XCTAssertEqual(parts("Sam CARTER"), ["sam", "", "carter", "capitals"])
        XCTAssertEqual(parts("Sam A. CARTER"), ["sam", "a", "carter", "capitals"])
    }

    func testCapitalsProveNothingWhenTheWholeNameHasThem() {
        XCTAssertEqual(parts("SAM CARTER"), ["sam", "", "carter", "none"])
        XCTAssertEqual(parts("sam carter"), ["sam", "", "carter", "none"])
    }

    func testTwoCapitalLettersAreAShortFirstNameNotAFamilyName() {
        // "DJ" and "AJ" are first names. Only a word of three letters or more in capitals proves a family name.
        XCTAssertEqual(parts("DJ Carter"), ["dj", "", "carter", "none"])
    }

    func testLastThenFirstWithNoProofKeepsTheWrittenOrder() {
        // The swapped reading is a second candidate; `fit` finds it.
        XCTAssertEqual(parts("Carter Sam"), ["carter", "", "sam", "none"])
    }

    func testAMiddleNameOrInitial() {
        XCTAssertEqual(parts("Sam A. Carter"), ["sam", "a", "carter", "none"])
        XCTAssertEqual(parts("Sam Allen Carter"), ["sam", "allen", "carter", "none"])
    }

    func testATitleAndASuffixAreRemoved() {
        XCTAssertEqual(parts("Dr. Sam Carter Jr."), ["sam", "", "carter", "none"])
        XCTAssertEqual(PersonNames.parse("Dr. Sam Carter Jr.").suffix, "jr")
        XCTAssertEqual(parts("Sam Carter, PhD"), ["sam", "", "carter", "none"])
        XCTAssertEqual(PersonNames.parse("Sam Carter, PhD").suffix, "phd")
    }

    func testTwoCommasWithASuffixAreStillLastCommaFirst() {
        XCTAssertEqual(parts("Carter, Sam, PhD"), ["sam", "", "carter", "comma"])
        XCTAssertEqual(parts("Carter, Sam A., Jr."), ["sam", "a", "carter", "comma"])
    }

    func testACompanyInBracketsAndAnAddressAreNotPartOfTheName() {
        XCTAssertEqual(parts("Sam Carter (Acme)"), ["sam", "", "carter", "none"])
        XCTAssertEqual(parts("Sam Carter <sam@acme.com>"), ["sam", "", "carter", "none"])
        XCTAssertEqual(parts("Carter, Sam (Acme) <sam@acme.com>"), ["sam", "", "carter", "comma"])
        XCTAssertEqual(PersonNames.email(in: "Sam Carter <Sam@Acme.com>"), "sam@acme.com", "the email becomes its own observation")
        XCTAssertNil(PersonNames.email(in: "Sam Carter"))
    }

    func testAHyphenInTheFamilyName() {
        XCTAssertEqual(parts("Zoë Carter-Reed"), ["zoe", "", "carter reed", "none"])
        XCTAssertEqual(parts("Carter-Reed, Zoë"), ["zoe", "", "carter reed", "comma"])
        // Without the hyphen, syntax cannot tell a middle name from a first part of the family name. The two
        // readings have the same words, and that makes them one name.
        XCTAssertEqual(PersonNames.fit(PersonNames.parse("Zoë Carter-Reed"), PersonNames.parse("Zoe Carter Reed")), .same)
        XCTAssertEqual(PersonNames.fit(PersonNames.parse("Carter Reed, Zoe"), PersonNames.parse("Zoë Carter-Reed")), .same)
    }

    func testParticlesStayWithTheFamilyName() {
        XCTAssertEqual(parts("Maria De La Cruz"), ["maria", "", "de la cruz", "none"])
        XCTAssertEqual(parts("De La Cruz, Maria"), ["maria", "", "de la cruz", "comma"])
        XCTAssertEqual(parts("Jan van der Berg"), ["jan", "", "van der berg", "none"])
        XCTAssertEqual(parts("Maria Elena De La Cruz"), ["maria", "elena", "de la cruz", "none"])
    }

    func testOneWordIsAFirstNameOnly() {
        XCTAssertEqual(parts("Sam"), ["sam", "", "-", "none"])
        XCTAssertTrue(PersonNames.parse("Sam").isName)
    }

    func testAnAddressALabelAndEmptyTextAreNotNames() {
        XCTAssertFalse(PersonNames.parse("sam.carter@acme.com").isName)
        XCTAssertNil(PersonNames.parse("sam.carter@acme.com").given)
        XCTAssertFalse(PersonNames.parse("Speaker C").isName)
        XCTAssertFalse(PersonNames.parse("   ").isName)
        XCTAssertFalse(PersonNames.parse("(Acme)").isName)
    }

    // MARK: Fit

    private func fit(_ a: String, _ b: String) -> NameFit { PersonNames.fit(PersonNames.parse(a), PersonNames.parse(b)) }

    func testTheSameNameInEachWrittenFormFits() {
        for written in ["Sam Carter", "sam  carter", "Carter, Sam", "CARTER Sam", "Sam CARTER", "Dr. Sam Carter Jr.", "Sam Carter (Acme)"] {
            XCTAssertEqual(fit(written, "Sam Carter"), .same, written)
            XCTAssertEqual(fit("Sam Carter", written), .same, written)
        }
    }

    func testAMiddleNameOnOneSideStillFits() {
        XCTAssertEqual(fit("Sam A. Carter", "Sam Carter"), .sameWithMiddle)
        XCTAssertEqual(fit("Carter, Sam Allen", "Sam Carter"), .sameWithMiddle)
        XCTAssertEqual(fit("Sam A. Carter", "Sam Allen Carter"), .same, "an initial agrees with its name")
        XCTAssertEqual(fit("Sam Allen Carter", "Carter, Sam A."), .same)
    }

    func testTwoDifferentMiddleNamesAreAConflict() {
        XCTAssertEqual(fit("Sam A. Carter", "Sam B. Carter"), .conflict)
        XCTAssertEqual(fit("Sam Allen Carter", "Sam Blake Carter"), .conflict)
        XCTAssertEqual(fit("Carter, Sam A.", "Sam B. Carter"), .conflict)
    }

    func testAnUnprovedSwapIsItsOwnAnswer() {
        XCTAssertEqual(fit("Carter Sam", "Sam Carter"), .swapped)
        XCTAssertEqual(fit("Sam Carter", "Carter Sam"), .swapped)
        // Only a side with no proof is read the other way.
        XCTAssertEqual(fit("Sam, Carter", "Sam Carter"), .swapped)
        XCTAssertEqual(fit("Sam, Carter", "Carter, Sam"), .none, "two proved orders that disagree are two names")
        XCTAssertEqual(fit("Sam, Carter", "CARTER Sam"), .none)
    }

    func testAShortFormAndItsFullFormAreANickname() {
        XCTAssertEqual(fit("Mike Reed", "Michael Reed"), .nickname)
        XCTAssertEqual(fit("Reed, Mike", "Michael Reed"), .nickname)
        XCTAssertEqual(fit("Samuel Reed", "Samantha Reed"), .none, "two full names of one group are two people")
        XCTAssertEqual(fit("Bill Reed", "Will Reed"), .none, "two short forms can be two people")
    }

    func testAFirstNameAloneOrWithAnInitialIsShort() {
        XCTAssertEqual(fit("Sam", "Sam Carter"), .short)
        XCTAssertEqual(fit("Sam", "Samuel Reed"), .short)
        XCTAssertEqual(fit("Sam C.", "Sam Carter"), .short)
        XCTAssertEqual(fit("Dana K.", "Dana Lee"), .none)
        XCTAssertEqual(fit("Sam", "Dana Lee"), .none)
    }

    func testOtherNamesDoNotFit() {
        XCTAssertEqual(fit("Scott Miller", "Scott Taylor"), .none)
        XCTAssertEqual(fit("Dana Carter", "Sam Carter"), .none)
        XCTAssertEqual(fit("sam@acme.com", "Sam Carter"), .none)
        XCTAssertEqual(fit("Speaker A", "Speaker A"), .none)
    }
}
