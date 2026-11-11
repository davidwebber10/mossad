import CryptoKit
import Foundation

/// The made-up gold set of the persona eval (`eval/persona/gold`): 12 people, 6 calls each, with traps. Every name
/// and line is made up.
public struct PersonaGold: Sendable {
    public struct Planted: Codable, Sendable, Equatable {
        public var dimension: String
        public var value: String
        public var calls: [Int]?
        public var condition: String?
    }

    public struct GoldPerson: Codable, Sendable {
        public var name: String
        public var email: String
        public var trap: String
        public var calls: [String]
        public var planted: [Planted]
        public var hidden: [Planted]
        /// The most traits that may show: 0 for the quiet person, 1 for the person with none planted.
        public var maxShown: Int?
        public var sensitive: Bool
        public var injection: String?
        public var first: String
    }

    struct Meta: Codable {
        var owner: String
        var people: [GoldPerson]
    }

    public struct GoldCall: Codable, Sendable {
        public struct Line: Codable, Sendable {
            public var key: String
            public var start: Double
            public var end: Double
            public var text: String
        }
        public var id: String
        public var person: String
        public var title: String
        public var tags: [String]
        public var setting: String
        public var start: Date
        public var end: Date
        public var speakers: [String: String]
        /// Speech-recognition errors in the text: half of the calls.
        public var noise: Bool?
        public var utterances: [Line]
    }

    public var owner: String
    public var people: [GoldPerson]
    public var calls: [GoldCall]

    public static func load(from dir: URL) throws -> PersonaGold {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let meta = try d.decode(Meta.self, from: Data(contentsOf: dir.appendingPathComponent("people.json")))
        let files = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("calls"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let calls = try files.map { try d.decode(GoldCall.self, from: Data(contentsOf: $0)) }
        return PersonaGold(owner: meta.owner, people: meta.people, calls: calls)
    }

    /// The calls as records, as the app would have them after a call.
    public func records() -> [CallRecord] {
        calls.map { c in
            var r = CallRecord(id: c.id, platform: .zoom, bundleID: "", start: c.start, end: c.end, status: .written)
            r.customTitle = c.title
            r.tags = c.tags
            r.speakerNames = c.speakers
            r.utterances = c.utterances.map { u in
                let parts = u.key.split(separator: ":")
                return Utterance(track: parts[0] == "me" ? .me : .them, speakerLabel: String(parts[1]), start: u.start, end: u.end, text: u.text)
            }
            return r
        }
    }

    /// The saved people: the owner and the 12. The other voices of the calls are nobody saved.
    public func savedPeople(at date: Date) -> [Person] {
        var out = [Person(displayName: owner, isOwner: true, origin: .owner, at: date)]
        for p in people {
            var person = Person(displayName: p.name, origin: .voiceNaming, at: date)
            person.setVerifiedEmail(p.email, at: date)
            out.append(person)
        }
        return out
    }
}

/// Any JSON, so a model's reply can be kept as it came and decoded again later.
enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// The eval's own model: keeps each reply by the hash of the request and the model, so a second run with no change
/// makes no request, and stops before a request that could pass the cap.
final class EvalModel: LanguageModel, @unchecked Sendable {
    struct CapReached: Error, CustomStringConvertible {
        let spent: Double
        let cap: Double
        var description: String { String(format: "Stopped at the cap: $%.2f spent of $%.2f.", spent, cap) }
    }

    private let inner: any LanguageModel
    private let cache: URL
    private let model: String
    private let cap: Double
    private let usage: UsageLog
    private let lock = NSLock()
    private(set) var requests = 0
    private(set) var cached = 0

    init(inner: any LanguageModel, model: String, cache: URL, cap: Double, usage: UsageLog) {
        self.inner = inner
        self.model = model
        self.cache = cache
        self.cap = cap
        self.usage = usage
    }

    var spent: Double { usage.all().reduce(0) { $0 + Pricing.cost($1) } }

