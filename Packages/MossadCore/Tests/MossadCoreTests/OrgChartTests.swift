import XCTest
@testable import MossadCore

final class OrgChartTests: XCTestCase {
    private let csv = """
    \u{FEFF}"Last Name","First Name","Position Title","Supervisor"
    "Park","Sam","VP Planning",""
    "Lee","Dana","Director, Finance","Park, Sam"
    "Rivera","Alex","Analyst","Lee, Dana"
    "Chen","Benjamin","Analyst","Lee, Dana"
    "Stone","Mary Ann","Manager","Park, Sam"
    "Quinn","Pat","Engineer","Park, Sam"
    "Quinn","Pat","Designer","Lee, Dana"
    "Ng","Zachary","Intern","Nobody, Here"
    "Fox","Kim","Coordinator","Lee, Dana"
    "Fox","Jim","Coordinator","Lee, Dana"
    "Moss","Jamie","Clerk","Stone, Mary Ann"
    "Gray","Lou","Clerk","Stone, Mary Ann"
    "Gray","Max","Clerk","Quinn, Pat"
    "Ode","Rae","Clerk","Lee, Dana"
    "Orr","Chris","Clerk","Lee, Dana"
    """

    private func chart() throws -> OrgChart { try OrgChart.parse(csv: csv) }

    func testParsesWithBomAndQuotedCommas() throws {
        let c = try chart()
        XCTAssertEqual(c.people.count, 15)
        XCTAssertEqual(c.person(id: "lee, dana")?.title, "Director, Finance")
        XCTAssertNil(c.person(id: "park, sam")?.managerID)
    }

    func testRejectsAFileWithoutTheColumns() {
        XCTAssertThrowsError(try OrgChart.parse(csv: "\"Name\",\"Boss\"\n\"A\",\"B\"\n"))
    }

    func testMissingSupervisorIsTheRootAndUnknownSupervisorIsNil() throws {
        let c = try chart()
        XCTAssertNil(c.person(id: "park, sam")?.managerID)
        XCTAssertNil(c.person(id: "ng, zachary")?.managerID)
        XCTAssertEqual(c.chain(of: "rivera, alex"), ["lee, dana", "park, sam"])
    }

    func testBareCommaSupervisorIsNoSupervisor() throws {
        let c = try OrgChart.parse(csv: "\"Last Name\",\"First Name\",\"Position Title\",\"Supervisor\"\n\"Lee\",\"Dana\",\"Lead\",\",\"\n")
        XCTAssertNil(c.person(id: "lee, dana")?.managerID)
    }

    func testManagerReportsAndPeers() throws {
        let c = try chart()
        XCTAssertEqual(c.manager(of: "rivera, alex")?.id, "lee, dana")
        XCTAssertTrue(c.reports(of: "lee, dana").map(\.id).contains("rivera, alex"))
        XCTAssertEqual(Set(c.peers(of: "rivera, alex").map(\.id)).isSuperset(of: ["chen, benjamin"]), true)
        XCTAssertFalse(c.peers(of: "rivera, alex").map(\.id).contains("rivera, alex"))
    }

    func testExactMatchIgnoresCaseAndSpacing() throws {
        let m = try chart().person(matching: "  dana   LEE ", overrides: OrgMatches())
        XCTAssertEqual(m?.person.id, "lee, dana")
        XCTAssertEqual(m?.how, .exact)
    }

    func testMiddleNameInTheFileStillMatchesOnTheFirstWord() throws {
        let m = try chart().person(matching: "Mary Stone", overrides: OrgMatches())
        XCTAssertEqual(m?.person.id, "stone, mary ann")
        XCTAssertEqual(try chart().person(matching: "Mary Ann Stone", overrides: OrgMatches())?.how, .exact)
    }

    func testNicknameMatchNeedsTheSameLastName() throws {
        let c = try chart()
        let m = c.person(matching: "Ben Chen", overrides: OrgMatches())
        XCTAssertEqual(m?.person.id, "chen, benjamin")
        XCTAssertEqual(m?.how, .nickname)
        XCTAssertEqual(c.person(matching: "Zach Ng", overrides: OrgMatches())?.how, .nickname)
        XCTAssertNil(c.person(matching: "Ben Park", overrides: OrgMatches()))
    }

    func testNicknameWorksBothWays() throws {
        let c = try OrgChart.parse(csv: "\"Last Name\",\"First Name\",\"Position Title\",\"Supervisor\"\n\"Fox\",\"Jim\",\"Lead\",\"\"\n")
        XCTAssertEqual(c.person(matching: "James Fox", overrides: OrgMatches())?.how, .nickname)
    }

