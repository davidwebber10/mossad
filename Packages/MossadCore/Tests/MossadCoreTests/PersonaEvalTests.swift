import XCTest
@testable import MossadCore

/// The eval harness and the first fill, with stub models only: no request goes to a provider here.
final class PersonaEvalTests: XCTestCase {
    static let goldDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("eval/persona/gold")

    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("persona-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: work) }

    func testTheGoldSetHasTwelvePeopleWithSixCallsEachAndItsTraps() throws {
        let gold = try PersonaGold.load(from: Self.goldDir)
        XCTAssertEqual(gold.people.count, 12)
        XCTAssertEqual(gold.calls.count, 72)
        XCTAssertEqual(gold.owner, "Dana Lee")
        XCTAssertTrue(gold.people.allSatisfy { $0.calls.count == 6 && $0.email.hasSuffix("@example.com") })
        let traps = gold.people.map(\.trap).joined(separator: " | ")
        for trap in ["budget", "1:1", "first 3 calls", "opposite in 1", "4 short lines", "no planted trait", "approver", "same first name", "health", "tells the model"] {
            XCTAssertTrue(traps.contains(trap), trap)
        }
        let words = gold.calls.map { $0.utterances.reduce(0) { $0 + $1.text.split(separator: " ").count } }
        XCTAssertGreaterThanOrEqual(words.min() ?? 0, 1_200)
        XCTAssertLessThanOrEqual(words.max() ?? 0, 2_200)
        XCTAssertEqual(gold.calls.filter { $0.noise == true }.count, 36, "half with speech-recognition errors")
        let records = gold.records()
        let saved = CoachPeople(people: gold.savedPeople(at: Date()))
        let quiet = try XCTUnwrap(gold.people.first { $0.maxShown == 0 })
        for id in quiet.calls {
            let r = try XCTUnwrap(records.first { $0.id == id })
            XCTAssertFalse(PersonaExtractor.speakers(in: r, saved: saved, owner: gold.owner, excluded: []).contains { $0.name == quiet.name }, "the quiet person gets none")
        }
    }

    @MainActor
    func testTheEstimateIsPrintedBeforeAnyRequestAndIsUnderTheCap() async throws {
        var said: [String] = []
        var asked = false
        let status = await PersonaEval.command(["--persona-eval", "--gold", Self.goldDir.path, "--estimate-only"], key: { asked = true; return "k" },
                                               say: { said.append($0) })
        XCTAssertEqual(status, 0)
        XCTAssertFalse(asked, "an estimate reads no key")
        let line = try XCTUnwrap(said.first { $0.hasPrefix("Estimate:") })
        let dollars = try XCTUnwrap(Double(line.split(separator: "$").last!.dropLast()))
        XCTAssertGreaterThan(dollars, 0.3)
        XCTAssertLessThan(dollars, 5, "one full run is a few dollars at most")
        XCTAssertTrue(said.contains { $0.contains("Cap $15.00") })
        let over = await PersonaEval.command(["--gold", Self.goldDir.path, "--cap", "40"], key: { nil }, say: { said.append($0) })
        XCTAssertEqual(over, 1, "no key: nothing sent")
        XCTAssertTrue(said.contains { $0.contains("Cap $15.00") }, "the cap is never above $15")
    }

    func testTheEvalMeasuresAndASecondRunUsesTheCacheAndTheCapStopsIt() async throws {
        let gold = try PersonaGold.load(from: Self.goldDir)
        // A stub that finds the planted beats by their words, and writes a plain sentence for each trait.
        let model = GoldStubModel(gold: gold)
        let usage = UsageLog(directory: work.appendingPathComponent("usage"))
        model.usage = usage
        let cache = work.appendingPathComponent("cache")
        let report = try await PersonaEval.run(gold, inner: model, usage: usage, model: "claude-sonnet-5-5", cap: 15, cache: cache, log: { _ in })
        XCTAssertFalse(report.stoppedAtCap)
        XCTAssertGreaterThan(report.requests, 72)
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("Precision of shown traits after 6 calls") })
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("Recall after 4 calls") })
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("Sentences that the word check refused") })
        XCTAssertTrue(report.lines[0].hasPrefix("Limits: the gold set is made from templates"), "the limits stand at the top")
        XCTAssertFalse(report.lines.contains { $0.contains("lower") && !$0.contains("never lowers") }, "the eval never lowers the threshold")
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("Calibration mean gap") })
        let shown = report.traits.filter { $0.checkpoint == 6 && $0.shown }
        XCTAssertFalse(shown.isEmpty)
        XCTAssertGreaterThanOrEqual(Double(shown.filter(\.correct).count) / Double(shown.count), 0.9, "a stub that finds only the planted beats is precise")
        XCTAssertFalse(shown.contains { $0.person == "Casey Moore" }, "the quiet person")
        XCTAssertFalse(shown.contains { $0.person == "Morgan Diaz" && $0.value == "asks_for_time" }, "the older habit")
        XCTAssertFalse(shown.contains { $0.person == "Jordan Blake" && $0.value == "numbers" }, "the budget call")

        let before = model.calls
        let again = try await PersonaEval.run(gold, inner: model, usage: usage, model: "claude-sonnet-5-5", cap: 15, cache: cache, log: { _ in })
        XCTAssertEqual(model.calls, before, "a second run with no change makes no request")
        XCTAssertEqual(again.requests, 0)

        let capped = try await PersonaEval.run(gold, inner: model, usage: usage, model: "claude-sonnet-5-5", cap: 0.01, cache: work.appendingPathComponent("other"),
                                               log: { _ in })
        XCTAssertTrue(capped.stoppedAtCap)
        XCTAssertLessThanOrEqual(usage.all().reduce(0) { $0 + Pricing.cost($1) }, 15)
    }

    func testThePersonaStepHasAModelOnEachProviderPathOrSkips() {
        XCTAssertEqual(PersonaExtractor.model(provider: .anthropic, chosen: "claude-opus-5-5", key: "k", usage: nil)?.name, "claude-sonnet-5-5")
        XCTAssertNil(PersonaExtractor.model(provider: .anthropic, chosen: "", key: nil, usage: nil), "no key: skip")
        XCTAssertEqual(PersonaExtractor.model(provider: .openai, chosen: "gpt-6.1-sol", key: "k", usage: nil)?.service, .openai)
        XCTAssertNil(PersonaExtractor.model(provider: .openrouter, chosen: "", key: "k", usage: nil), "no model chosen: skip")
        XCTAssertEqual(PersonaExtractor.model(provider: .localServer, chosen: "llama", key: nil, usage: nil)?.service, .local)
        XCTAssertNotNil(PersonaExtractor.model(provider: .apple, chosen: "", key: nil, usage: nil))
    }

    func testASmallOnDeviceModelSkipsTheStepCleanly() async throws {
        let paths = Paths(root: work)
        try paths.ensureDirectories()
        let gold = try PersonaGold.load(from: Self.goldDir)
        try PeopleStore(directory: paths.people).replaceAll(gold.savedPeople(at: Date()))
        let r = gold.records()[0]
        try FileManager.default.createDirectory(at: paths.callDirectory(r.id), withIntermediateDirectories: true)
        try r.save(to: paths.callDirectory(r.id))
        let small = SmallModel()
        let report = await PersonaRunner(paths: paths, llm: small, owner: "Dana Lee").run(since: nil, isLive: { false })
        XCTAssertEqual(report.stopped, "the model's context is too small")
        XCTAssertEqual(small.calls, 0)
        XCTAssertFalse(PersonaLedger.load(from: PersonaStore(paths: paths).directory).isRead(r), "the call waits for a model that can read it")
        let broken = await PersonaRunner(paths: paths, llm: BrokenModel(), owner: "Dana Lee").run(since: nil, isLive: { false })
        XCTAssertNil(broken.stopped)
        XCTAssertTrue(PersonaLedger.load(from: PersonaStore(paths: paths).directory).isRead(r), "a reply in another shape leaves the call out, so it blocks nothing")
    }

    @MainActor
    func testTheFirstFillPrintsItsCostAndSendsNothingWithoutGo() async throws {
        let paths = Paths(root: work)
        try paths.ensureDirectories()
        let gold = try PersonaGold.load(from: Self.goldDir)
        try PeopleStore(directory: paths.people).replaceAll(gold.savedPeople(at: Date()))
        for r in gold.records().prefix(6) {
            try FileManager.default.createDirectory(at: paths.callDirectory(r.id), withIntermediateDirectories: true)
            try r.save(to: paths.callDirectory(r.id))
        }
        let model = GoldStubModel(gold: gold)
        var said: [String] = []
        var keyRead = false
        let status = await PersonaFill.command(["--persona-fill"], paths: paths, owner: "Dana Lee", plan: ("claude-sonnet-5-5", .claude), makeModel: { _ in keyRead = true; return model },
                                               say: { said.append($0) })
        XCTAssertEqual(status, 0)
        XCTAssertEqual(model.calls, 0)
        XCTAssertFalse(keyRead, "the estimate makes no model and reads no key")
        XCTAssertTrue(said.contains { $0.hasPrefix("Estimated cost: $") })
        XCTAssertTrue(said.contains { $0.contains("Calls to read: 6") })
        let go = await PersonaFill.command(["--persona-fill", "--go"], paths: paths, owner: "Dana Lee", plan: ("claude-sonnet-5-5", .claude), makeModel: { usage in model.usage = usage; return model },
                                           say: { said.append($0) })
        XCTAssertEqual(go, 0)
        XCTAssertGreaterThan(model.calls, 0)
        XCTAssertTrue(PersonaLedger.load(from: PersonaStore(paths: paths).directory).isRead(gold.records()[0]))
        let none = await PersonaFill.command(["--persona-fill"], paths: paths, owner: "Dana Lee", plan: nil, makeModel: { _ in nil }, say: { said.append($0) })
        XCTAssertEqual(none, 1)
        for bad in ["inf", "0", "-1", "40"] {
            let s = await PersonaFill.command(["--persona-fill", "--cap", bad], paths: paths, owner: "Dana Lee", plan: ("claude-sonnet-5-5", .claude), makeModel: { _ in nil },
                                              say: { said.append($0) })
            XCTAssertEqual(s, 1, bad)
        }
        _ = await PersonaFill.command(["--persona-fill"], paths: paths, owner: "Dana Lee", plan: ("some-model", .openrouter), makeModel: { _ in model },
                                      say: { said.append($0) })
        XCTAssertTrue(said.contains { $0.contains("price of some-model is not known") })
        XCTAssertFalse(PersonaFill.price(service: .openrouter, model: "some-model").known)
        XCTAssertTrue(PersonaFill.price(service: .local, model: "llama").known)
    }
}

