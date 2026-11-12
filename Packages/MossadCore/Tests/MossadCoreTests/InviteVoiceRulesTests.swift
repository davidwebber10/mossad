import XCTest
@testable import MossadCore

final class InviteVoiceRulesTests: XCTestCase {
    typealias Guest = CallInvite.Guest
    let owner = "Avery Lane"

    func profile(_ name: String, voice: Bool = true, email: String? = nil, owner: Bool = false) -> VoiceProfile {
        VoiceProfile(name: name, isOwner: owner, embeddings: voice ? [[1, 0, 0, 0]] : [], email: email)
    }

    var profiles: [VoiceProfile] {
        [profile(owner, owner: true), profile("Mira Stone", email: "mira@example.com"), profile("Dale Fenwick")]
    }

    func voice(_ key: String, _ scores: [(String, Float)]) -> InviteVoiceRules.Voice {
        InviteVoiceRules.Voice(key: key, scores: scores.map { VoiceScore(name: $0.0, score: $0.1) }, fingerprint: true)
    }

    func decide(_ voices: [InviteVoiceRules.Voice], _ invite: CallInvite?, profiles: [VoiceProfile]? = nil, people: [Person] = []) -> InviteVoiceRules.Decision {
        let roster = invite.map { InviteRoster(invite: $0, profiles: profiles ?? self.profiles, people: people) }
        return InviteVoiceRules.decide(voices, roster: roster, owner: owner)
    }

    // The owner's case: the brother of an invited person is a weak match and was not invited; the invited person
    // has no voice yet, so the one voice left is them.
    func testUninvitedBrotherIsNotNamedAndTheVoicelessInviteeIs() {
        let invite = CallInvite(guests: [Guest(name: owner, email: "avery@example.com"), Guest(email: "mira@example.com"),
                                         Guest(email: "jo.fenwick@example.com")])
        let d = decide([voice("me:A", [(owner, 0.95)]), voice("them:A", [("Mira Stone", 0.9)]),
                        voice("them:B", [("Dale Fenwick", 0.74), ("Mira Stone", 0.2)])], invite)
        XCTAssertEqual(d.verdicts["me:A"], .named(owner, score: 0.95, learn: true))
        XCTAssertEqual(d.verdicts["them:A"], .named("Mira Stone", score: 0.9, learn: true))
        XCTAssertEqual(d.verdicts["them:B"], .inferred("Jo Fenwick"))
        XCTAssertEqual(d.inferred?.email, "jo.fenwick@example.com")
    }

    func testUninvitedWeakMatchIsWithheldAndSuggestedWhenNothingCanBeInferred() {
        let invite = CallInvite(guests: [Guest(name: "Mira Stone")])
        let d = decide([voice("them:A", [("Mira Stone", 0.9)]), voice("them:B", [("Dale Fenwick", 0.74), ("Mira Stone", 0.2)])], invite)
        XCTAssertEqual(d.verdicts["them:B"], .withheld(suggestion: VoiceScore(name: "Dale Fenwick", score: 0.74)))
        XCTAssertNil(d.inferred)
    }

    func testStrongUninvitedMatchWithAClearMarginStillNames() {
        let invite = CallInvite(guests: [Guest(name: "Mira Stone")])
        let d = decide([voice("them:A", [("Dale Fenwick", 0.88), ("Mira Stone", 0.5)])], invite)
        XCTAssertEqual(d.verdicts["them:A"], .named("Dale Fenwick", score: 0.88, learn: false))
    }

    func testStrongUninvitedMatchWithoutAMarginIsWithheld() {
        let invite = CallInvite(guests: [Guest(name: "Mira Stone")])
        let d = decide([voice("them:A", [("Dale Fenwick", 0.86), ("Mira Stone", 0.83)])], invite)
        XCTAssertEqual(d.verdicts["them:A"], .withheld(suggestion: VoiceScore(name: "Dale Fenwick", score: 0.86)))
    }

    func testTwoVoicelessInviteesNameNobody() {
        let invite = CallInvite(guests: [Guest(email: "jo.fenwick@example.com"), Guest(name: "Pat Quill")])
        let d = decide([voice("them:A", [("Dale Fenwick", 0.7)])], invite)
        XCTAssertEqual(d.verdicts["them:A"], .withheld(suggestion: VoiceScore(name: "Dale Fenwick", score: 0.7)))
        XCTAssertNil(d.inferred)
    }

