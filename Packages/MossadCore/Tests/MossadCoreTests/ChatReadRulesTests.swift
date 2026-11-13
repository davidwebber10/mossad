import XCTest
@testable import MossadCore

/// The review's read rules: the coach's notes and older reads follow the app's show rule (R3), two people with one
/// name are never one answer (R10), the switch is read at each call (R4), the calendar file says what it could not
/// read and keeps no passcode (R6, R7), and the small truths (R13).
final class ChatReadRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var paths: Paths!

    private func person(_ id: String, _ name: String, email: String? = nil, owner: Bool = false, off: Bool = false) -> Person {
        var p = Person(id: PersonID(rawValue: id), displayName: name, isOwner: owner, origin: .migration, at: now)
        if let email { p.emails = [EmailIdentity(address: email, state: .verified, source: .owner, at: now)] }
        p.doNotProfile = off
        return p
    }

    private var people: [Person] {
        [person("id-owner", "Avery Webb", owner: true), person("id-sam", "Sam Carter", email: "sam@example.com"),
         person("id-dana", "Dana Lee", email: "dana@example.com", off: true)]
    }

    private func records() -> [CallRecord] {
        var r = CallRecord(id: "a", platform: .meet, bundleID: "b", start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(-84_600), status: .written)
        r.calendarTitle = "Planning"
        r.attendees = ["Sam Carter", "Dana Lee"]
        r.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter", "them:B": "Dana Lee"]
        r.speakerPeople = ["me:A": "id-owner", "them:A": "id-sam", "them:B": "id-dana"]
        r.utterances = [Utterance(track: .them, speakerLabel: "A", start: 0, end: 60, text: "Hello."),
                        Utterance(track: .them, speakerLabel: "B", start: 60, end: 120, text: "Hi.")]
        r.markdownPath = "/Users/someone/Mossad/Meetings/2027-01-14 0800 - Planning.md"
        return [r]
    }

    override func setUpWithError() throws {
        paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        var profile = CoachProfile()
        for (name, id) in [("Sam Carter", "id-sam"), ("Dana Lee", "id-dana")] {
            var c = CoachPerson(note: "\(name) NOTE", calls: 3, lastSeen: now)
            c.person = id
            c.brief = PersonBrief(headline: "\(name) BRIEF", sections: [], calls: 3, updated: now)
            profile.people[name] = c
        }
        profile.updateFacts(add: [CoachFact(kind: .relationship, text: "Dana FACT", person: "id-dana"), CoachFact(kind: .role, text: "Head of data")], remove: [])
        try profile.save(to: paths.coach)
    }

    private func tools(personas: Bool = true, people list: [Person]? = nil) -> ChatTools {
        ChatTools(records: records(), owner: "Avery Webb", paths: paths, people: list ?? people, personaTraits: personas, settings: ToolSettings(), now: now)
    }

    // MARK: R3

    func testPeopleGiveNoNoteOrBriefOfAPersonWhoKeepsNoReadAndNoneWithTheSwitchOff() {
        let on = tools().run("people", input: [:])
        XCTAssertTrue(on.contains("Sam Carter NOTE") && on.contains("Sam Carter BRIEF"), on)
        XCTAssertFalse(on.contains("Dana Lee NOTE") || on.contains("Dana Lee BRIEF"), on)
        let off = tools(personas: false).run("people", input: [:])
        XCTAssertFalse(off.contains("NOTE") || off.contains("BRIEF"), off)
    }

    func testReadPersonFollowsTheSameRule() {
        XCTAssertTrue(tools().run("read_person", input: ["person": "id-sam"]).contains("Sam Carter BRIEF"))
        XCTAssertFalse(tools(personas: false).run("read_person", input: ["person": "id-sam"]).contains("BRIEF"))
        let dana = tools().run("read_person", input: ["person": "id-dana"])
        XCTAssertFalse(dana.contains("BRIEF") || dana.contains("NOTE") || dana.contains("Dana FACT"), dana)
        XCTAssertFalse(dana.contains("learns nothing"), "not a claim the coach keeps today")
    }

    func testCoachProfileLeavesOutWhatTheCoachLearnedAboutAPersonWhoKeepsNoRead() {
        let on = tools().run("coach_profile", input: [:])
        XCTAssertTrue(on.contains("Sam Carter NOTE") && on.contains("Head of data"), on)
        XCTAssertFalse(on.contains("Dana Lee NOTE") || on.contains("Dana FACT"), on)
        let off = tools(personas: false).run("coach_profile", input: [:])
        XCTAssertFalse(off.contains("NOTE"), off)
        XCTAssertTrue(off.contains("Head of data"), "the owner's own facts stay")
    }

    func testPrepGivesNoReadOfAPersonWhoKeepsNoneOrWithTheSwitchOff() throws {
        let e = CalendarEventInfo(title: "Planning", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(5400),
                                  attendees: ["Sam Carter", "Dana Lee"], text: "https://meet.google.com/abc-defg-hij", isAllDay: false)
        try CalendarSnapshot([e], saved: now).save(to: paths.calendar)
        let on = tools().run("prep", input: [:])
        XCTAssertTrue(on.contains("Sam Carter BRIEF"), on)
        XCTAssertFalse(on.contains("Dana Lee BRIEF"), on)
        XCTAssertFalse(tools(personas: false).run("prep", input: [:]).contains("BRIEF"))
    }

    func testTheProfileForTheServerLeavesOutEveryPersonWhoKeepsNoRead() throws {
        let profile = try CoachProfile.load(from: paths.coach)
        let sent = profile.withoutCoachData(on: CoachPeople(people: people))
        XCTAssertNil(sent.people["Dana Lee"])
        XCTAssertNotNil(sent.people["Sam Carter"])
        XCTAssertFalse(sent.facts.contains { $0.person == "id-dana" })
        XCTAssertTrue(sent.facts.contains { $0.text == "Head of data" })
        let payload = String(decoding: SharedPayload.profile(profile, people: people).data, as: UTF8.self)
        XCTAssertFalse(payload.contains("Dana Lee NOTE") || payload.contains("Dana FACT"), payload)
    }

    // MARK: R10

    func testTwoPeopleWithOneNameAreNeverOneAnswer() {
        let two = people + [person("id-sam2", "Sam Carter", email: "sam2@example.com")]
        let list = tools(people: two).run("people", input: [:])
        XCTAssertFalse(list.contains("person_id: id-sam |") || list.contains("person_id: id-sam2"), list)
        XCTAssertTrue(list.contains("two saved people have this name"), list)
        let read = tools(people: two).run("read_person", input: ["person": "Sam Carter"])
        XCTAssertTrue(read.contains("person_id: id-sam") && read.contains("person_id: id-sam2") && read.contains("Several saved people"), read)
        let one = tools(people: two).run("read_person", input: ["person": "id-sam2"])
        XCTAssertTrue(one.contains("two saved people have this name"), one)
        XCTAssertFalse(one.contains("Sam Carter BRIEF"), "a read by the name could be the other one")
    }

    // MARK: R4

    func testTheMCPReadsTheSwitchAtEachCall() throws {
        try JSONEncoder.callRecord.encode(SyncedPersonas([])).write(to: paths.coach.appendingPathComponent(SyncedPersonas.fileName))
        let flag = Flag()
        let server = MCPServer(paths: paths, owner: "Avery Webb", settings: {
            var s = ToolSettings()
            s.coach = true
            s.personaInMCP = flag.on
            return s
        })
        func people() -> String {
            let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"coach_profile","arguments":{}}}"#
            return server.handle(line) ?? ""
        }
        flag.on = true
        XCTAssertTrue(people().contains("Sam Carter NOTE"))
        flag.on = false
        XCTAssertFalse(people().contains("Sam Carter NOTE"), "the switch turned off reaches the running process")
    }

    // MARK: R6, R7

    func testACalendarMossadCouldNotReadIsSaidSoNeverNoCalls() throws {
        var s = CalendarSnapshot([], saved: now)
        s.access = CalendarSnapshot.Access(mac: .no, google: .no)
        try s.save(to: paths.calendar)
        XCTAssertTrue(tools().run("upcoming_meetings", input: [:]).contains("Mossad has no access to the calendar"))
        XCTAssertTrue(tools().run("prep", input: [:]).contains("Mossad has no access to the calendar"))
        s.access = CalendarSnapshot.Access(mac: .yes, google: .failed)
        try s.save(to: paths.calendar)
        XCTAssertTrue(tools().run("upcoming_meetings", input: [:]).contains("Google's calendar could not be read"))
    }

    func testTheCalendarFileKeepsNoPasscodeOnlyUsefulEventsAndOnlyTheOwnersAccess() throws {
        let call = CalendarEventInfo(title: "Planning", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(5400),
                                     attendees: ["Sam Carter"], text: "https://zoom.us/j/123456?pwd=SECRETPASS#x", isAllDay: false,
                                     participants: [Invitee(name: "Sam Carter", email: "sam@example.com")])
        let lunch = CalendarEventInfo(title: "Lunch", start: now, end: now.addingTimeInterval(3600), attendees: [], text: "Cafe", isAllDay: false)
        let allDay = CalendarEventInfo(title: "Holiday", start: now, end: now.addingTimeInterval(86_400), attendees: [], text: "https://zoom.us/j/9", isAllDay: true)
        try CalendarSnapshot([call, lunch, allDay], saved: now).save(to: paths.calendar)
        let url = paths.calendar.appendingPathComponent(CalendarSnapshot.fileName)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(text.contains("SECRETPASS"))
        XCTAssertTrue(text.contains("123456") && text.contains("zoom.us"))
        XCTAssertFalse(text.contains("Lunch") || text.contains("Holiday"), "only the events the lists and the series can use")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for event in json["events"] as? [[String: Any]] ?? [] {
            for p in event["participants"] as? [[String: Any]] ?? [] {
                XCTAssertTrue(Set(p.keys).isSubset(of: CalendarSnapshot.allowedKeys["participant"]!), "\(p.keys)")
            }
        }
    }

    // MARK: R13

    func testAMeetingLineNamesItsNoteWithoutTheAccount() {
        let text = tools().run("find_meetings", input: [:])
        XCTAssertTrue(text.contains("note: 2027-01-14 0800 - Planning.md"), text)
        XCTAssertFalse(text.contains("/Users/someone"), text)
    }

    func testTheTasksListTakesASmallLimit() throws {
        var book = CommitmentBook()
        book.items = (1...8).map { Commitment(text: "Task \($0)", to: nil, callID: nil, callTitle: nil, madeAt: now, due: nil) }
        try book.save(to: paths.commitments)
        let lines = tools().run("commitments", input: ["limit": 3]).split(separator: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(lines.count, 3)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var on: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
