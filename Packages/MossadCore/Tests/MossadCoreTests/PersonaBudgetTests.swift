import XCTest
@testable import MossadCore

/// The budget of older calls: the first fill, calls read again after a change, and the owner's yes. Stub models
/// only; the money is the stub's usage log.
final class PersonaBudgetTests: XCTestCase {
    private let t0 = PersonaTraitsTests.t0
    private var root: URL!
    private var paths: Paths { Paths(root: root) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("persona-budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: Paths(root: root).usage, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: The pure rules

    func testAboveTheCapOrAnUnknownPriceSendsNothingUntilTheOwnersYes() {
        var b = PersonaBudget()
        XCTAssertEqual(b.decide(backlog: 0, estimate: 0, priceKnown: true, free: false, model: "m", referencesReady: true, now: t0), .done)
        XCTAssertEqual(b.decide(backlog: 5, estimate: 0.3, priceKnown: true, free: false, model: "m", referencesReady: false, now: t0), .wait(.people))
        XCTAssertEqual(b.decide(backlog: 300, estimate: 3, priceKnown: true, free: false, model: "m", referencesReady: true, now: t0),
                       .wait(.overEstimate(calls: 300, dollars: 3)))
        XCTAssertEqual(b.decide(backlog: 30, estimate: 0, priceKnown: false, free: false, model: "m", referencesReady: true, now: t0),
                       .wait(.unknownPrice(calls: 30, model: "m")))
        XCTAssertEqual(b.decide(backlog: 30, estimate: 0, priceKnown: false, free: true, model: "llama", referencesReady: true, now: t0), .read(dollars: nil, calls: nil),
                       "a model on the Mac costs nothing")
        b.approve(model: "m", estimate: 3, priceKnown: true, backlog: 300, now: t0)
        XCTAssertEqual(b.decide(backlog: 300, estimate: 3, priceKnown: true, free: false, model: "m", referencesReady: true, now: t0), .read(dollars: 3.75, calls: nil))
        XCTAssertEqual(b.decide(backlog: 300, estimate: 3, priceKnown: true, free: false, model: "other", referencesReady: true, now: t0),
                       .wait(.overEstimate(calls: 300, dollars: 3)), "the yes is for that model only")
        var u = PersonaBudget()
        u.approve(model: "m", estimate: 0, priceKnown: false, backlog: 30, now: t0)
        XCTAssertEqual(u.decide(backlog: 30, estimate: 0, priceKnown: false, free: false, model: "m", referencesReady: true, now: t0), .read(dollars: nil, calls: 30))
        u.record(dollars: 0, calls: 30, model: "m", now: t0)
        XCTAssertEqual(u.decide(backlog: 5, estimate: 0, priceKnown: false, free: false, model: "m", referencesReady: true, now: t0),
                       .wait(.unknownPrice(calls: 5, model: "m")), "an unknown price: a number of calls, never unlimited")
    }

    func testTheCapHoldsAcrossLaunchesForThirtyDays() throws {
        var b = PersonaBudget()
        b.record(dollars: 0.7, calls: 60, model: "m", now: t0)
        b.save(to: root)
        let again = PersonaBudget.load(from: root)
        XCTAssertEqual(again.decide(backlog: 40, estimate: 0.5, priceKnown: true, free: false, model: "m", referencesReady: true, now: t0.addingTimeInterval(3600)),
                       .read(dollars: 0.3, calls: nil), "the first start was with this model")
        var spent = again
        spent.record(dollars: 0.3, calls: 20, model: "m", now: t0.addingTimeInterval(7200))
        XCTAssertEqual(spent.decide(backlog: 20, estimate: 0.3, priceKnown: true, free: false, model: "m", referencesReady: true, now: t0.addingTimeInterval(86_400)),
                       .wait(.capReached(calls: 20, spent: 1, cap: 1)))
        XCTAssertEqual(spent.decide(backlog: 20, estimate: 0.3, priceKnown: true, free: false, model: "m", referencesReady: true, now: t0.addingTimeInterval(31 * 86_400)),
                       .read(dollars: 1, calls: nil), "a new window of 30 days")
        XCTAssertNotNil(PersonaBudget.Wait.capReached(calls: 20, spent: 1, cap: 1).text)
        XCTAssertNil(PersonaBudget.Wait.people.text)
    }

    // MARK: The phases, with a stub

    private func person(_ name: String, owner: Bool = false) -> Person { Person(displayName: name, isOwner: owner, origin: .voiceNaming, at: t0) }
    private lazy var dana = person("Dana Lee", owner: true)
    private lazy var sam = person("Sam Carter")
    /// Calls are dated from today: a new call is one of the last 7 days by the clock.
    private let base = PersonaBudget.second(Date()).addingTimeInterval(-200 * 86_400)
    private static let filler = "We went through the lanes and the carriers and the schedule for the next quarter in some detail today."

    private func calls(_ n: Int, firstDay: Int = 0, voice: String = "Sam Carter") throws {
        for i in 0..<n {
            let start = base.addingTimeInterval(Double(firstDay + i) * 86_400)
            var r = CallRecord(id: "c\(firstDay + i)", platform: .zoom, bundleID: "", start: start, end: start.addingTimeInterval(1800), status: .written)
            r.customTitle = "Plan \(i)"
            r.speakerNames = ["me:A": "Dana Lee", "them:A": voice]
            r.utterances = [
                Utterance(track: .me, speakerLabel: "A", start: 0, end: 5, text: "I propose we move 40% of the volume next month."),
                Utterance(track: .them, speakerLabel: "A", start: 6, end: 20, text: "Compared with what? " + [Self.filler, Self.filler, Self.filler, Self.filler].joined(separator: " ")),
            ]
            try FileManager.default.createDirectory(at: paths.callDirectory(r.id), withIntermediateDirectories: true)
            try r.save(to: paths.callDirectory(r.id))
        }
    }

    /// Costs $0.05 for each request, in its usage log; a bad reply for the call ids in `bad`.
    private func model(bad: Set<String> = []) -> CostModel { CostModel(usage: UsageLog(directory: paths.usage), bad: bad) }

    private func run(_ m: CostModel, since: Date, ready: Bool = true, now: Date? = nil) async -> PersonaBacklog.Outcome {
        let usage = UsageLog(directory: paths.usage)
        return await PersonaBacklog.run(runner: PersonaRunner(paths: paths, llm: m, owner: "Dana Lee"), paths: paths, owner: "Dana Lee", model: "claude-sonnet-5-5",
                                        service: .claude, since: since, referencesReady: ready, now: { now ?? Date() },
                                        spent: { from in usage.all().filter { $0.date >= from }.reduce(0) { $0 + ($1.costUSD ?? 0) } }, isLive: { false })
    }

    func testABadReplyNeverEndsTheFillAndTheCapHolds() async throws {
        try PeopleStore(directory: paths.people).replaceAll([dana, sam])
        try calls(30)
        let m = model(bad: ["c29"])
        let since = base.addingTimeInterval(100 * 86_400)
        let first = await run(m, since: since)
        XCTAssertEqual(first.olderCalls.handled, 20, "the cap of $1 at $0.05 each, with the bad reply among them")
        XCTAssertEqual(first.decision, .wait(.capReached(calls: 10, spent: PersonaBudget.load(from: PersonaStore(paths: paths).directory).spent(now: Date()), cap: 1)))
        XCTAssertNotNil(first.note)
        let before = m.reads
        let second = await run(m, since: since)
        XCTAssertEqual(m.reads, before, "a new launch: the cap still holds for call reads; a person's sentences are the usual step")
        XCTAssertNotEqual(second.decision, .done, "older calls wait; the fill is not done")
    }

    func testAtTheCapNewCallsAreStillRead() async throws {
        try PeopleStore(directory: paths.people).replaceAll([dana, sam])
        try calls(30)
        let since = base.addingTimeInterval(100 * 86_400)
        _ = await run(model(), since: since)
        try calls(2, firstDay: 198)
        let m = model()
        let out = await run(m, since: since)
        XCTAssertEqual(out.newCalls.calls, 2, "the usual step for new calls, outside the budget")
        XCTAssertEqual(out.olderCalls.calls, 0)
        XCTAssertNotNil(out.note)
    }

    func testARenameMakesNoCallDueAndANamedVoiceIsAnOlderCall() async throws {
        try PeopleStore(directory: paths.people).replaceAll([dana, sam])
        try calls(3)
        let since = base.addingTimeInterval(100 * 86_400)
        _ = await run(model(), since: since)
        let store = PeopleStore(directory: paths.people)
        try store.rename(sam.id, to: "Samuel Carter")
        for i in 0..<3 {
            var r = try CallRecord.load(from: paths.callDirectory("c\(i)"))
            r.speakerNames["them:A"] = "Samuel Carter"
            try r.save(to: paths.callDirectory(r.id))
        }
        let m = model()
        let after = await run(m, since: since)
        XCTAssertEqual(m.reads, 0, "the stamp holds ids, not names")
        XCTAssertEqual(after.decision, .done)
        let owner = PersonaBacklog.split(PersonaRunner.records(paths: paths, owner: "Dana Lee"), ledger: PersonaLedger.load(from: PersonaStore(paths: paths).directory),
                                         since: since, saved: CoachPeople.read(paths: paths), owner: "Dana Lee", now: Date())
        XCTAssertTrue(owner.older.isEmpty && owner.new.isEmpty)
    }

    func testNothingRunsBeforeThePeopleHaveTheirIds() async throws {
        try PeopleStore(directory: paths.people).replaceAll([dana, sam])
        try calls(3)
        let m = model()
        let out = await run(m, since: base, ready: false)
        XCTAssertEqual(m.requests, 0, "no request at all")
        XCTAssertEqual(out.decision, .wait(.people))
        XCTAssertNil(out.note)
    }

    func testTheFillIsDoneOnlyWhenNoOlderCallIsDue() async throws {
        try PeopleStore(directory: paths.people).replaceAll([dana, sam])
        try calls(4)
        let out = await run(model(bad: ["c1"]), since: base.addingTimeInterval(100 * 86_400))
        XCTAssertEqual(out.olderCalls.handled, 4, "a call left out for good is taken up")
        XCTAssertEqual(out.decision, .done)
    }

    // MARK: Re-review 2

    func testASmallRoomLeftIsUsedUpForOlderCallsOnlyAndSentencesAreTheUsualStep() async throws {
        var b = PersonaBudget()
        b.record(dollars: 0.98, calls: 40, model: "m", now: t0)
        XCTAssertEqual(b.decide(backlog: 5, estimate: 0.05, priceKnown: true, free: false, model: "m", referencesReady: true, now: t0, request: 0.03),
                       .wait(.capReached(calls: 5, spent: 0.98, cap: 1)), "room under one request is no room")
        try PeopleStore(directory: paths.people).replaceAll([dana, sam])
        try calls(30)
        let since = base.addingTimeInterval(100 * 86_400)
        let first = await run(model(), since: since)
        XCTAssertNotNil(first.note)
        XCTAssertEqual(first.newCalls.people, 1, "at the cap, the sentences are still written: the usual step")
        // A spend that leaves a small room: the next run still writes the sentences that are due.
        var file = PersonaBudget.load(from: PersonaStore(paths: paths).directory)
        file.spends = [PersonaBudget.Spend(date: Date(), dollars: 0.98, calls: 20)]
        file.save(to: PersonaStore(paths: paths).directory)
        let m = model()
        let later = await run(m, since: since)
        XCTAssertEqual(m.reads, 0, "a room under one request reads no older call")
        XCTAssertNotNil(later.note)
    }

    func testTheOwnersYesAtTheCapGivesRealRoomOnTopOfTheSpend() {
        var b = PersonaBudget()
        b.record(dollars: 0.97, calls: 40, model: "m", now: t0)
        b.approve(model: "m", estimate: 0.06, priceKnown: true, backlog: 20, now: t0)
        guard case .read(let room?, nil) = b.decide(backlog: 20, estimate: 0.06, priceKnown: true, free: false, model: "m", referencesReady: true, now: t0, request: 0.03)
        else { return XCTFail("the yes gives room") }
        XCTAssertEqual(room, 1, accuracy: 0.01, "the yes adds at least $1 on top of what was spent")
        var big = PersonaBudget()
        big.record(dollars: 1, calls: 40, model: "m", now: t0)
        big.approve(model: "m", estimate: 20, priceKnown: true, backlog: 400, now: t0)
        XCTAssertEqual(big.decide(backlog: 400, estimate: 20, priceKnown: true, free: false, model: "m", referencesReady: true, now: t0, request: 0.03),
                       .read(dollars: 5, calls: nil), "$5 at most for each yes")
        XCTAssertEqual(PersonaBudget.yesGives(estimate: 20), 5)
        XCTAssertEqual(PersonaBudget.yesGives(estimate: 0.06), 1)
    }

    func testANewCallIsOneOfTheLastSevenDaysAndEachOtherDueCallIsAnOlderCall() throws {
        try PeopleStore(directory: paths.people).replaceAll([dana, sam])
        try calls(30)
        let saved = CoachPeople.read(paths: paths), records = PersonaRunner.records(paths: paths, owner: "Dana Lee")
        let now = base.addingTimeInterval(30 * 86_400)
        // A ledger that was lost, or reads that were off for a month: only the last 7 days are new.
        let lost = PersonaBacklog.split(records, ledger: PersonaLedger(), since: base, saved: saved, owner: "Dana Lee", now: now)
        XCTAssertEqual(lost.new.count, 7)
        XCTAssertEqual(lost.older.count, 23)
        // "Keep a read" on again: the person's calls are due and older, never new.
        var ledger = PersonaLedger()
        for r in records { ledger.markRead(r, saved: saved, owner: "Dana Lee") }
        ledger.markDue(Set(records.map(\.id)))
        let again = PersonaBacklog.split(records, ledger: ledger, since: base, saved: saved, owner: "Dana Lee", now: now)
        XCTAssertEqual(again.new.count, 0)
        XCTAssertEqual(again.older.count, 30)
    }

    func testTheModelOfTheFirstStartMustMatchForTheFillToGoOnWithoutAYes() {
        var b = PersonaBudget()
        b.record(dollars: 0.1, calls: 5, model: "free-model", now: t0)
        XCTAssertEqual(b.decide(backlog: 300, estimate: 3, priceKnown: true, free: false, model: "m", referencesReady: true, now: t0, request: 0.03),
                       .wait(.overEstimate(calls: 300, dollars: 3)), "a start with another model is no start for this one")
    }

    // MARK: Release check M1

    /// A sentence reply with no usable item, or a refusal, must not be asked again at the next run: each run is an
    /// hour or a call apart, and the same person would cost a request each time.
    func testASentenceReplyWithNothingOrARefusalWaitsLikeASentence() async throws {
        for kind in [CostModel.Sentences.empty, .refuse] {
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: paths.usage, withIntermediateDirectories: true)
            try PeopleStore(directory: paths.people).replaceAll([dana, sam])
            try calls(3)
            let m = CostModel(usage: UsageLog(directory: paths.usage), bad: [], sentences: kind)
            let runner = PersonaRunner(paths: paths, llm: m, owner: "Dana Lee")
            _ = await runner.run(since: nil, isLive: { false })
            _ = await runner.run(since: nil, isLive: { false })
            XCTAssertEqual(m.writes, 1, "\(kind): one request for the person in two runs, not one in each")
        }
    }

    // MARK: M9, M3

    func testSentencesThatAreDueAreWrittenInALaterRunAfterAStop() async throws {
        try PeopleStore(directory: paths.people).replaceAll([dana, sam])
        try calls(3)
        let m = model()
        let runner = PersonaRunner(paths: paths, llm: m, owner: "Dana Lee")
        _ = await runner.run(since: nil, writeLimit: 0, isLive: { false })
        let later = await runner.run(since: nil, isLive: { false })
        XCTAssertEqual(later.calls, 0)
        XCTAssertEqual(later.people, 1, "no list in memory: each person with a file is looked at")
    }

    @MainActor
    func testTheEvalsCapHoldsForAllRunsTogether() async throws {
        let out = root.appendingPathComponent("eval")
        let usage = UsageLog(directory: out.appendingPathComponent("usage"))
        try FileManager.default.createDirectory(at: out.appendingPathComponent("usage"), withIntermediateDirectories: true)
        usage.record(UsageEvent(date: Date(), callID: nil, service: .claude, purpose: .persona, model: "claude-sonnet-5-5", inputTokens: 7_200_000, outputTokens: 0))
        var said: [String] = []
        let status = await PersonaEval.command(["--gold", PersonaEvalTests.goldDir.path, "--out", out.path], key: { "k" }, say: { said.append($0) },
                                               makeModel: { _, _, _ in BrokenModel() })
        XCTAssertEqual(status, 1)
        XCTAssertTrue(said.contains { $0.contains("Spent so far in earlier runs: $14.40") })
        XCTAssertTrue(said.contains { $0.contains("pass the cap: nothing was sent") })
    }
}

/// Costs $0.05 for each request; a bad reply for the calls in `bad`.
final class CostModel: LanguageModel, @unchecked Sendable {
    let usage: UsageLog
    let bad: Set<String>
    /// How the sentence step answers: with sentences, with no usable item, or with a refusal.
    enum Sentences { case write, empty, refuse }
    let sentences: Sentences
    private(set) var requests = 0
    /// Requests that read a call.
    private(set) var reads = 0

