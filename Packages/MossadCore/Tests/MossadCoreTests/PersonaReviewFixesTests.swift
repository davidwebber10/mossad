import XCTest
@testable import MossadCore

/// The review of the person reads: a call that changes is read again, the 2-call rule waits for real answers, and
/// the smaller fixes. Stub models only.
final class PersonaReviewFixesTests: XCTestCase {
    private let t0 = PersonaTraitsTests.t0
    private var root: URL!
    private var paths: Paths { Paths(root: root) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("persona-fixes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func person(_ name: String, owner: Bool = false) -> Person { Person(displayName: name, isOwner: owner, origin: .voiceNaming, at: t0) }
    private lazy var dana = person("Dana Lee", owner: true)
    private lazy var sam = person("Sam Carter")
    private lazy var riley = person("Riley Chen")
    private static let filler = "We went through the lanes and the carriers and the schedule for the next quarter in some detail today."

    /// A 1:1 where the voice "them:A" reacts to the owner's number.
    private func call(_ id: String = "c1", day: Int = 1, voice: String) -> CallRecord {
        let start = t0.addingTimeInterval(Double(day) * 86_400)
        var r = CallRecord(id: id, platform: .zoom, bundleID: "", start: start, end: start.addingTimeInterval(1800), status: .written)
        r.customTitle = "Plan \(id)"
        r.speakerNames = ["me:A": "Dana Lee", "them:A": voice]
        r.utterances = [
            Utterance(track: .me, speakerLabel: "A", start: 0, end: 5, text: "I propose we move 40% of the volume next month."),
            Utterance(track: .them, speakerLabel: "A", start: 6, end: 20, text: "Compared with what? " + [Self.filler, Self.filler, Self.filler, Self.filler].joined(separator: " ")),
        ]
        return r
    }

    private func save(_ r: CallRecord) throws {
        try FileManager.default.createDirectory(at: paths.callDirectory(r.id), withIntermediateDirectories: true)
        try r.save(to: paths.callDirectory(r.id))
    }

    private let comparison: [String: Any] = ["line": 1, "person": "P1", "quote": "Compared with what?", "dimension": "evidence", "value": "comparison", "label": "",
                                             "strength": "clear", "role": "decides"]

    private func run(since: Date? = nil) async -> PersonaRunner.Report {
        await PersonaRunner(paths: paths, llm: PersonaStubModel(evidence: [comparison]), owner: "Dana Lee").run(since: since, isLive: { false })
    }

    private func calls(of p: Person) -> Set<String> { (try? PersonaStore(paths: paths).load(p.id.rawValue))?.calls ?? [] }

    // MARK: H1

    func testScenarioAAVoiceCorrectedToAnotherPersonMovesTheEvidence() async throws {
        try PeopleStore(directory: paths.people).replaceAll([dana, sam, riley])
        var r = call(voice: "Sam Carter")
        try save(r)
        _ = await run()
        XCTAssertEqual(calls(of: sam), ["c1"])
        r.speakerNames["them:A"] = "Riley Chen"
        try save(r)
        let again = await run()
        XCTAssertEqual(again.calls, 1, "the stamp changed: the call is read again")
        XCTAssertEqual(calls(of: sam), [], "Sam keeps nothing of Riley's voice")
        XCTAssertEqual(calls(of: riley), ["c1"])
        let p = try XCTUnwrap(try PersonaStore(paths: paths).load(riley.id.rawValue)).evidence[0].pointer
        let saved = CoachPeople(people: [dana, sam, riley])
        XCTAssertNotNil(p.utterance(in: r, person: riley.id.rawValue, saved: saved))
        XCTAssertNil(p.utterance(in: r, person: sam.id.rawValue, saved: saved), "a line is someone's only while its speaker is that person")
    }

    func testScenarioBAVoiceNamedAfterTheStepIsReadAgain() async throws {
        try PeopleStore(directory: paths.people).replaceAll([dana, sam])
        var r = call(voice: "Speaker A")
        try save(r)
        _ = await run()
        XCTAssertEqual(calls(of: sam), [])
        r.speakerNames["them:A"] = "Sam Carter"
        try save(r)
        _ = await run(since: t0.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(calls(of: sam), ["c1"], "read before and changed: due again, also when older than the start of the in-app step")
    }

    func testScenarioCTranscribeAgainReplacesTheCallsEvidence() async throws {
        try PeopleStore(directory: paths.people).replaceAll([dana, sam])
        var r = call(voice: "Sam Carter")
        try save(r)
        _ = await run()
        let before = try XCTUnwrap(try PersonaStore(paths: paths).load(sam.id.rawValue)).evidence.map(\.pointer.line)
        r.utterances[1].text = "Compared with what, exactly? " + [Self.filler, Self.filler, Self.filler, Self.filler].joined(separator: " ")
        try save(r)
        XCTAssertFalse(PersonaLedger.load(from: PersonaStore(paths: paths).directory).isRead(r))
        _ = await run()
        let after = try XCTUnwrap(try PersonaStore(paths: paths).load(sam.id.rawValue)).evidence
        XCTAssertEqual(after.count, 1, "the old evidence of the call is replaced, not added to")
        XCTAssertNotEqual(after.map(\.pointer.line), before)
        XCTAssertNotNil(after[0].pointer.utterance(in: r))
        let unchanged = await run()
        XCTAssertEqual(unchanged.calls, 0, "the same call is not read twice")
    }

    func testALedgerOfAnEarlierBuildReadsAndEachCallIsReadAgainOnce() throws {
        let old = #"{"calls": {"c1": 1}, "written": {}}"#
        let ledger = try JSONDecoder.coach.decode(PersonaLedger.self, from: Data(old.utf8))
        XCTAssertFalse(ledger.isRead(call(voice: "Sam Carter")))
    }

    func testACallThatFailsThreeTimesIsLeftOut() async throws {
        try PeopleStore(directory: paths.people).replaceAll([dana, sam])
        let r = call(voice: "Sam Carter")
        try save(r)
        for _ in 0..<2 {
            let report = await PersonaRunner(paths: paths, llm: FailingModel(), owner: "Dana Lee").run(since: nil, isLive: { false })
            XCTAssertEqual(report.stopped, "an error")
        }
        let third = await PersonaRunner(paths: paths, llm: FailingModel(), owner: "Dana Lee").run(since: nil, isLive: { false })
        XCTAssertNil(third.stopped)
        XCTAssertTrue(PersonaLedger.load(from: PersonaStore(paths: paths).directory).isRead(r))
    }

    // MARK: H2

    private func twoCallPersona() -> Persona {
        var p = Persona(person: "p1", updated: t0)
        p.evidence = [PersonaTraitsTests.moment(1, series: "a"), PersonaTraitsTests.moment(4, series: "b")]
        p.texts["p1|order|answer_first|any"] = PersonaText(statement: "Sam asks for the answer first.", soDoThis: "Open with the answer.", rating: .high,
                                                           written: t0, calls: 2, counter: 0)
        return p
    }

    private func answers(_ yes: Int, _ no: Int) -> [FindingAnswer] {
        (0..<(yes + no)).map { i in
            FindingAnswer(CoachFinding(id: "c|trait|q|x\(i)|v|any", callID: "c", date: t0, kind: .trait, text: "t", skill: "", person: "q", trait: "q|x\(i)|v|any"),
                          verdict: i < yes ? .yes : .no, date: t0)
        }
    }

    func testATwoCallTraitShowsOnlyAfterTheOwnersYesUntilRealAnswers() throws {
        let p = twoCallPersona()
        let t = try XCTUnwrap(PersonaTraits.build(p, answers: []).first)
        XCTAssertFalse(t.isShown, "no real answers yet: the 2-call rule is off")
        XCTAssertEqual(t.state, .candidate, "a question in the deck")
        let yes = FindingAnswer(CoachFinding(id: "c4|trait|\(t.id)", callID: "c4", date: t0, kind: .trait, text: "t", skill: "", person: "p1", trait: t.id), verdict: .yes, date: t0)
        XCTAssertEqual(PersonaTraits.build(p, answers: [yes]).first?.state, .confirmed)
        XCTAssertFalse(PersonaConfidence.twoCallRuleOn(answers(23, 7)), "30 answers, 77% yes")
        XCTAssertTrue(PersonaConfidence.twoCallRuleOn(answers(24, 6)), "30 answers, 80% yes")
        XCTAssertTrue(try XCTUnwrap(PersonaTraits.build(p, answers: answers(24, 6)).first { $0.person == "p1" }).isShown, "real answers turn the rule on")
        XCTAssertFalse(PersonaConfidence.twoCallRuleOn(answers(20, 0)), "too few answers")
    }

    func testTheEvalNeverLowersTheThresholdAndJudgesItOnlyWithTwentyTraits() throws {
        let gold = try PersonaGold.load(from: PersonaEvalTests.goldDir)
        func scored(_ n: Int, correct: Int, confidence: Double) -> [PersonaEval.Scored] {
            (0..<n).map { i in PersonaEval.Scored(person: "Sam Carter", checkpoint: 6, dimension: "order", value: "v\(i)", condition: nil, statement: "s", confidence: confidence,
                                                  days: 4, shown: true, correct: i < correct, passesWords: true, refused: nil, twoCalls: false) }
        }
        func report(_ t: [PersonaEval.Scored]) -> [String] {
            PersonaEval.metrics(PersonaEval.Report(model: "m", requests: 0, cachedReplies: 0, spent: 0, stoppedAtCap: false, proposed: 0, kept: 0, traits: t, lines: []), gold: gold)
        }
        XCTAssertTrue(report(scored(10, correct: 5, confidence: 0.6)).contains { $0.contains("fewer than 20: no advice") })
        XCTAssertTrue(report(scored(25, correct: 25, confidence: 0.6)).contains { $0.contains("No change: the eval never lowers it") })
        let mixed = scored(20, correct: 10, confidence: 0.6) + scored(20, correct: 20, confidence: 0.8).map { var s = $0; s.value += "b"; return s }
        XCTAssertTrue(report(mixed).contains { $0.hasPrefix("Threshold: raise to") })
        let lines = report(scored(25, correct: 25, confidence: 0.6))
        XCTAssertTrue(lines[0].hasPrefix("Limits:") && lines[1].hasPrefix("Sample:") && lines[2].contains("never turns it on"))
        XCTAssertTrue(lines.contains { $0.contains("low end of the 95% range") }, "each share with its sample")
    }

    // MARK: M2, M15, L3

    func testTheWordCheckTakesOneToOneAndAConditionAndRefusesMotivesAndCharacterWords() {
        let act = "Ask for the no before the meeting ends."
        XCTAssertTrue(PersonaWords.passes(statement: "In a 1:1, Sam says no directly.", soDoThis: act))
        XCTAssertTrue(PersonaWords.passes(statement: "When a plan is new, Sam asks who owns each step.", soDoThis: act))
        XCTAssertFalse(PersonaWords.passes(statement: "Sam wants control of each decision.", soDoThis: act))
        for word in ["impatient", "stubborn", "defensive", "micromanages", "medical", "maternity"] {
            XCTAssertFalse(PersonaWords.passes(statement: "Sam asks questions when \(word) comes up.", soDoThis: act), word)
        }
        XCTAssertTrue(PersonaWords.passes(statement: "Sam asks what the price compares with.", soDoThis: act, names: ["Jo Price"], person: "Sam"), "a name has its capital")
        XCTAssertFalse(PersonaWords.passes(statement: "Sam asks Price before deciding.", soDoThis: act, names: ["Jo Price"], person: "Sam"))
    }

    func testARefusedSentenceIsDueAgainAtTheNextCall() {
        var t = PersonaTrait(id: "p|order|answer_first|any", person: "p", dimension: "order", value: "answer_first", condition: nil,
                             support: [1, 4].map { PersonaTraitsTests.moment($0) }, counter: [], supportDays: 2, counterDays: 0,
                             text: PersonaText(statement: "", soDoThis: "", rating: .medium, written: t0, calls: 2, counter: 0), answer: nil, confidence: 0.4, state: .candidate)
        XCTAssertFalse(PersonaWriter.needsText(t))
        t.support.append(PersonaTraitsTests.moment(7))
        XCTAssertTrue(PersonaWriter.needsText(t))
    }

    func testAFirstNameIsReplacedOnlyWithItsCapital() {
        XCTAssertEqual(PersonaExtractor.replaceNames("Will said we will see.", [("Will", "P1")]), "P1 said we will see.")
        XCTAssertEqual(PersonaExtractor.replaceNames("ask will park", [("Will Park", "P1")]), "ask P1")
    }

    // MARK: M10, M11, M12, M13, M14, M7, M5

    func testAnAnswerKeepsItsTraitThroughAnOlderBuild() {
        let card = CoachFinding(id: "c1|trait|p|order|answer_first|any", callID: "c1", date: t0, kind: .trait, text: "t", skill: "", person: "p", trait: "p|order|answer_first|any")
        let full = FindingAnswer(card, verdict: .never, date: t0)
        var stripped = full
        stripped.trait = nil
        stripped.person = nil
        let merged = CoachProfile.mergedAnswers([full], [stripped])
        XCTAssertEqual(merged.first?.trait, "p|order|answer_first|any")
        XCTAssertEqual(merged.first?.person, "p")
        XCTAssertEqual(stripped.traitID, "p|order|answer_first|any", "the card id still names the trait")
    }

    func testTheCountSaysHowManyCallsWithThePersonAndTheOpposite() {
        var p = Persona(person: "p", updated: t0)
        p.evidence = [1, 4, 7].map { PersonaTraitsTests.moment($0) }
        p.texts["p|order|answer_first|any"] = PersonaText(statement: "Sam asks for the answer first.", soDoThis: "Open with it.", rating: .medium, written: t0, calls: 3, counter: 0)
        let s = PersonaSummary.make(p, answers: [], name: "Sam Carter", callsWith: 22)
        XCTAssertEqual(s?.traits.first?.confidenceLine, "Likely, seen in 3 of 22 calls")
        var t = s!.traits[0]
        t.counterCalls = 1
        XCTAssertEqual(t.countLine, "seen in 3 of 22 calls, the opposite in 1")
    }

    func testNoTraitFeedsTheAvoidLineAndPaceNeverShows() {
        XCTAssertEqual(PersonaCard.LineKind.of(dimension: "pace", value: "short_turns"), .open)
        XCTAssertEqual(PersonaCard.LineKind.of(dimension: "free:rollout", value: "small"), .ask)
        var p = Persona(person: "p", updated: t0)
        p.evidence = (1...6).map { PersonaTraitsTests.moment($0 * 3, "pace", "short_turns") }
        p.texts["p|pace|short_turns|any"] = PersonaText(statement: "Sam asks short questions.", soDoThis: "Keep it short.", rating: .high, written: t0, calls: 6, counter: 0)
        XCTAssertFalse(PersonaTraits.build(p, answers: []).contains(where: \.isShown), "pace follows the meeting's format")
    }

    func testExpectsHasAFixedListAndAFreeLabelWithATopicWordIsDropped() async throws {
        XCTAssertEqual(PersonaDimension.normalized(dimension: "expects", value: "short_updates")?.value, "short_updates")
        XCTAssertNil(PersonaDimension.normalized(dimension: "expects", value: "status_note_first"))
        let saved = CoachPeople(people: [dana, sam])
        var r = call(voice: "Sam Carter")
        r.customTitle = "Freight lanes"
        let model = PersonaStubModel(evidence: [
            ["line": 1, "person": "P1", "quote": "Compared with what?", "dimension": "free", "value": "freight_first", "label": "focus", "strength": "clear", "role": "decides"],
            ["line": 1, "person": "P1", "quote": "Compared with what?", "dimension": "free", "value": "asks_back", "label": "reply", "strength": "clear", "role": "decides"],
        ])
        let speakers = PersonaExtractor.speakers(in: r, saved: saved, owner: "Dana Lee", excluded: [])
        let result = try await PersonaExtractor(llm: model).extract(r, speakers: speakers, owner: "Dana Lee")
        XCTAssertEqual(result.evidence[sam.id.rawValue]?.map(\.dimension), ["free:reply"])
    }

    func testOtherAIAppsGetTheReadsOnlyWhenEachSwitchIsOn() {
        XCTAssertTrue(MCPServer.showsPersonas(coachEnabled: true, personaEnabled: true, personaInMCP: true))
        XCTAssertFalse(MCPServer.showsPersonas(coachEnabled: true, personaEnabled: false, personaInMCP: true))
        XCTAssertFalse(MCPServer.showsPersonas(coachEnabled: false, personaEnabled: true, personaInMCP: true))
        XCTAssertFalse(MCPServer.showsPersonas(coachEnabled: true, personaEnabled: true, personaInMCP: false))
    }

    func testACallAppWindowWithNoTitleMeansTheShareIsNotKnown() {
        XCTAssertNil(OwnerShare.isSharing([("zoom.us", nil), ("Finder", "Documents")]), "the call app's titles cannot be read")
        XCTAssertEqual(OwnerShare.isSharing([("zoom.us", "Zoom Meeting"), ("Finder", "Documents")]), false)
    }

    func testMoreInvitedPeopleThanVoicesIsAGroup() {
        var r = call(voice: "Sam Carter")
        XCTAssertEqual(PersonaExtractor.setting(r, owner: "Dana Lee"), .oneOnOne)
        r.invitees = [Invitee(name: "Dana Lee", email: nil, isSelf: true), Invitee(name: "Sam Carter", email: nil), Invitee(name: "Riley Chen", email: nil)]
        XCTAssertEqual(PersonaExtractor.setting(r, owner: "Dana Lee"), .group)
    }
}

/// A model that fails as a network does.
final class FailingModel: LanguageModel, @unchecked Sendable {
    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort, purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        throw URLError(.timedOut)
    }
    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String { "" }
}
