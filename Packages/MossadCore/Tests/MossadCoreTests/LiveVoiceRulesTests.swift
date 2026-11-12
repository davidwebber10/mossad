import XCTest
@testable import MossadCore

/// The live transcript's names: the pipeline's invite rules, enough speech, a clear lead, and a name that changes
/// only when a later fingerprint clearly disagrees.
final class LiveVoiceRulesTests: XCTestCase {
    typealias Guest = CallInvite.Guest
    static let owner = "Avery Lane"

    static func profile(_ name: String, email: String? = nil, owner: Bool = false) -> VoiceProfile {
        VoiceProfile(name: name, isOwner: owner, embeddings: [[1, 0, 0, 0]], email: email)
    }

    static let profiles = [
        profile(owner, email: "avery@example.com", owner: true),
        profile("Rob Hale", email: "rob@example.com"), profile("Ned Hale", email: "ned@example.com"),
        profile("Mira Stone", email: "mira@example.com"), profile("Dale Fenwick", email: "dale@example.com"),
        profile("Kim Moss", email: "kim@example.com"),
    ]

    static func invite(_ emails: String...) -> CallInvite {
        CallInvite(guests: [Guest(name: owner, email: "avery@example.com")] + emails.map { Guest(email: $0) })
    }

    struct Case {
        var name: String
        var scores: [(String, Float)]
        var invite: CallInvite?
        var seconds: TimeInterval = 20
        var current: String?
        var mixed = false
        var provisional: [String: String] = [:]
        var room = false
        var expected: String?
    }

    let cases: [Case] = [
        // Brothers with similar voices, only one invited.
        Case(name: "the invited brother is named over his brother", scores: [("Rob Hale", 0.82), ("Ned Hale", 0.79)],
             invite: invite("rob@example.com"), expected: "Rob Hale"),
        Case(name: "the brother who was not invited needs 0.80 and a lead of 0.08", scores: [("Ned Hale", 0.84), ("Rob Hale", 0.81)],
             invite: invite("rob@example.com"), expected: nil),
        Case(name: "with no invite the brothers are too close to tell", scores: [("Rob Hale", 0.82), ("Ned Hale", 0.79)],
             invite: nil, expected: nil),
        Case(name: "a voice not invited and clearly ahead is named", scores: [("Dale Fenwick", 0.86), ("Mira Stone", 0.70)],
             invite: invite("mira@example.com"), expected: "Dale Fenwick"),
        // A provisional voice names only on a call that invites them.
        Case(name: "a provisional voice not on the invite", scores: [("Kim Moss", 0.9)], invite: invite("mira@example.com"),
             provisional: ["Kim Moss": "call-1"], expected: nil),
        Case(name: "a provisional voice on the invite", scores: [("Kim Moss", 0.9)], invite: invite("kim@example.com"),
             provisional: ["Kim Moss": "call-1"], expected: "Kim Moss"),
        Case(name: "a provisional voice with no invite", scores: [("Kim Moss", 0.9)], invite: nil,
             provisional: ["Kim Moss": "call-1"], expected: nil),
        Case(name: "a provisional voice is no rival of an invited one", scores: [("Mira Stone", 0.80), ("Kim Moss", 0.79)],
             invite: invite("mira@example.com"), provisional: ["Kim Moss": "call-1"], expected: "Mira Stone"),
        // A close second-best.
        Case(name: "two invited voices too close", scores: [("Mira Stone", 0.74), ("Dale Fenwick", 0.71)],
             invite: invite("mira@example.com", "dale@example.com"), expected: nil),
        Case(name: "two invited voices with a clear lead", scores: [("Mira Stone", 0.78), ("Dale Fenwick", 0.71)],
             invite: invite("mira@example.com", "dale@example.com"), expected: "Mira Stone"),
        Case(name: "no invite and a clear lead, as before", scores: [("Mira Stone", 0.78), ("Dale Fenwick", 0.71)],
             invite: nil, expected: "Mira Stone"),
        Case(name: "no invite and under the threshold, as before", scores: [("Mira Stone", 0.60)], invite: nil, expected: nil),
        // Enough speech.
        Case(name: "too little speech", scores: [("Mira Stone", 0.9)], invite: nil, seconds: 9, expected: nil),
        // A name that must change after more speech, without flipping.
        Case(name: "a later fingerprint clearly disagrees", scores: [("Mira Stone", 0.85), ("Dale Fenwick", 0.70)],
             invite: nil, current: "Dale Fenwick", expected: "Mira Stone"),
        Case(name: "a name given stays when it trails by a hair", scores: [("Mira Stone", 0.76), ("Dale Fenwick", 0.755)],
             invite: nil, current: "Dale Fenwick", expected: "Dale Fenwick"),
        Case(name: "a name given goes when another leads but not clearly", scores: [("Mira Stone", 0.78), ("Dale Fenwick", 0.75)],
             invite: nil, current: "Dale Fenwick", expected: nil),
        Case(name: "a name given stays a little under the threshold", scores: [("Dale Fenwick", 0.63)],
             invite: nil, current: "Dale Fenwick", expected: "Dale Fenwick"),
        Case(name: "a name given goes well under the threshold", scores: [("Dale Fenwick", 0.61)],
             invite: nil, current: "Dale Fenwick", expected: nil),
        Case(name: "a voice not invited keeps its name a little under 0.80", scores: [("Dale Fenwick", 0.78), ("Mira Stone", 0.72)],
             invite: invite("mira@example.com"), current: "Dale Fenwick", expected: "Dale Fenwick"),
        // A key with two voices.
        Case(name: "a mixed key loses its name", scores: [("Mira Stone", 0.9)], invite: nil, current: "Mira Stone", mixed: true, expected: nil),
        Case(name: "a mixed key gets no name", scores: [("Mira Stone", 0.9)], invite: nil, mixed: true, expected: nil),
        // The owner.
        Case(name: "never the owner on the call audio", scores: [(owner, 0.9)], invite: nil, expected: nil),
        Case(name: "the owner in a room", scores: [(owner, 0.9)], invite: nil, room: true, expected: owner),
    ]