    init(usage: UsageLog, bad: Set<String>, sentences: Sentences = .write) {
        self.usage = usage
        self.bad = bad
        self.sentences = sentences
    }

    /// Requests that asked for sentences.
    var writes: Int { requests - reads }

    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort, purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        requests += 1
        var e = UsageEvent(date: Date(), callID: UsageContext.callID, service: .claude, purpose: .persona, model: "claude-sonnet-5-5")
        e.costUSD = 0.05
        usage.record(e)
        if let id = UsageContext.callID, bad.contains(id) { throw SummaryError.malformed }
        let props = schema["properties"] as? [String: Any] ?? [:]
        if props["evidence"] != nil { reads += 1 }
        if props["evidence"] == nil, sentences == .refuse { throw SummaryError.refused }
        if props["evidence"] == nil, sentences == .empty {
            return try JSONDecoder().decode(Output.self, from: JSONSerialization.data(withJSONObject: ["traits": [[String: Any]]()]))
        }
        let out: [String: Any] = props["evidence"] != nil
            ? ["evidence": [["line": 1, "person": "P1", "quote": "Compared with what?", "dimension": "evidence", "value": "comparison", "label": "", "strength": "clear", "role": "decides"]]]
            : ["traits": [["id": "T1", "statement": "When a figure comes up, P1 asks what it compares with.", "so_do_this": "Bring a comparison.", "rating": "medium"]]]
        return try JSONDecoder().decode(Output.self, from: JSONSerialization.data(withJSONObject: out))
    }

    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String { "" }
}