    func testDuplicateFullNamesGetNoAutomaticMatch() throws {
        XCTAssertNil(try chart().person(matching: "Pat Quinn", overrides: OrgMatches()))
    }

    func testDuplicateNamesKeepSeparateIDs() throws {
        let c = try chart()
        XCTAssertEqual(c.people.filter { $0.last == "Quinn" }.count, 2)
        XCTAssertEqual(Set(c.people.map(\.id)).count, c.people.count)
    }

    func testDuplicateIDsDoNotDependOnRowOrder() throws {
        let head = "\"Last Name\",\"First Name\",\"Position Title\",\"Supervisor\"\n"
        let a = "\"Quinn\",\"Pat\",\"Engineer\",\"Park, Sam\"\n", b = "\"Quinn\",\"Pat\",\"Designer\",\"Lee, Dana\"\n"
        let one = try OrgChart.parse(csv: head + a + b), two = try OrgChart.parse(csv: head + b + a)
        func id(_ c: OrgChart, _ title: String) -> String? { c.people.first { $0.title == title }?.id }
        XCTAssertEqual(id(one, "Engineer"), id(two, "Engineer"))
        XCTAssertEqual(id(one, "Designer"), id(two, "Designer"))
        XCTAssertNotEqual(id(one, "Engineer"), id(one, "Designer"))
    }

    func testSameNameAndTitleAreToldApartBySupervisor() throws {
        let head = "\"Last Name\",\"First Name\",\"Position Title\",\"Supervisor\"\n"
        let a = "\"Quinn\",\"Pat\",\"Analyst\",\"Park, Sam\"\n", b = "\"Quinn\",\"Pat\",\"Analyst\",\"Lee, Dana\"\n"
        let one = try OrgChart.parse(csv: head + a + b), two = try OrgChart.parse(csv: head + b + a)
        XCTAssertEqual(Set(one.people.map(\.id)), Set(two.people.map(\.id)))
        XCTAssertEqual(Set(one.people.map(\.id)).count, 2)
    }

    func testAManualMatchToAnIdThatIsGoneIsUnmatched() throws {
        var o = OrgMatches()
        o.set("Dana Lee", to: "quinn, pat#2")
        XCTAssertNil(try chart().person(matching: "Dana Lee", overrides: o))
    }

    func testMultiWordLastNamesMatchOnEverySplit() throws {
        let c = try OrgChart.parse(csv: "\"Last Name\",\"First Name\",\"Position Title\",\"Supervisor\"\n\"De La Cruz\",\"Maria\",\"Lead\",\"\"\n\"Van Dyke\",\"Benjamin\",\"Lead\",\"\"\n")
        XCTAssertEqual(c.person(matching: "Maria De La Cruz", overrides: OrgMatches())?.how, .exact)
        XCTAssertEqual(c.person(matching: "Ben Van Dyke", overrides: OrgMatches())?.how, .nickname)
        XCTAssertNil(c.person(matching: "Maria Cruz", overrides: OrgMatches()))
    }

    func testManualMatchWinsAndPicksADuplicate() throws {
        let c = try chart()
        let quinn = c.people.filter { $0.last == "Quinn" }.map(\.id)
        var o = OrgMatches()
        o.set("Pat Quinn", to: quinn[1])
        let m = c.person(matching: "pat quinn", overrides: o)
        XCTAssertEqual(m?.person.id, quinn[1])
        XCTAssertEqual(m?.how, .manual)
        o.set("Dana Lee", to: "park, sam")
        XCTAssertEqual(c.person(matching: "Dana Lee", overrides: o)?.person.id, "park, sam")
    }

    func testOutsideMarksAPersonAsNotInTheCompany() throws {
        var o = OrgMatches()
        o.setOutside("Dana Lee")
        XCTAssertNil(try chart().person(matching: "Dana Lee", overrides: o))
        XCTAssertTrue(o.isOutside("dana lee"))
    }

    func testMatchesRoundTripThroughDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = Paths(root: dir)
        var o = OrgMatches()
        o.set("Pat Quinn", to: "quinn, pat")
        o.setOutside("Ann Out")
        try o.save(paths: paths)
        let back = OrgMatches.load(paths: paths)
        XCTAssertEqual(back, o)
        XCTAssertEqual(OrgMatches.load(paths: Paths(root: dir.appendingPathComponent("none"))), OrgMatches())
    }

    func testImportCopiesTheFileAndLoadReadsIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("export.csv")
        try csv.write(to: src, atomically: true, encoding: .utf8)
        let paths = Paths(root: dir.appendingPathComponent("root"))
        XCTAssertNil(OrgChart.load(paths: paths))
        let imported = try OrgChart.import(from: src, paths: paths)
        XCTAssertEqual(imported.people.count, 15)
        XCTAssertEqual(OrgChart.load(paths: paths)?.people.count, 15)
        let bad = dir.appendingPathComponent("bad.csv")
        try "x,y\n1,2\n".write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try OrgChart.import(from: bad, paths: paths))
        XCTAssertEqual(OrgChart.load(paths: paths)?.people.count, 15)
    }

    func testContextLinesNameTheTitleOfMatchedSpeakers() throws {
        let lines = try chart().contextLines(for: ["Sam Park", "Speaker B", "Zach Ng"], overrides: OrgMatches())
        XCTAssertEqual(lines, ["Sam Park, VP Planning", "Zach Ng, Intern"])
    }

    func testThePromptsCarryThePeopleLines() {
        var r = CallRecord(id: "x", platform: .meet, bundleID: "", start: Date(), end: Date(), status: .written)
        r.speakerNames = ["me:A": "Avery Lane"]
        let coach = CoachPrompt.user(record: r, owner: "Avery Lane", profile: CoachProfile(), people: ["Sam Park, VP Planning"])
        XCTAssertTrue(coach.contains("Sam Park, VP Planning"))
        XCTAssertFalse(CoachPrompt.user(record: r, owner: "Avery Lane", profile: CoachProfile()).contains("Job titles"))
        let summary = LLMSummarizer.userPrompt(knownTags: [], title: "Sync", transcript: "t", people: ["Sam Park, VP Planning"])
        XCTAssertTrue(summary.contains("Sam Park, VP Planning"))
        XCTAssertEqual(LLMSummarizer.userPrompt(knownTags: [], title: "Sync", transcript: "t", people: []), "Meeting: Sync\n\nTranscript:\nt")
    }

    func testParsesTwoThousandRowsQuickly() throws {
        var big = "\"Last Name\",\"First Name\",\"Position Title\",\"Supervisor\"\n\"Root\",\"Rita\",\"Head\",\"\"\n"
        for i in 0..<2000 { big += "\"L\(i)\",\"F\(i)\",\"Title, \(i)\",\"Root, Rita\"\n" }
        let start = Date()
        let c = try OrgChart.parse(csv: big)
        XCTAssertEqual(c.people.count, 2001)
        XCTAssertEqual(c.reports(of: "root, rita").count, 2000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
    }

    func testLevelsCountTheDeepestChain() throws {
        XCTAssertEqual(try chart().levels, 3)
        XCTAssertEqual(try OrgChart.parse(csv: OrgChart.templateCSV).levels, 0)
    }

    func testTheTemplateHasTheFourColumnsAndNoPeople() throws {
        XCTAssertEqual(OrgChart.templateCSV, "Last Name,First Name,Position Title,Supervisor\n")
        XCTAssertTrue(try OrgChart.parse(csv: OrgChart.templateCSV).people.isEmpty)
    }

    func testTeamAroundAPersonIsTheirManagerThenThemAndPeersWithReports() throws {
        let team = try chart().team(around: "lee, dana")
        XCTAssertEqual(team.top?.id, "park, sam")
        XCTAssertEqual(team.columns.map(\.head.fullName), ["Dana Lee", "Pat Quinn", "Mary Ann Stone"])
        XCTAssertEqual(team.columns[0].reports.map(\.fullName), ["Benjamin Chen", "Jim Fox", "Kim Fox", "Rae Ode", "Chris Orr", "Pat Quinn", "Alex Rivera"])
        XCTAssertEqual(team.columns[2].reports.map(\.fullName), ["Lou Gray", "Jamie Moss"])
        XCTAssertEqual(team.focus, "lee, dana")
    }

    func testTeamAroundTheTopIsTheTopThenItsReports() throws {
        let team = try chart().team(around: "park, sam")
        XCTAssertEqual(team.top?.id, "park, sam")
        XCTAssertEqual(team.columns.map(\.head.fullName), ["Dana Lee", "Pat Quinn", "Mary Ann Stone"])
    }

    func testTeamAroundAPersonWithNoManagerInTheFileStandsAlone() throws {
        let team = try chart().team(around: "ng, zachary")
        XCTAssertEqual(team.top?.id, "ng, zachary")
        XCTAssertTrue(team.columns.isEmpty)
        XCTAssertNil(try chart().team(around: "nobody").top)
    }
}