/// An on-device model with a context of 2,048 tokens.
final class SmallModel: ContextLimitedModel, @unchecked Sendable {
    private(set) var calls = 0
    func contextTokens() async -> Int { 2_048 }
    func tokenCount(_ text: String) async -> Int { text.count / 3 }
    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort, purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        calls += 1
        throw SummaryError.malformed
    }
    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String { "" }
}

/// A model whose reply never has the shape asked.
final class BrokenModel: LanguageModel, @unchecked Sendable {
    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort, purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        throw SummaryError.malformed
    }
    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String { "" }
}

/// Finds the planted beats in the moments by their words, as a perfect extractor would, and writes one plain
/// sentence for each trait. Writes each request's tokens to the usage log it is given.
final class GoldStubModel: LanguageModel, @unchecked Sendable {
    let beats: [(String, String, String)]
    var usage: UsageLog?
    private(set) var calls = 0

    init(gold: PersonaGold) {
        // The words of each beat variant, from the calls' own lines: the generator wrote them.
        let script = try? String(contentsOf: PersonaEvalTests.goldDir.deletingLastPathComponent().appendingPathComponent("make_gold.py"), encoding: .utf8)
        var out: [(String, String, String)] = []
        let pattern = try! NSRegularExpression(pattern: #"\("(\w+)", "(\w+)"\): \[([^\]]+)\]"#)
        let text = script ?? ""
        for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let d = String(text[Range(m.range(at: 1), in: text)!]), v = String(text[Range(m.range(at: 2), in: text)!])
            let list = String(text[Range(m.range(at: 3), in: text)!])
            for line in list.components(separatedBy: "\"").enumerated().filter({ $0.offset % 2 == 1 }).map(\.element) { out.append((d, v, line)) }
        }
        beats = out
    }

    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort, purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        calls += 1
        usage?.record(UsageEvent(date: Date(), callID: nil, service: .claude, purpose: .persona, model: "claude-sonnet-5-5", inputTokens: (system.count + user.count) / 4, outputTokens: 400))
        let props = schema["properties"] as? [String: Any] ?? [:]
        var out: [String: Any]
        if props["evidence"] != nil {
            var items: [[String: Any]] = []
            for line in user.split(separator: "\n") where line.hasPrefix("L") && !line.hasSuffix("(context)") {
                let parts = line.components(separatedBy: " | ")
                guard parts.count >= 3, parts[1].hasPrefix("P"), let n = Int(parts[0].dropFirst()) else { continue }
                let words = parts[2...].joined(separator: " | ")
                let plain = words.lowercased().filter { $0.isLetter || $0 == " " }
                guard let beat = beats.first(where: { b in
                    let first = b.2.lowercased().filter { $0.isLetter || $0 == " " }.split(separator: " ").prefix(5).joined(separator: " ")
                    return plain.contains(first)
                }) else { continue }
                let quote = words.split(separator: " ").prefix(6).joined(separator: " ")
                items.append(["line": n, "person": parts[1], "quote": quote, "dimension": beat.0 == "expects" ? "expects" : beat.0, "value": beat.1, "label": "",
                              "strength": "clear", "role": "decides"])
            }
            out = ["evidence": items]
        } else {
            let ids = user.split(separator: "\n").filter { $0.hasPrefix("T") }.compactMap { $0.split(separator: " ").first.map(String.init) }
            out = ["traits": ids.map { ["id": $0, "statement": "When asked for a decision, P1 asks one plain question first.", "so_do_this": "Answer the question before you go on.",
                                        "rating": "medium"] }]
        }
        return try JSONDecoder().decode(Output.self, from: JSONSerialization.data(withJSONObject: out))
    }

    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String { "" }
}