    func testTwoVoicesLeftNameNobody() {
        let invite = CallInvite(guests: [Guest(email: "jo.fenwick@example.com")])
        let d = decide([voice("them:A", []), voice("them:B", [("Dale Fenwick", 0.7)])], invite)
        XCTAssertEqual(d.verdicts["them:A"], .unknown)
        XCTAssertNil(d.inferred)
    }

    func testAVoiceWithNoFingerprintIsNeverInferred() {
        let invite = CallInvite(guests: [Guest(email: "jo.fenwick@example.com")])
        let d = decide([InviteVoiceRules.Voice(key: "them:A", scores: [], fingerprint: false)], invite)
        XCTAssertEqual(d.verdicts["them:A"], .unknown)
    }

    func testTheLeftVoiceNearAnInvitedVoiceThatDidNotSpeakIsNotInferred() {
        // Mira was invited and has a voice, but no voice was named Mira: the one voice left may be her.
        let invite = CallInvite(guests: [Guest(name: "Mira Stone"), Guest(email: "jo.fenwick@example.com")])
        let d = decide([voice("them:A", [("Mira Stone", 0.6)])], invite)
        XCTAssertEqual(d.verdicts["them:A"], .unknown)
        XCTAssertNil(d.inferred)
    }

    func testMicVoicesAreNotTheOtherSide() {
        let invite = CallInvite(guests: [Guest(email: "jo.fenwick@example.com")])
        let d = decide([voice("me:B", [])], invite)
        XCTAssertEqual(d.verdicts["me:B"], .unknown)
    }

    func testNoInviteKeepsTheRuleOfBefore() {
        let d = decide([voice("them:A", [("Dale Fenwick", 0.7)]), voice("them:B", [("Mira Stone", 0.85)]), voice("them:C", [("Mira Stone", 0.5)])], nil)
        XCTAssertEqual(d.verdicts["them:A"], .named("Dale Fenwick", score: 0.7, learn: false))
        XCTAssertEqual(d.verdicts["them:B"], .named("Mira Stone", score: 0.85, learn: true))
        XCTAssertEqual(d.verdicts["them:C"], .unknown)
    }

    func testTheOwnersOwnVoiceIsAlwaysOnTheInvite() {
        let invite = CallInvite(guests: [Guest(name: "Mira Stone")])
        let d = decide([voice("me:A", [(owner, 0.7)])], invite)
        XCTAssertEqual(d.verdicts["me:A"], .named(owner, score: 0.7, learn: false))
    }

    func testAnUninvitedPersonIsNeverLearned() {
        let invite = CallInvite(guests: [Guest(name: "Mira Stone")])
        let d = decide([voice("them:A", [("Dale Fenwick", 0.99), ("Mira Stone", 0.1)])], invite)
        XCTAssertEqual(d.verdicts["them:A"], .named("Dale Fenwick", score: 0.99, learn: false))
    }

    // The roster: who on the invite is which saved voice.

    func testTheRosterFindsVoicesByEmailWholeNameAndPersonID() {
        let people = [Person(id: PersonID(rawValue: "p-dale"), displayName: "Dale Fenwick", origin: .voiceNaming, at: .distantPast)]
        let roster = InviteRoster(invite: CallInvite(guests: [Guest(email: "MIRA@example.com"), Guest(personID: "p-dale")]), profiles: profiles, people: people)
        XCTAssertEqual(roster.invited, [owner, "Mira Stone", "Dale Fenwick"])
        XCTAssertTrue(roster.voiceless.isEmpty)
        let byName = InviteRoster(invite: CallInvite(guests: [Guest(name: "Stone, Mira")]), profiles: profiles, people: [])
        XCTAssertTrue(byName.invited.contains("Mira Stone"))
    }

    func testAFirstNameAloneIsNotASureMatch() {
        let roster = InviteRoster(invite: CallInvite(guests: [Guest(name: "Mira")]), profiles: profiles, people: [])
        XCTAssertFalse(roster.invited.contains("Mira Stone"))
        XCTAssertEqual(roster.voiceless.map(\.label), ["Mira"])
    }