    func testTheTable() {
        for c in cases {
            let roster = c.invite.map { InviteRoster(invite: $0, profiles: Self.profiles, people: []) }
            let voice = LiveVoiceRules.Voice(key: "0A", scores: c.scores.map { VoiceScore(name: $0.0, score: $0.1) }, seconds: c.seconds, mixed: c.mixed)
            let names = LiveVoiceRules.names([voice], current: c.current.map { ["0A": $0] } ?? [:], roster: roster, owner: Self.owner,
                                             provisional: c.provisional, room: c.room)
            XCTAssertEqual(names["0A"], c.expected, c.name)
        }
    }

    /// The pipeline names the one voice left as the one invited person with no voice; live, it is only the one heard so far.
    func testTheInviteDoesNotNameTheOneVoiceLeftWhileTheCallRecords() {
        let invite = CallInvite(guests: [Guest(email: "mira@example.com"), Guest(name: "Jo Park", email: "jo.park@example.com")])
        let roster = InviteRoster(invite: invite, profiles: Self.profiles, people: [])
        XCTAssertEqual(roster.voiceless.count, 1)
        let voice = LiveVoiceRules.Voice(key: "0A", scores: [VoiceScore(name: "Mira Stone", score: 0.2)], seconds: 30)
        XCTAssertEqual(LiveVoiceRules.names([voice], current: [:], roster: roster, owner: Self.owner), [:])
    }

    func testOneNameForOneKeyTheStrongerHasIt() {
        let a = LiveVoiceRules.Voice(key: "0A", scores: [VoiceScore(name: "Mira Stone", score: 0.75)], seconds: 20)
        let b = LiveVoiceRules.Voice(key: "0B", scores: [VoiceScore(name: "Mira Stone", score: 0.85)], seconds: 20)
        XCTAssertEqual(LiveVoiceRules.names([a, b], current: ["0A": "Mira Stone"], roster: nil, owner: Self.owner), ["0B": "Mira Stone"])
    }

    func testAKeyNotFingerprintedKeepsItsName() {
        let b = LiveVoiceRules.Voice(key: "1B", scores: [VoiceScore(name: "Dale Fenwick", score: 0.85)], seconds: 20)
        XCTAssertEqual(LiveVoiceRules.names([b], current: ["0A": "Mira Stone"], roster: nil, owner: Self.owner),
                       ["0A": "Mira Stone", "1B": "Dale Fenwick"])
    }

    func testEarlyAndLateSpeechThatDisagreeAreTwoVoices() {
        func piece(_ start: Double, _ v: [Float], _ seconds: Double = 5) -> SpeakerIdentifier.PieceVector {
            SpeakerIdentifier.PieceVector(start: start, seconds: seconds, vector: v)
        }
        let one: [Float] = [1, 0, 0, 0], other: [Float] = [0, 1, 0, 0], near: [Float] = [0.9, 0.3, 0, 0]
        XCTAssertEqual(LiveVoiceRules.mixed([piece(30, other), piece(0, one)]), true, "in time order, not the order of the pieces")
        XCTAssertEqual(LiveVoiceRules.mixed([piece(0, one), piece(30, near)]), false)
        XCTAssertNil(LiveVoiceRules.mixed([piece(0, one)]), "one piece cannot disagree with itself")
        XCTAssertNil(LiveVoiceRules.mixed([piece(0, one, 3), piece(30, other)]), "a half too short to say")
    }

    func testTheLiveInviteIsMatchedWithTheCallsTimesSoFar() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func event(_ from: TimeInterval, _ to: TimeInterval, _ email: String) -> CalendarEventInfo {
            CalendarEventInfo(title: "Sync", start: start.addingTimeInterval(from), end: start.addingTimeInterval(to), attendees: [email],
                              text: "https://meet.google.com/abc-defg-hij", isAllDay: false)
        }
        let events = [event(600, 2400, "later@example.com")]
        let early = CallInvite.live(platform: .meet, meetingID: "abc-defg-hij", start: start, now: start.addingTimeInterval(60), events: events)
        XCTAssertEqual(early?.sure, false, "the call has not reached the event yet")
        XCTAssertEqual(early?.guests.map(\.email), ["later@example.com"])
        let later = CallInvite.live(platform: .meet, meetingID: "abc-defg-hij", start: start, now: start.addingTimeInterval(900), events: events)
        XCTAssertEqual(later?.sure, true)
        XCTAssertNil(CallInvite.live(platform: .inPerson, meetingID: nil, start: start, now: start.addingTimeInterval(900), events: events))
    }
}
