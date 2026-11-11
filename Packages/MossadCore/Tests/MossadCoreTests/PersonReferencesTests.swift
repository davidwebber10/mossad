import XCTest
@testable import MossadCore

/// Ids next to names in records and commitments: who gets one, who does not, a rename, a merge, and the repair of
/// what an older build dropped.
final class PersonReferencesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    private var owner: Person!, sam: Person!, dana: Person!, samReed: Person!

    override func setUp() {
        owner = Person(id: PersonID(rawValue: "id-owner"), displayName: "Avery Webb", isOwner: true, origin: .owner, at: t0)
        sam = Person(id: PersonID(rawValue: "id-sam"), displayName: "Sam Carter", origin: .migration, at: t0)
        sam.setVerifiedEmail("sam.carter@example.com", at: t0)
        dana = Person(id: PersonID(rawValue: "id-dana"), displayName: "Dana Lee", origin: .migration, at: t0)
        samReed = Person(id: PersonID(rawValue: "id-reed"), displayName: "Samuel Reed", origin: .migration, at: t0)
    }

    private var people: [Person] { [owner, sam, dana, samReed] }

    private func record() -> CallRecord {
        var r = CallRecord(id: "20261105-100000", platform: .meet, bundleID: "b", start: t0, end: t0.addingTimeInterval(1800), status: .written)
        r.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter", "them:B": "Speaker B", "them:C": "Pat Moreno"]
        r.attendees = ["Carter, Sam", "dana@nowhere.example.com", "sam.carter@example.com"]
        r.invitees = [Invitee(name: "Carter, Sam", email: nil), Invitee(name: "Dana", email: "dana@nowhere.example.com"),
                      Invitee(name: nil, email: "sam.carter@example.com")]
        r.actionItems = [ActionItem(owner: "Sam", task: "send the plan"), ActionItem(owner: "Sam Carter", task: "book the room"),
                         ActionItem(owner: nil, task: "check the budget"), ActionItem(owner: "Jordan", task: "call the vendor"),
                         ActionItem(owner: "Avery", task: "write it up")]
        return r
    }

    // MARK: Who gets an id

    func testEachSureNameGetsAnIdAndALabelGetsNone() {
        let r = PersonReferences(people: people).refresh(record())
        XCTAssertEqual(r.speakerPeople, ["me:A": "id-owner", "them:A": "id-sam"], "no id for Speaker B or for a name that is no saved person")
        XCTAssertEqual(r.invitees?.map(\.personID), ["id-sam", nil, "id-sam"], "last name first, and the address; a first name of nobody there is nobody")
        XCTAssertEqual(r.actionItems.map(\.ownerID), ["id-sam", "id-sam", nil, nil, "id-owner"], "a short name inside the call's people")
        XCTAssertEqual(r.speakerNames, record().speakerNames, "no label changes with no rename")
        XCTAssertEqual(r.actionItems.map(\.owner), record().actionItems.map(\.owner))
    }

    func testAShortNameThatTwoPeopleOfTheCallFitIsNobody() {
        var r = record()
        r.speakerNames["them:D"] = "Samuel Reed"
        let out = PersonReferences(people: people).refresh(r)
        XCTAssertEqual(out.speakerPeople?["them:D"], "id-reed")
        XCTAssertNil(out.actionItems[0].ownerID, "\"Sam\" can be Sam Carter or Samuel Reed")
        XCTAssertEqual(out.actionItems[1].ownerID, "id-sam")
    }

    func testTwoSavedPeopleWithOneNameGetNoId() {
        let twin = Person(id: PersonID(rawValue: "id-twin"), displayName: "Sam Carter", origin: .migration, at: t0)
        let out = PersonReferences(people: people + [twin]).refresh(record())
        XCTAssertNil(out.speakerPeople?["them:A"])
        XCTAssertNil(out.actionItems[1].ownerID)
        XCTAssertEqual(out.invitees?[2].personID, "id-sam", "the address still says who it is")
    }

    func testNoPeopleChangesNothing() {
        XCTAssertEqual(PersonReferences(people: []).refresh(record()), record())
    }

    func testARefreshIsSafeToRunAgain() {
        let refs = PersonReferences(people: people)
        let once = refs.refresh(record())
        XCTAssertEqual(refs.refresh(once), once)
    }

    // MARK: Repair

    func testIdsThatAnOlderBuildDroppedComeBack() {
        let refs = PersonReferences(people: people)
        let full = refs.refresh(record())
        XCTAssertEqual(refs.refresh(PersonReferences.withoutIDs(full)), full)
    }

    func testAnIdOfAStoreThatStartedAgainIsFoundAgainFromTheLabel() {
        var r = PersonReferences(people: people).refresh(record())
        r.speakerPeople?["them:A"] = "id-gone"
        r.actionItems[1].ownerID = "id-gone"
        let out = PersonReferences(people: people).refresh(r)
        XCTAssertEqual(out.speakerPeople?["them:A"], "id-sam")
        XCTAssertEqual(out.actionItems[1].ownerID, "id-sam")
    }

    func testANewNameFromANewerEditWinsOverAnOldId() {
        var r = PersonReferences(people: people).refresh(record())
        r.speakerNames["them:A"] = "Dana Lee"
        let out = PersonReferences(people: people).refresh(r)
        XCTAssertEqual(out.speakerPeople?["them:A"], "id-dana")
        r.speakerNames["them:A"] = "Someone New"
        XCTAssertNil(PersonReferences(people: people).refresh(r).speakerPeople?["them:A"], "a name that is nobody keeps no old id")
    }

    func testAKeyThatLeftLeavesItsId() {
        var r = PersonReferences(people: people).refresh(record())
        r.speakerNames["them:A"] = nil
        XCTAssertNil(PersonReferences(people: people).refresh(r).speakerPeople?["them:A"])
    }

    // MARK: Rename and merge

    func testARenameChangesTheLabelsOfTheWholeNameAndKeepsAShortOne() {
        let refs = PersonReferences(people: people)
        let before = refs.refresh(record())
        sam.rename(to: "Sam Brooks", source: .owner, at: t0)
        let after = PersonReferences(people: people).refresh(before)
        XCTAssertEqual(after.speakerNames["them:A"], "Sam Brooks")
        XCTAssertEqual(after.speakerPeople?["them:A"], "id-sam")
        XCTAssertEqual(after.actionItems[1].owner, "Sam Brooks")
        XCTAssertEqual(after.actionItems[0].owner, "Sam", "a short name is still right")
        XCTAssertEqual(after.actionItems[0].ownerID, "id-sam")
        XCTAssertEqual(after.invitees?[0].name, "Carter, Sam", "what the calendar wrote stays")
        XCTAssertTrue(PersonReferences(people: people).changesOnlyReferences(from: before, to: after))
    }

    func testAStopBeforeTheLabelsChangedIsFinishedFromTheOldName() {
        // The rename reached the people file; the records still have the old name and no ids.
        sam.rename(to: "Sam Brooks", source: .owner, at: t0)
        let out = PersonReferences(people: people).refresh(record())
        XCTAssertEqual(out.speakerNames["them:A"], "Sam Brooks", "one person, not two")
        XCTAssertEqual(out.speakerPeople?["them:A"], "id-sam")
    }

    func testAFormerNameThatIsAnotherPersonsNameNowIsThatPerson() {
        // A voice was named "Dana Lee" by mistake and corrected to "Sam Carter"; the real Dana Lee is saved too.
        sam.forms.append(NameForm(text: "Dana Lee", kind: .former, source: .owner, confirmed: true, at: t0))
        var r = record()
        r.speakerNames["them:D"] = "Dana Lee"
        let out = PersonReferences(people: people).refresh(r)
        XCTAssertEqual(out.speakerPeople?["them:D"], "id-dana")
        XCTAssertEqual(out.speakerNames["them:D"], "Dana Lee")
    }

    func testTheOwnersNewNameReachesTheOwnersLines() {
        let before = PersonReferences(people: people).refresh(record())
        owner.rename(to: "Avery Stone", source: .owner, at: t0)
        let after = PersonReferences(people: people).refresh(before)
        XCTAssertEqual(after.speakerNames["me:A"], "Avery Stone")
        XCTAssertEqual(after.speakerPeople?["me:A"], "id-owner")
    }

    func testAMergedPersonsReferencesGoToThePersonThatTookItIn() {
        var sc = Person(id: PersonID(rawValue: "id-sc"), displayName: "Sam C", origin: .migration, at: t0)
        var r = record()
        r.speakerNames["them:A"] = "Sam C"
        r.actionItems[1].owner = "Sam C"
        let before = PersonReferences(people: people + [sc]).refresh(r)
        XCTAssertEqual(before.speakerPeople?["them:A"], "id-sc")
        sc.mergedInto = sam.id
        sam.addForm("Sam C", kind: .alias, source: .owner, confirmed: true, at: t0)
        let after = PersonReferences(people: people + [sc]).refresh(before)
        XCTAssertEqual(after.speakerPeople?["them:A"], "id-sam")
        XCTAssertEqual(after.speakerNames["them:A"], "Sam Carter")
        XCTAssertEqual(after.actionItems[1].ownerID, "id-sam")
        XCTAssertEqual(after.actionItems[1].owner, "Sam Carter")
    }

    func testAnIdOfADeletedPersonIsDropped() {
        let before = PersonReferences(people: people).refresh(record())
        dana.deleted = t0
        sam.deleted = t0
        let after = PersonReferences(people: people).refresh(before)
        XCTAssertNil(after.speakerPeople?["them:A"])
        XCTAssertEqual(after.speakerNames["them:A"], "Sam Carter", "the label stays")
    }

    func testTheCheckRefusesAChangeOutsideTheReferences() {
        let refs = PersonReferences(people: people)
        let before = record()
        var after = refs.refresh(before)
        XCTAssertTrue(refs.changesOnlyReferences(from: before, to: after))
        after.summary = "changed"
        XCTAssertFalse(refs.changesOnlyReferences(from: before, to: after))
        after = refs.refresh(before)
        after.speakerNames["them:A"] = "Dana Lee"
        XCTAssertFalse(refs.changesOnlyReferences(from: before, to: after), "a label may only become the name of its own id")
    }

    // MARK: Commitments

    func testACommitmentGetsAnIdInsideItsCallAndAHandMadeOneOnlyByTheWholeName() {
        let refs = PersonReferences(people: people)
        let call = refs.refresh(record())
        let inCall = refs.refresh(Commitment(text: "Send it", to: "Sam", callID: call.id, callTitle: nil, madeAt: t0, due: nil), call: call)
        XCTAssertEqual(inCall.toID, "id-sam")
        let byHand = refs.refresh(Commitment(text: "Call", to: "Sam", callID: nil, callTitle: nil, madeAt: t0, due: nil), call: nil)
        XCTAssertNil(byHand.toID)
        let nickname = refs.refresh(Commitment(text: "Call", to: "Sammy Reed", callID: nil, callTitle: nil, madeAt: t0, due: nil), call: nil)
        XCTAssertNil(nickname.toID, "a nickname is no sure match outside a call")
        let whole = refs.refresh(Commitment(text: "Call", to: "Carter, Sam", callID: nil, callTitle: nil, madeAt: t0, due: nil), call: nil)
        XCTAssertEqual(whole.toID, "id-sam")
    }

    func testARenameReachesACommitmentAndKeepsItsTime() {
        var book = CommitmentBook()
        book.items = [Commitment(text: "Send it", to: "Sam Carter", callID: nil, callTitle: nil, madeAt: t0, due: nil, created: t0)]
        book = PersonReferences(people: people).refresh(book, records: [])
        XCTAssertEqual(book.items[0].toID, "id-sam")
        sam.rename(to: "Sam Brooks", source: .owner, at: t0)
        let after = PersonReferences(people: people).refresh(book, records: [])
        XCTAssertEqual(after.items[0].to, "Sam Brooks")
        XCTAssertEqual(after.items[0].updated, t0, "an id is not a change of the owner's")
        XCTAssertEqual(PersonReferences(people: people).refresh(after, records: []), after)
    }
}