    func testTheOwnerIsNeverAVoicelessInvitee() {
        var me = Person(displayName: owner, isOwner: true, origin: .voiceNaming, at: .distantPast)
        _ = me.addEmail("avery@example.com", state: .verified, source: .voiceNaming, at: .distantPast)
        let roster = InviteRoster(invite: CallInvite(guests: [Guest(email: "avery@example.com"), Guest(name: "Mira Stone")]),
                                  profiles: [profile("Mira Stone")], people: [me])
        XCTAssertTrue(roster.voiceless.isEmpty)
    }

    func testADeclinedInviteeIsNotVoiceless() {
        let roster = InviteRoster(invite: CallInvite(guests: [Guest(name: "Pat Quill", declined: true)]), profiles: profiles, people: [])
        XCTAssertTrue(roster.voiceless.isEmpty)
    }

    func testAnInviteeWithAProfileButNoVoiceIsVoiceless() {
        let roster = InviteRoster(invite: CallInvite(guests: [Guest(email: "pat@example.com")]),
                                  profiles: [profile("Pat Quill", voice: false, email: "pat@example.com")], people: [])
        XCTAssertEqual(roster.voiceless.map(\.label), ["Pat Quill"])
    }

    func testTheLabelOfAVoicelessInvitee() {
        let saved = Person(id: PersonID(rawValue: "p-pat"), displayName: "Pat Quill", origin: .voiceNaming, at: .distantPast)
        func label(_ g: Guest) -> String? { InviteRoster(invite: CallInvite(guests: [g]), profiles: [], people: [saved]).voiceless.first?.label }
        XCTAssertEqual(label(Guest(personID: "p-pat")), "Pat Quill")
        XCTAssertEqual(label(Guest(name: "Quill, Pat")), "Pat Quill")
        XCTAssertEqual(label(Guest(name: "Robin Ash")), "Robin Ash")
        XCTAssertEqual(label(Guest(email: "robin.ash@example.com")), "Robin Ash")
        XCTAssertEqual(label(Guest(email: "rash@example.com")), "rash@example.com")
    }

    func testALabelThatIsAnotherSavedVoiceIsNoLabel() {
        // An address that reads as the name of a voice already saved is not proof that it is that person.
        let roster = InviteRoster(invite: CallInvite(guests: [Guest(email: "dale.fenwick@other.example")]), profiles: profiles, people: [])
        XCTAssertEqual(roster.voiceless.count, 1)
        XCTAssertNil(roster.voiceless[0].label)
        let d = InviteVoiceRules.decide([voice("them:A", [("Mira Stone", 0.3)])], roster: roster, owner: owner)
        XCTAssertEqual(d.verdicts["them:A"], .unknown)
    }

    func testTheInviteOfARecord() {
        var r = CallRecord(id: "c", platform: .zoom, bundleID: "", start: .distantPast, end: .distantPast, status: .transcribed)
        XCTAssertNil(CallInvite(record: r))
        r.attendees = ["Mira Stone", "jo@example.com"]
        XCTAssertEqual(CallInvite(record: r)?.guests, [Guest(name: "Mira Stone"), Guest(email: "jo@example.com")])
        r.invitees = [Invitee(name: owner, email: "avery@example.com", isSelf: true), Invitee(name: nil, email: "jo@example.com", personID: "p-jo", response: "declined")]
        XCTAssertEqual(CallInvite(record: r)?.guests, [Guest(email: "jo@example.com", personID: "p-jo", declined: true)])
    }

    func testTheLogLineHasCountsAndScoresAndNoNames() {
        let invite = CallInvite(guests: [Guest(email: "mira@example.com"), Guest(email: "jo.fenwick@example.com")])
        let d = decide([voice("them:A", [("Mira Stone", 0.9)]), voice("them:B", [("Dale Fenwick", 0.74), ("Mira Stone", 0.2)])], invite)
        XCTAssertFalse(d.logLine.contains("Fenwick"))
        XCTAssertFalse(d.logLine.contains("Mira"))
        XCTAssertTrue(d.logLine.contains("0.74"), d.logLine)
    }
}