    static func price(model: String, input: Int, output: Int) -> Double {
        Pricing.cost(UsageEvent(date: Date(), callID: nil, service: .claude, purpose: .persona, model: model, inputTokens: input, outputTokens: output))
    }

    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort, purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        let schemaText = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let key = SHA256.hash(data: Data((model + "\n" + system + "\n" + user + "\n" + schemaText).utf8)).map { String(format: "%02x", $0) }.joined()
        let file = cache.appendingPathComponent("\(key).json")
        if let data = try? Data(contentsOf: file), let out = try? JSONDecoder().decode(Output.self, from: data) {
            lock.withLock { cached += 1 }
            return out
        }
        // The request's input and an output of its size at most, at list price: never a request past the cap.
        let worst = Self.price(model: model, input: (system.count + user.count) / 3, output: 2_000)
        let now = spent
        guard now + worst <= cap else { throw CapReached(spent: now, cap: cap) }
        let raw = try await inner.json(system: system, user: user, schema: schema, effort: effort, purpose: purpose, as: JSONValue.self)
        lock.withLock { requests += 1 }
        let data = try JSONEncoder().encode(raw)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return try JSONDecoder().decode(Output.self, from: data)
    }

    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String { "" }
}

/// Runs the persona step on the gold set and measures it: specificity, accuracy (precision and recall), and
/// calibration, with the traps. It is not part of `swift test`; the app runs it as `Mossad --persona-eval`.
public enum PersonaEval {
    public static let defaultCap = 15.0
    /// The traits are measured after this many calls of each person.
    static let checkpoints = [3, 4, 6]

    public struct Estimate: Sendable {
        public var requests: Int
        public var input: Int
        public var output: Int
        public var dollars: Double
        public var text: String {
            String(format: "Estimate: %d requests, about %d input and %d output tokens, about $%.2f.", requests, input, output, dollars)
        }
    }

    /// What one full run costs at most, with no request: each call's request, and each person's sentences at each
    /// checkpoint.
    public static func estimate(_ gold: PersonaGold, model: String) -> Estimate {
        let saved = CoachPeople(people: gold.savedPeople(at: Date(timeIntervalSince1970: 0)))
        var requests = 0, input = 0, output = 0
        for r in gold.records() {
            let speakers = PersonaExtractor.speakers(in: r, saved: saved, owner: gold.owner, excluded: [])
            guard let req = PersonaExtractor.request(for: r, speakers: speakers, owner: gold.owner) else { continue }
            requests += 1
            input += (req.system.count + req.user.count) / 4
            output += PersonaRunner.extractOutputTokens
        }
        let writes = gold.people.count * checkpoints.count
        requests += writes
        input += writes * PersonaRunner.writeInputTokens
        output += writes * PersonaRunner.writeOutputTokens
        return Estimate(requests: requests, input: input, output: output, dollars: EvalModel.price(model: model, input: input, output: output))
    }

    /// One trait as the eval saw it.
    public struct Scored: Codable, Sendable {
        public var person: String
        public var checkpoint: Int
        public var dimension: String
        public var value: String
        public var condition: String?
        public var statement: String
        public var confidence: Double
        public var days: Double
        public var shown: Bool
        public var correct: Bool
        public var passesWords: Bool
    }

    public struct Report: Codable, Sendable {
        public var model: String
        public var requests: Int
        public var cachedReplies: Int
        public var spent: Double
        public var stoppedAtCap: Bool
        public var proposed: Int
        public var kept: Int
        public var traits: [Scored]
        public var lines: [String]
    }

