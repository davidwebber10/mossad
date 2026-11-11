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
                       .read(dollars: 1, calls: nil), "the yes is for that model only; the first fill has started, so the usual budget is left")
        var u = PersonaBudget()
        u.approve(model: "m", estimate: 0, priceKnown: false, backlog: 30, now: t0)
        XCTAssertEqual(u.decide(backlog: 30, estimate: 0, priceKnown: false, free: false, model: "m", referencesReady: true, now: t0), .read(dollars: nil, calls: 30))
        u.record(dollars: 0, calls: 30, now: t0)
        XCTAssertEqual(u.decide(backlog: 5, estimate: 0, priceKnown: false, free: false, model: "m", referencesReady: true, now: t0),
                       .wait(.unknownPrice(calls: 5, model: "m")), "an unknown price: a number of calls, never unlimited")
    }

    func testTheCapHoldsAcrossLaunchesForThirtyDays() throws {
        var b = PersonaBudget()
        b.record(dollars: 0.7, calls: 60, now: t0)
        b.save(to: root)
        let again = PersonaBudget.load(from: root)
        XCTAssertEqual(again.decide(backlog: 40, estimate: 0.5, priceKnown: true, free: false, model: "m", referencesReady: true, now: t0.addingTimeInterval(3600)),
                       .read(dollars: 0.3, calls: nil))
        var spent = again
        spent.record(dollars: 0.3, calls: 20, now: t0.addingTimeInterval(7200))
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
    private static let filler = "We went through the lanes and the carriers and the schedule for the next quarter in some detail today."

    private func calls(_ n: Int, firstDay: Int = 0, voice: String = "Sam Carter") throws {
        for i in 0..<n {
            let start = t0.addingTimeInterval(Double(firstDay + i) * 86_400)
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
        let since = t0.addingTimeInterval(100 * 86_400)
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
        let since = t0.addingTimeInterval(100 * 86_400)
        _ = await run(model(), since: since)
        try calls(2, firstDay: 120)
        let m = model()
        let out = await run(m, since: since)
        XCTAssertEqual(out.newCalls.calls, 2, "the usual step for new calls, outside the budget")
        XCTAssertEqual(out.olderCalls.calls, 0)
        XCTAssertNotNil(out.note)
    }

    func testARenameMakesNoCallDueAndANamedVoiceIsAnOlderCall() async throws {
        try PeopleStore(directory: paths.people).replaceAll([dana, sam])
        try calls(3)
        let since = t0.addingTimeInterval(100 * 86_400)
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
                                         since: since, saved: CoachPeople.read(paths: paths), owner: "Dana Lee")
        XCTAssertTrue(owner.older.isEmpty && owner.new.isEmpty)
    }

    func testNothingRunsBeforeThePeopleHaveTheirIds() async throws {
        try PeopleStore(directory: paths.people).replaceAll([dana, sam])
        try calls(3)
        let m = model()
        let out = await run(m, since: t0, ready: false)
        XCTAssertEqual(m.requests, 0, "no request at all")
        XCTAssertEqual(out.decision, .wait(.people))
        XCTAssertNil(out.note)
    }

    func testTheFillIsDoneOnlyWhenNoOlderCallIsDue() async throws {
        try PeopleStore(directory: paths.people).replaceAll([dana, sam])
        try calls(4)
        let out = await run(model(bad: ["c1"]), since: t0.addingTimeInterval(100 * 86_400))
        XCTAssertEqual(out.olderCalls.handled, 4, "a call left out for good is taken up")
        XCTAssertEqual(out.decision, .done)
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
    private(set) var requests = 0
    /// Requests that read a call.
    private(set) var reads = 0

    init(usage: UsageLog, bad: Set<String>) {
        self.usage = usage
        self.bad = bad
    }

    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort, purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        requests += 1
        var e = UsageEvent(date: Date(), callID: UsageContext.callID, service: .claude, purpose: .persona, model: "claude-sonnet-5-5")
        e.costUSD = 0.05
        usage.record(e)
        if let id = UsageContext.callID, bad.contains(id) { throw SummaryError.malformed }
        let props = schema["properties"] as? [String: Any] ?? [:]
        if props["evidence"] != nil { reads += 1 }
        let out: [String: Any] = props["evidence"] != nil
            ? ["evidence": [["line": 1, "person": "P1", "quote": "Compared with what?", "dimension": "evidence", "value": "comparison", "label": "", "strength": "clear", "role": "decides"]]]
            : ["traits": [["id": "T1", "statement": "When a figure comes up, P1 asks what it compares with.", "so_do_this": "Bring a comparison.", "rating": "medium"]]]
        return try JSONDecoder().decode(Output.self, from: JSONSerialization.data(withJSONObject: out))
    }

    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String { "" }
}