extension PersonReferencesTests {
    func testTheOwnersLinesAreFoundByTheIdUnderANameNobodyKnows() {
        var r = PersonReferences(people: people).refresh(record())
        r.speakerNames["me:A"] = "Typed Once"
        let owner = OwnerIdentity(name: "Avery Webb", id: "id-owner")
        XCTAssertEqual(owner.speakerKeys(in: r), ["me:A"])
        XCTAssertEqual(owner.withCurrentName(r).speakerNames["me:A"], "Avery Webb")
        XCTAssertEqual(OwnerIdentity(name: "Avery Webb").speakerKeys(in: r), [], "with no id, the name of before")
    }
}

extension PersonReferencesTests {
    func testANewPersonNeverMovesAnId() {
        let before = PersonReferences(people: people).refresh(record())
        let unrelated = Person(id: PersonID(rawValue: "id-0"), displayName: "Riley Chen", origin: .migration, at: t0)
        XCTAssertEqual(PersonReferences(people: people + [unrelated]).refresh(before), before)
        // Another Sam Carter: the ids stay with the person they were given to, and no new reference gets either.
        let twin = Person(id: PersonID(rawValue: "id-00"), displayName: "Sam Carter", origin: .migration, at: t0)
        let after = PersonReferences(people: [twin] + people).refresh(before)
        XCTAssertEqual(after.speakerPeople?["them:A"], "id-sam")
        XCTAssertEqual(after.actionItems[1].ownerID, "id-sam")
        var fresh = record()
        fresh.id = "other"
        XCTAssertNil(PersonReferences(people: [twin] + people).refresh(fresh).speakerPeople?["them:A"])
    }

    func testTheAnswerDoesNotDependOnTheOrderOfThePeople() {
        let r = record()
        XCTAssertEqual(PersonReferences(people: people).refresh(r), PersonReferences(people: people.reversed()).refresh(r))
    }
}