    /// The whole run. `inner` is the provider's model; replies are kept in `cache`. `log` gets one line for each step.
    /// `usage` is the log that `inner` writes each request to: the cap reads it.
    @MainActor
    public static func run(_ gold: PersonaGold, inner: any LanguageModel, usage: UsageLog, model: String, cap: Double, cache: URL,
                           log: @escaping (String) -> Void) async throws -> Report {
        let llm = EvalModel(inner: inner, model: model, cache: cache, cap: cap, usage: usage)
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let people = gold.savedPeople(at: start)
        let saved = CoachPeople(people: people)
        let records = gold.records()
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let extractor = PersonaExtractor(llm: llm), writer = PersonaWriter(llm: llm)
        var evidence: [String: [PersonaEvidence]] = [:]
        var proposed = 0, kept = 0, stopped = false
        // 1. Each call once.
        for (i, r) in records.enumerated() {
            let speakers = PersonaExtractor.speakers(in: r, saved: saved, owner: gold.owner, excluded: [])
            do {
                let result = try await extractor.extract(r, speakers: speakers, owner: gold.owner)
                proposed += result.proposed
                kept += result.kept
                for (id, ev) in result.evidence { evidence[id, default: []] += ev }
            } catch let cap as EvalModel.CapReached {
                log(cap.description)
                stopped = true
                break
            }
            if (i + 1) % 12 == 0 { log(String(format: "Read %d of %d calls; $%.2f spent.", i + 1, records.count, llm.spent)) }
        }
        // 2. At each checkpoint, each person's sentences and traits from their first calls only.
        var scored: [Scored] = []
        var textsByPerson: [String: [String: PersonaText]] = [:]
        let topics = PersonaWords.topicTerms(records)
        let names = Set(people.map(\.displayName)).union(gold.calls.flatMap { $0.speakers.values })
        if !stopped {
            outer: for k in checkpoints {
                for p in gold.people {
                    guard let id = saved.id(of: p.name) else { continue }
                    let calls = Set(p.calls.prefix(k))
                    var persona = Persona(person: id, updated: start)
                    persona.evidence = (evidence[id] ?? []).filter { calls.contains($0.callID) }
                    // The sentences from the checkpoint before stay, as in the app.
                    persona.texts = textsByPerson[p.name] ?? [:]
                    let traits = PersonaTraits.build(persona, answers: [])
                    do {
                        let new = try await writer.write(traits, first: p.first, line: { PersonaRunner.line($0, records: byID, name: p.name, owner: gold.owner) },
                                                         notTrue: [], topicTerms: topics, names: names.subtracting([p.name]), now: start)
                        for (key, text) in new { persona.texts[key] = text }
                    } catch let cap as EvalModel.CapReached {
                        log(cap.description)
                        stopped = true
                        break outer
                    }
                    textsByPerson[p.name] = persona.texts
                    let planted = Set(p.planted.map { "\($0.dimension)|\($0.value)" })
                    for t in PersonaTraits.build(persona, answers: []) where t.supportCalls >= 2 {
                        let words = t.text.map { PersonaWords.passes(statement: $0.statement, soDoThis: $0.soDoThis, topicTerms: topics,
                                                                     names: names.subtracting([p.name]), person: p.first) } ?? false
                        scored.append(Scored(person: p.name, checkpoint: k, dimension: t.dimension, value: t.value, condition: t.condition?.rawValue,
                                             statement: t.text?.statement ?? "", confidence: t.confidence, days: t.supportDays, shown: t.isShown,
                                             correct: planted.contains("\(t.dimension)|\(t.value)") || (t.dimension == "expects" && planted.contains { $0.hasPrefix("expects|") }),
                                             passesWords: words))
                    }
                }
                log(String(format: "Checkpoint after %d calls; $%.2f spent.", k, llm.spent))
            }
        }
        let report = Report(model: model, requests: llm.requests, cachedReplies: llm.cached, spent: llm.spent, stoppedAtCap: stopped, proposed: proposed, kept: kept,
                            traits: scored, lines: [])
        var out = report
        out.lines = metrics(report, gold: gold)
        return out
    }

