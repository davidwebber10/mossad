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
        /// No later fingerprint comes: the full bar, with no slack.
        var final = false
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
        Case(name: "a last fingerprint gets no slack", scores: [("Dale Fenwick", 0.63)],
             invite: nil, current: "Dale Fenwick", final: true, expected: nil),
        Case(name: "a last fingerprint keeps a name that passes the full bar", scores: [("Dale Fenwick", 0.70)],
             invite: nil, current: "Dale Fenwick", final: true, expected: "Dale Fenwick"),
        // The invited brother keeps his name while his brother, not invited, leads by a little.
        Case(name: "an invited name stays while one not invited leads by 0.02", scores: [("Ned Hale", 0.82), ("Rob Hale", 0.80)],
             invite: invite("rob@example.com"), current: "Rob Hale", expected: "Rob Hale"),
        Case(name: "an invited name goes when one not invited leads by 0.04", scores: [("Ned Hale", 0.84), ("Rob Hale", 0.80)],
             invite: invite("rob@example.com"), current: "Rob Hale", expected: nil),
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
            let voice = LiveVoiceRules.Voice(key: "0A", scores: c.scores.map { VoiceScore(name: $0.0, score: $0.1) }, seconds: c.seconds,
                                             mixed: c.mixed, final: c.final)
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

    func voice(_ key: String, _ scores: [(String, Float)], vector: [Float]? = nil) -> LiveVoiceRules.Voice {
        LiveVoiceRules.Voice(key: key, scores: scores.map { VoiceScore(name: $0.0, score: $0.1) }, seconds: 20, vector: vector)
    }

    /// One key through a call: named, kept within the slack, dropped, and not named again below the full lead.
    func testOneKeyAcrossFingerprints() {
        var current: [String: String] = [:]
        let steps: [([(String, Float)], String?)] = [
            ([("Mira Stone", 0.78), ("Dale Fenwick", 0.70)], "Mira Stone"),
            ([("Mira Stone", 0.74), ("Dale Fenwick", 0.745)], "Mira Stone"),
            ([("Dale Fenwick", 0.76), ("Mira Stone", 0.73)], nil),
            ([("Mira Stone", 0.75), ("Dale Fenwick", 0.73)], nil),
            ([("Mira Stone", 0.79), ("Dale Fenwick", 0.73)], "Mira Stone"),
        ]
        for (i, step) in steps.enumerated() {
            current = LiveVoiceRules.names([voice("0A", step.0)], current: current, roster: nil, owner: Self.owner)
            XCTAssertEqual(current["0A"], step.1, "step \(i)")
        }
    }

    /// After a pause the service gives the same person a new key: both keep the name when their voices agree.
    func testOnePersonOnTheKeysOfTwoSessions() {
        let a = voice("0A", [("Sam Lee", 0.82)], vector: [1, 0.1, 0, 0]), b = voice("1B", [("Sam Lee", 0.84)], vector: [1, 0, 0.1, 0])
        XCTAssertEqual(LiveVoiceRules.names([a, b], current: ["0A": "Sam Lee"], roster: nil, owner: Self.owner),
                       ["0A": "Sam Lee", "1B": "Sam Lee"])
        let other = voice("1B", [("Sam Lee", 0.84)], vector: [0, 1, 0, 0])
        XCTAssertEqual(LiveVoiceRules.names([a, other], current: ["0A": "Sam Lee"], roster: nil, owner: Self.owner), ["0A": "Sam Lee"],
                       "two voices that do not agree are not one person: the key with the name keeps it")
        let same = voice("0B", [("Sam Lee", 0.90)], vector: [1, 0, 0.1, 0])
        XCTAssertEqual(LiveVoiceRules.names([a, same], current: [:], roster: nil, owner: Self.owner), ["0B": "Sam Lee"],
                       "in one session one name is one key")
    }

    /// Two keys of one session that both sound like one person: the key with the name keeps it unless the other
    /// leads clearly, so it does not pass back and forth.
    func testTheKeyWithTheNameKeepsItUnlessTheOtherLeadsClearly() {
        let a = voice("0A", [("Sam Lee", 0.80)]), c = voice("0C", [("Sam Lee", 0.83)])
        XCTAssertEqual(LiveVoiceRules.names([a, c], current: ["0A": "Sam Lee"], roster: nil, owner: Self.owner), ["0A": "Sam Lee"])
        let clear = voice("0C", [("Sam Lee", 0.86)])
        XCTAssertEqual(LiveVoiceRules.names([a, clear], current: ["0A": "Sam Lee"], roster: nil, owner: Self.owner), ["0C": "Sam Lee"])
    }

    func testAKeyNotFingerprintedLosesANameTheRulesNoLongerAllow() {
        let roster = InviteRoster(invite: Self.invite("mira@example.com"), profiles: Self.profiles, people: [])
        XCTAssertEqual(LiveVoiceRules.names([], current: ["0A": "Kim Moss", "0B": Self.owner, "0C": "Mira Stone"], roster: roster,
                                            owner: Self.owner, provisional: ["Kim Moss": "call-1"]), ["0C": "Mira Stone"])
    }

    func testEarlyAndLateSpeechThatDisagreeAreTwoVoices() {
        func piece(_ start: Double, _ v: [Float], _ seconds: Double = 10) -> SpeakerIdentifier.PieceVector {
            SpeakerIdentifier.PieceVector(start: start, seconds: seconds, vector: v)
        }
        func at(_ cosine: Float) -> [Float] { [cosine, (1 - cosine * cosine).squareRoot(), 0, 0] }
        let one: [Float] = [1, 0, 0, 0]
        XCTAssertEqual(LiveVoiceRules.halves([piece(30, at(0)), piece(0, one)])?.mixed, true, "in time order, not the order of the pieces")
        XCTAssertEqual(LiveVoiceRules.halves([piece(0, one), piece(30, at(0.3))])?.mixed, true)
        XCTAssertEqual(LiveVoiceRules.halves([piece(0, one), piece(30, at(0.45))])?.mixed, false, "pieces of one voice can agree this little")
        XCTAssertEqual(LiveVoiceRules.halves([piece(0, one), piece(30, at(0.6))])?.mixed, false)
        XCTAssertEqual(LiveVoiceRules.halves([piece(0, one), piece(30, at(0.6))])?.cosine ?? 0, 0.6, accuracy: 0.001)
        XCTAssertNil(LiveVoiceRules.halves([piece(0, one)]), "one piece cannot disagree with itself")
        XCTAssertNil(LiveVoiceRules.halves([piece(0, one, 5), piece(30, at(0), 5)]), "halves under one full piece are too short to say")
        XCTAssertEqual(LiveVoiceRules.halves([piece(0, one), piece(30, at(0))])?.settled, false, "10 s halves can be decided again")
        XCTAssertEqual(LiveVoiceRules.halves([piece(0, one), piece(10, one, 5), piece(30, at(0)), piece(40, at(0), 5)])?.settled, true)
    }

    func event(_ from: TimeInterval, _ to: TimeInterval, _ email: String, link: String = "https://meet.google.com/abc-defg-hij") -> CalendarEventInfo {
        CalendarEventInfo(title: "Sync", start: Self.start.addingTimeInterval(from), end: Self.start.addingTimeInterval(to), attendees: [email],
                          text: link, isAllDay: false)
    }
    static let start = Date(timeIntervalSince1970: 1_000_000)

    func testTheLiveInviteIsTheOneTheCallShows() {
        let start = Self.start
        let events = [event(600, 2400, "later@example.com")]
        let early = CallInvite.live(platform: .meet, meetingID: "abc-defg-hij", start: start, now: start.addingTimeInterval(60), events: events)
        XCTAssertEqual(early?.guests.map(\.email), ["later@example.com"])
        XCTAssertNil(CallInvite.live(platform: .inPerson, meetingID: nil, start: start, now: start.addingTimeInterval(900), events: events))
    }

    /// The owner joins the second of two meetings on one link two minutes early: the meeting that ends is not it.
    func testInTheFirstMinutesTheMeetingThatEndsIsNotTheInvite() {
        let start = Self.start
        let events = [event(-1680, 120, "first@example.com"), event(120, 1920, "second@example.com")]
        for id in ["abc-defg-hij", nil] {
            let invite = CallInvite.live(platform: .meet, meetingID: id, start: start, now: start.addingTimeInterval(60), events: events)
            XCTAssertEqual(invite?.guests.map(\.email), ["second@example.com"], "meeting id \(id ?? "none")")
        }
    }

    func testTheInviteOfAnEventIsTheInviteOfARecordWithIt() {
        var e = event(0, 1800, "x@example.com")
        e.participants = [Invitee(name: "Mira Stone", email: "mira@example.com"), Invitee(name: "Avery Lane", email: "avery@example.com", isSelf: true),
                          Invitee(name: "Room 4", email: "room4@example.com", kind: "resource"),
                          Invitee(name: "Dale Fenwick", email: "dale@example.com", response: "declined")]
        var r = CallRecord(id: "c", platform: .meet, bundleID: "", start: Self.start, end: Self.start.addingTimeInterval(1800), status: .written)
        r.setInvite(e)
        XCTAssertEqual(CallInvite(event: e, sure: true), CallInvite(record: r, sure: true))
        e.participants = []
        r.setInvite(e)
        XCTAssertEqual(CallInvite(event: e, sure: false), CallInvite(record: r, sure: false))
    }
}
