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

    func voice(_ key: String, _ scores: [(String, Float)], seconds: Double = 60) -> InviteVoiceRules.Voice {
        InviteVoiceRules.Voice(key: key, scores: scores.map { VoiceScore(name: $0.0, score: $0.1) }, fingerprint: true, seconds: seconds)
    }

    func decide(_ voices: [InviteVoiceRules.Voice], _ invite: CallInvite?, profiles: [VoiceProfile]? = nil, people: [Person] = [],
                provisional: [String: String] = [:], call: String = "call-2") -> InviteVoiceRules.Decision {
        let roster = invite.map { InviteRoster(invite: $0, profiles: profiles ?? self.profiles, people: people) }
        return InviteVoiceRules.decide(voices, roster: roster, owner: owner, provisional: provisional, callID: call)
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
        XCTAssertEqual(d.verdicts["them:B"], .inferred("Jo Fenwick", learn: true))
        XCTAssertEqual(d.inferred?.guest.email, "jo.fenwick@example.com")
        XCTAssertEqual(d.inferred?.source, .address)
        XCTAssertEqual(d.fromInvite, ["them:B"])
    }

    // A person's second address on the invite is still that person: their saved voice is invited, so no other voice
    // is taken for them.
    func testAnInvitedPersonsSecondAddressFindsTheirVoice() {
        var mira = profile("Mira Stone", email: "mira@example.com")
        mira.moreEmails = ["m.stone@example-group.test"]
        let invite = CallInvite(guests: [Guest(email: "m.stone@example-group.test")])
        let d = decide([voice("them:A", [("Dale Fenwick", 0.5)])], invite, profiles: [profile(owner, owner: true), mira, profile("Dale Fenwick")])
        XCTAssertNil(d.inferred)
        XCTAssertEqual(d.verdicts["them:A"] ?? .unknown, .unknown)
        let roster = InviteRoster(invite: invite, profiles: [mira], people: [])
        XCTAssertTrue(roster.invited.contains("Mira Stone"))
        XCTAssertTrue(roster.voiceless.isEmpty)
    }

    func testTheNamingFieldOpensEmptyForANameFromTheInviteEvenWithTwoAddresses() {
        let both = ["jo.fenwick@example.com", "jo@example-group.test"]
        XCTAssertEqual(NamingPrefill.email(fromInvite: true, addresses: both), "")
        XCTAssertEqual(NamingPrefill.email(fromInvite: false, addresses: both), "jo.fenwick@example.com")
        XCTAssertEqual(NamingPrefill.email(fromInvite: false, addresses: []), "")
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

    func testTheLeftVoiceNearAnInvitedVoiceThatHasANameIsNotInferred() {
        // One person can be two speaker keys: a part of Mira's voice that scores low is not the invitee with no voice.
        let invite = CallInvite(guests: [Guest(name: "Mira Stone"), Guest(email: "jo.fenwick@example.com")])
        let d = decide([voice("them:A", [("Mira Stone", 0.9)]), voice("them:B", [("Mira Stone", 0.6)])], invite)
        XCTAssertEqual(d.verdicts["them:B"], .unknown)
        XCTAssertNil(d.inferred)
    }

    func testAShortVoiceIsNamedFromTheInviteButNotLearned() {
        let invite = CallInvite(guests: [Guest(email: "jo.fenwick@example.com")])
        let d = decide([voice("them:A", [("Dale Fenwick", 0.3)], seconds: 8)], invite)
        XCTAssertEqual(d.verdicts["them:A"], .inferred("Jo Fenwick", learn: false))
    }

    func testAnInviteThatIsNotSurelyTheCallsNamesNobodyByRuleFour() {
        let invite = CallInvite(guests: [Guest(email: "jo.fenwick@example.com")], sure: false)
        let d = decide([voice("them:A", [("Dale Fenwick", 0.3)])], invite)
        XCTAssertEqual(d.verdicts["them:A"], .unknown)
    }

    func testARoomOrAGroupIsNotAnInvitedPerson() {
        let invite = CallInvite(guests: [Guest(name: "Board Room 4", person: false), Guest(email: "team@example.com", person: false),
                                         Guest(email: "jo.fenwick@example.com")])
        let roster = InviteRoster(invite: invite, profiles: profiles, people: [])
        XCTAssertEqual(roster.guests, 1)
        XCTAssertEqual(roster.voiceless.map(\.label), ["Jo Fenwick"])
    }

    func testAGuestWhoMayBeTheOwnerStopsRuleFour() {
        for guest in [Guest(email: "avery@personal.example"), Guest(name: "Avery")] {
            let invite = CallInvite(guests: [guest, Guest(name: "Mira Stone")])
            let roster = InviteRoster(invite: invite, profiles: profiles, people: [])
            XCTAssertTrue(roster.ownerDoubt)
            XCTAssertTrue(roster.voiceless.isEmpty)
            let d = InviteVoiceRules.decide([voice("them:A", [("Dale Fenwick", 0.3)])], roster: roster, owner: owner)
            XCTAssertEqual(d.verdicts["them:A"], .unknown)
        }
    }

    func testAGuestWhoMayBeASavedVoiceIsThatVoiceAndNoNewPerson() {
        let invite = CallInvite(guests: [Guest(name: "Mira")])
        let near = decide([voice("them:A", [("Mira Stone", 0.72)])], invite)
        XCTAssertEqual(near.verdicts["them:A"], .named("Mira Stone", score: 0.72, learn: false))
        XCTAssertNil(near.inferred)
        let far = decide([voice("them:A", [("Dale Fenwick", 0.4)])], invite)
        XCTAssertEqual(far.verdicts["them:A"], .unknown)
    }

    // A voice learned from one invite.

    func testAProvisionalVoiceNamesNobodyWhoIsNotInvited() {
        let p = ["Jo Fenwick": "call-1"]
        let profiles = self.profiles + [profile("Jo Fenwick", email: "jo.fenwick@example.com")]
        let other = decide([voice("them:A", [("Jo Fenwick", 0.97), ("Mira Stone", 0.1)])], CallInvite(guests: [Guest(name: "Mira Stone")]),
                           profiles: profiles, provisional: p)
        XCTAssertEqual(other.verdicts["them:A"], .withheld(suggestion: VoiceScore(name: "Jo Fenwick", score: 0.97)))
        let none = decide([voice("them:A", [("Jo Fenwick", 0.97)])], nil, provisional: p)
        XCTAssertEqual(none.verdicts["them:A"], .withheld(suggestion: VoiceScore(name: "Jo Fenwick", score: 0.97)))
    }

    func testAProvisionalVoiceOnAnotherCallThatInvitesThem() {
        let p = ["Jo Fenwick": "call-1"]
        let profiles = self.profiles + [profile("Jo Fenwick", email: "jo.fenwick@example.com")]
        let invite = CallInvite(guests: [Guest(email: "jo.fenwick@example.com")])
        let sure = decide([voice("them:A", [("Jo Fenwick", 0.85)])], invite, profiles: profiles, provisional: p)
        XCTAssertEqual(sure.verdicts["them:A"], .named("Jo Fenwick", score: 0.85, learn: true))
        XCTAssertTrue(sure.fromInvite.isEmpty)
        let weak = decide([voice("them:A", [("Jo Fenwick", 0.7)])], invite, profiles: profiles, provisional: p)
        XCTAssertEqual(weak.verdicts["them:A"], .named("Jo Fenwick", score: 0.7, learn: false))
        XCTAssertEqual(weak.fromInvite, ["them:A"])
    }

    func testAProvisionalVoiceOnItsOwnCallStaysFromTheInvite() {
        // "Transcribe again": the voice is learned again as the invite's, not as a sure match.
        let profiles = self.profiles + [profile("Jo Fenwick", email: "jo.fenwick@example.com")]
        let d = decide([voice("them:A", [("Jo Fenwick", 1)])], CallInvite(guests: [Guest(email: "jo.fenwick@example.com")]),
                       profiles: profiles, provisional: ["Jo Fenwick": "call-1"], call: "call-1")
        XCTAssertEqual(d.verdicts["them:A"], .inferred("Jo Fenwick", learn: true))
        XCTAssertEqual(d.fromInvite, ["them:A"])
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

    // An old id from a company domain rule is not proof: the person must have the guest's address or whole name.
    func testAnOldPersonIDNeedsTheGuestsAddressOrWholeName() {
        var dale = Person(id: PersonID(rawValue: "p-dale"), displayName: "Dale Fenwick", origin: .voiceNaming, at: .distantPast)
        dale.addEmail("dale@acme.test", state: .verified, source: .owner, at: .distantPast)
        let other = InviteRoster(invite: CallInvite(guests: [Guest(email: "d.f@acme-group.test", personID: "p-dale")]), profiles: profiles, people: [dale])
        XCTAssertFalse(other.invited.contains("Dale Fenwick"))
        let own = InviteRoster(invite: CallInvite(guests: [Guest(email: "dale@acme.test", personID: "p-dale")]), profiles: profiles, people: [dale])
        XCTAssertTrue(own.invited.contains("Dale Fenwick"))
        let named = InviteRoster(invite: CallInvite(guests: [Guest(name: "Fenwick, Dale", email: "d.f@acme-group.test", personID: "p-dale")]),
                                 profiles: profiles, people: [dale])
        XCTAssertTrue(named.invited.contains("Dale Fenwick"))
    }

    func testAFirstNameAloneIsNotASureMatch() {
        let roster = InviteRoster(invite: CallInvite(guests: [Guest(name: "Mira")]), profiles: profiles, people: [])
        XCTAssertFalse(roster.invited.contains("Mira Stone"))
        XCTAssertEqual(roster.voiceless.map(\.fits), [["Mira Stone"]])
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
        XCTAssertEqual(label(Guest(name: "Fenwick, Jo")), "Jo Fenwick")
        XCTAssertEqual(label(Guest(name: "FENWICK Jo")), "Jo Fenwick")
        // A speaker's name shows in the note: an address is never one.
        XCTAssertNil(label(Guest(email: "rash@example.com")))
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
        XCTAssertNil(CallInvite(record: r, sure: true))
        r.attendees = ["Mira Stone", "jo@example.com"]
        XCTAssertEqual(CallInvite(record: r, sure: true)?.guests, [Guest(name: "Mira Stone"), Guest(email: "jo@example.com")])
        r.invitees = [Invitee(name: owner, email: "avery@example.com", isSelf: true), Invitee(name: nil, email: "jo@example.com", personID: "p-jo", response: "declined"),
                     Invitee(name: "Board Room 4", email: nil, kind: "room")]
        XCTAssertEqual(CallInvite(record: r, sure: false)?.guests, [Guest(email: "jo@example.com", personID: "p-jo", declined: true),
                                                                   Guest(name: "Board Room 4", person: false)])
        XCTAssertEqual(CallInvite(record: r, sure: false)?.sure, false)
    }

    func testTheLogLineHasCountsAndScoresAndNoNames() {
        let invite = CallInvite(guests: [Guest(email: "mira@example.com"), Guest(email: "jo.fenwick@example.com")])
        let d = decide([voice("them:A", [("Mira Stone", 0.9)]), voice("them:B", [("Dale Fenwick", 0.74), ("Mira Stone", 0.2)])], invite)
        XCTAssertFalse(d.logLine.contains("Fenwick"))
        XCTAssertFalse(d.logLine.contains("Mira"))
        XCTAssertTrue(d.logLine.contains("0.74"), d.logLine)
    }

    func testADirectoryNameReplacesANameReadFromAnAddress() {
        let read = Person(displayName: "Robin Ash", origin: .address, at: .distantPast)
        XCTAssertTrue(DirectoryMerge.canTakeName(read))
        var typed = read
        typed.rename(to: "Robin Ashford", source: .owner, at: .distantPast)
        XCTAssertFalse(DirectoryMerge.canTakeName(typed))
    }

    func testTheMacCalendarsAnswersAndKinds() {
        XCTAssertEqual(EventKitCalendarSource.response(.declined), "declined")
        XCTAssertEqual(EventKitCalendarSource.response(.pending), "needsAction")
        XCTAssertNil(EventKitCalendarSource.response(.unknown))
        XCTAssertEqual(EventKitCalendarSource.kind(.room), "room")
        XCTAssertEqual(EventKitCalendarSource.kind(.group), "group")
        XCTAssertNil(EventKitCalendarSource.kind(.person))
        XCTAssertTrue(Invitee.make(name: "Board Room", address: nil, isCurrentUser: false, kind: "room")?.isPerson == false)
    }

    func testTheCallsEventIsSureByItsLinkOrWhenNoOtherCouldBeIt() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ title: String, _ text: String) -> CalendarEventInfo {
            CalendarEventInfo(title: title, start: t0, end: t0.addingTimeInterval(1800), attendees: [], text: text, isAllDay: false)
        }
        let a = event("A", "https://zoom.us/j/111"), b = event("B", "https://zoom.us/j/222")
        let end = t0.addingTimeInterval(1500)
        XCTAssertEqual(CalendarMatcher.match(for: .zoom, meetingID: nil, start: t0, end: end, in: [a])?.sure, true)
        XCTAssertEqual(CalendarMatcher.match(for: .zoom, meetingID: nil, start: t0, end: end, in: [a, b])?.sure, false)
        XCTAssertEqual(CalendarMatcher.match(for: .zoom, meetingID: "222", start: t0, end: end, in: [a, b])?.event.title, "B")
        XCTAssertEqual(CalendarMatcher.match(for: .zoom, meetingID: "222", start: t0, end: end, in: [a, b])?.sure, true)
    }

    func testAMeetingIdAloneDoesNotMakeAnEventFromAnotherTimeSure() {
        // A personal room has one id for all its meetings: an event that ended before the call is not the call's.
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let earlier = CalendarEventInfo(title: "A", start: t0.addingTimeInterval(-3600), end: t0.addingTimeInterval(-300),
                                        attendees: [], text: "https://zoom.us/j/111", isAllDay: false)
        XCTAssertEqual(CalendarMatcher.match(for: .zoom, meetingID: "111", start: t0, end: t0.addingTimeInterval(1800), in: [earlier])?.sure, false)
    }

    func testOnTheCallThatMadeItOnlyOneVoiceOfTheCallAudioIsTheInvitesAgain() {
        let profiles = self.profiles + [profile("Jo Fenwick", email: "jo.fenwick@example.com")]
        let d = decide([voice("them:B", [("Jo Fenwick", 1)]), voice("them:C", [("Jo Fenwick", 0.8)]), voice("me:B", [("Jo Fenwick", 0.99)])],
                       CallInvite(guests: [Guest(email: "jo.fenwick@example.com")]), profiles: profiles,
                       provisional: ["Jo Fenwick": "call-1"], call: "call-1")
        XCTAssertEqual(d.verdicts["them:B"], .inferred("Jo Fenwick", learn: true))
        XCTAssertEqual(d.verdicts["them:C"], .named("Jo Fenwick", score: 0.8, learn: false))
        XCTAssertEqual(d.verdicts["me:B"], .named("Jo Fenwick", score: 0.99, learn: false))
    }

    func testASavedPersonShownAsAnAddressIsNoLabel() {
        let saved = Person(id: PersonID(rawValue: "p-x"), displayName: "pq@example.com", origin: .calendar, at: .distantPast)
        let roster = InviteRoster(invite: CallInvite(guests: [Guest(personID: "p-x")]), profiles: [], people: [saved])
        XCTAssertNil(roster.voiceless.first?.label)
    }
}