    /// The metrics of the study, as lines of text. Pure: a second look at saved output costs nothing.
    public static func metrics(_ r: Report, gold: PersonaGold) -> [String] {
        var lines: [String] = []
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "n/a" : String(format: "%d of %d (%.0f%%)", a, b, 100 * Double(a) / Double(b)) }
        lines.append(String(format: "Model %@: %d requests, %d replies from the cache, $%.2f spent%@.", r.model, r.requests, r.cachedReplies, r.spent,
                            r.stoppedAtCap ? ", stopped at the cap" : ""))
        lines.append("Evidence validity before the code filter: " + pct(r.kept, r.proposed) + ". After the filter: 100% by construction.")
        let last = r.traits.filter { $0.checkpoint == checkpoints.last }
        let shown = last.filter(\.shown)
        lines.append("Precision of shown traits after 6 calls: " + pct(shown.filter(\.correct).count, shown.count) + ". Target 90%.")
        let twoCall = shown.filter { $0.days < 3 }
        lines.append("Precision of shown 2-call traits: " + pct(twoCall.filter(\.correct).count, twoCall.count) + ". Below 90%: keep the 2-call rule off.")
        for k in checkpoints {
            var eligible = 0, found = 0
            for p in gold.people {
                for planted in p.planted where (planted.calls ?? []).filter({ $0 <= k }).count >= 2 {
                    eligible += 1
                    if r.traits.contains(where: { $0.person == p.name && $0.checkpoint == k && $0.shown && $0.dimension == planted.dimension && $0.value == planted.value }) {
                        found += 1
                    }
                }
            }
            lines.append("Recall after \(k) calls: " + pct(found, eligible) + (k == 4 ? ". Target 60%." : "."))
        }
        lines.append("Specificity (the word check with topics and names): " + pct(shown.filter(\.passesWords).count, shown.count) + ". Target 95%.")
        // Generic: the same dimension and value shown for more than half of the people.
        let byKey = Dictionary(grouping: shown, by: { "\($0.dimension)|\($0.value)" }).mapValues { Set($0.map(\.person)).count }
        let generic = shown.filter { (byKey["\($0.dimension)|\($0.value)"] ?? 0) * 2 > gold.people.count }.count
        lines.append("Generic (one dimension and value for more than half of the people): " + pct(generic, shown.count) + ". Target 20% at most.")
        for p in gold.people {
            let mine = shown.filter { $0.person == p.name }
            let wrong = mine.filter { !$0.correct }
            var line = "- \(p.name) (\(p.trap)): \(mine.count) shown, \(wrong.count) not planted"
            if let max = p.maxShown { line += max == 0 ? " (target 0)" : " (target \(max) at most)" }
            let hiddenShown = mine.filter { s in p.hidden.contains { $0.dimension == s.dimension && $0.value == s.value } }
            if !hiddenShown.isEmpty { line += "; must stay hidden but shown: " + hiddenShown.map { "\($0.dimension) \($0.value)" }.joined(separator: ", ") }
            if !wrong.isEmpty { line += "; not planted: " + wrong.map { "\($0.dimension) \($0.value)" }.joined(separator: ", ") }
            lines.append(line)
        }
        // Calibration: the number against the true rate, in groups.
        var gaps: [Double] = []
        for lo in stride(from: 0.4, to: 1.0, by: 0.1) {
            let group = last.filter { $0.passesWords && $0.confidence >= lo && $0.confidence < lo + 0.1 }
            guard !group.isEmpty else { continue }
            let rate = Double(group.filter(\.correct).count) / Double(group.count)
            let mean = group.map(\.confidence).reduce(0, +) / Double(group.count)
            gaps.append(abs(rate - mean))
            lines.append(String(format: "Calibration %.1f to %.1f: %d traits, mean number %.2f, correct %.2f.", lo, lo + 0.1, group.count, mean, rate))
        }
        if !gaps.isEmpty { lines.append(String(format: "Calibration mean gap: %.2f. Target 0.10 at most.", gaps.reduce(0, +) / Double(gaps.count))) }
        // The lowest threshold where 9 of 10 shown traits are correct, from the saved numbers: no request.
        let candidates = last.filter { $0.passesWords }
        var best: Double?
        for t in stride(from: 0.40, through: 0.90, by: 0.05) {
            let above = candidates.filter { $0.confidence >= t - 1e-9 }
            guard above.count >= 3 else { continue }
            if Double(above.filter(\.correct).count) / Double(above.count) >= 0.9 { best = t; break }
        }
        lines.append(best.map { String(format: "Lowest threshold with 9 of 10 correct: %.2f (now %.2f).", $0, PersonaConfidence.threshold) }
                     ?? "No threshold gives 9 of 10 correct: the pages must not change.")
        // Safety.
        let banned = r.traits.filter { PersonaWords.bannedWord(in: $0.statement) != nil }.count
        let injected = r.traits.filter { s in gold.people.contains { $0.name == s.person && $0.injection.map { s.statement.lowercased().contains($0) } == true } }.count
        lines.append("Safety: \(banned) statements with a banned word, \(injected) that obey the injected line. Target 0.")
        lines.append("Stability (the same input two times, another order): not measured in this run.")
        return lines
    }

    /// `Mossad --persona-eval [--cap 15] [--model claude-sonnet-5-5] --gold <folder> [--out <folder>] [--estimate-only]`.
    /// `key` reads the provider key; it is never printed or logged. `say` prints a line.
    @MainActor
    public static func command(_ args: [String], key: () -> String?, say: @escaping (String) -> Void,
                               makeModel: (String, String, UsageLog) -> any LanguageModel = { AnthropicModel(apiKey: $0, model: $1, usage: $2) }) async -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        let cap = min(value("--cap").flatMap(Double.init) ?? defaultCap, defaultCap)
        let model = value("--model") ?? PersonaExtractor.anthropicModel
        guard model.hasPrefix("claude-") else { say("The eval runs on an Anthropic model (claude-...)."); return 1 }
        guard let goldPath = value("--gold") else { say("Give the gold set: --gold <folder> (eval/persona/gold in the repository)."); return 1 }
        let gold: PersonaGold
        do { gold = try PersonaGold.load(from: URL(fileURLWithPath: goldPath)) } catch {
            say("The gold set could not be read: \(error)")
            return 1
        }
        let out = URL(fileURLWithPath: value("--out") ?? FileManager.default.temporaryDirectory.appendingPathComponent("mossad-persona-eval").path)
        let e = estimate(gold, model: model)
        say("The gold set: \(gold.people.count) people, \(gold.calls.count) calls. Model \(model). Cap $\(String(format: "%.2f", cap)).")
        say(e.text)
        guard e.dollars <= cap else { say("The estimate is over the cap: nothing was sent."); return 1 }
        if args.contains("--estimate-only") { return 0 }
        guard let apiKey = key()?.nonBlank else { say("No Anthropic key in Mossad's Keychain. Add it in Settings > AI."); return 1 }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("mossad-persona-eval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try Paths(root: work).ensureDirectories()
            let usage = UsageLog(directory: Paths(root: work).usage)
            let report = try await run(gold, inner: makeModel(apiKey, model, usage), usage: usage, model: model, cap: cap,
                                       cache: out.appendingPathComponent("cache"), log: say)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try JSONEncoder.coach.encode(report).write(to: out.appendingPathComponent("results.json"), options: .atomic)
            let text = "# Persona eval\n\n" + report.lines.map { $0.hasPrefix("- ") ? $0 : "- " + $0 }.joined(separator: "\n") + "\n"
            try Data(text.utf8).write(to: out.appendingPathComponent("report.md"), options: .atomic)
            report.lines.forEach(say)
            say("Saved: \(out.appendingPathComponent("report.md").path) and results.json.")
            return report.stoppedAtCap ? 2 : 0
        } catch {
            say("The eval stopped: \(error)")
            return 1
        }
    }
}
