import Foundation

/// Runs the persona step over the calls that are due: one small request for each call, oldest first, then the
/// sentences of the people whose evidence changed. A crash before a save loses nothing: the call is due again.
/// It never runs while a call is recorded: `isLive` is asked before each request.
public actor PersonaRunner {
    public struct Report: Sendable, Equatable {
        public var calls = 0
        public var requests = 0
        public var people = 0
        /// Why it stopped early, when it did.
        public var stopped: String?
    }

    /// Sentences for this many people in one run, and one person once in this many hours.
    public static let writesPerRun = 5
    static let writeGapHours = 20.0
    /// Tokens of one reply, for the estimate.
    static let extractOutputTokens = 450
    static let writeInputTokens = 1_800
    static let writeOutputTokens = 500

    private let paths: Paths
    private let extractor: PersonaExtractor
    private let writer: PersonaWriter
    private let owner: String
    private let now: @Sendable () -> Date

    public init(paths: Paths, llm: any LanguageModel, owner: String, now: @escaping @Sendable () -> Date = Date.init) {
        self.paths = paths
        extractor = PersonaExtractor(llm: llm)
        writer = PersonaWriter(llm: llm)
        self.owner = owner
        self.now = now
    }

    /// The written calls the step has not read with this prompt, oldest first. `since`: only calls from then on.
    public static func due(_ records: [CallRecord], ledger: PersonaLedger, since: Date?) -> [CallRecord] {
        records.filter { r in r.status == .written && !r.utterances.isEmpty && !ledger.isRead(r.id) && (since.map { r.start >= $0 } ?? true) }
            .sorted { $0.start < $1.start }
    }

    /// The records as the coach reads them: the owner's lines under the owner's name of now.
    static func records(paths: Paths, owner: String) -> [CallRecord] {
        let identity = OwnerIdentity.read(name: owner, paths: paths)
        return ProcessingQueue(paths: paths).allRecords().map(identity.withCurrentName)
    }

    /// What a run would send, with no request: the calls, the requests, and the tokens. `price` gives the dollars
    /// of a request's tokens.
    public static func estimate(paths: Paths, owner: String, since: Date?, price: (Int, Int) -> Double) -> (calls: Int, requests: Int, input: Int, output: Int, dollars: Double) {
        let records = records(paths: paths, owner: owner)
        let saved = CoachPeople.read(paths: paths)
        let ledger = PersonaLedger.load(from: PersonaStore(paths: paths).directory)
        let due = due(records, ledger: ledger, since: since)
        var requests = 0, input = 0, output = 0
        var people: [String: Int] = [:]
        for r in due {
            let speakers = PersonaExtractor.speakers(in: r, saved: saved, owner: owner, excluded: saved.notProfiled)
            for s in speakers { people[s.person, default: 0] += 1 }
            guard let req = PersonaExtractor.request(for: r, speakers: speakers, owner: owner) else { continue }
            requests += 1
            input += (req.system.count + req.user.count) / 4
            output += extractOutputTokens
        }
        // One request of sentences for each person who reaches 2 calls.
        let writes = people.values.filter { $0 >= 2 }.count
        requests += writes
        input += writes * writeInputTokens
        output += writes * writeOutputTokens
        return (due.count, requests, input, output, price(input, output))
    }

    /// `since`: the in-app step reads only calls from then on; the first fill passes nil. `callLimit` bounds one
    /// run. `canSpend` is asked before each request with that request's estimated dollars, for a hard cap.
    public func run(since: Date?, callLimit: Int? = nil, writeLimit: Int = PersonaRunner.writesPerRun, isLive: @Sendable () async -> Bool,
                    canSpend: @Sendable (Double) -> Bool = { _ in true }, price: @Sendable (Int, Int) -> Double = { _, _ in 0 }) async -> Report {
        var report = Report()
        let store = PersonaStore(paths: paths)
        let records = Self.records(paths: paths, owner: owner)
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ledger = PersonaLedger.load(from: store.directory)
        let profile = (try? CoachProfile.load(from: paths.coach)) ?? CoachProfile()
        var touched: [String] = []
        var due = Self.due(records, ledger: ledger, since: since)
        if let callLimit { due = Array(due.prefix(callLimit)) }
        for r in due {
            if await isLive() { report.stopped = "a call is being recorded"; break }
            // The people may change during a long run: read them for each call.
            let saved = CoachPeople.read(paths: paths)
            let speakers = PersonaExtractor.speakers(in: r, saved: saved, owner: owner, excluded: saved.notProfiled)
            let notTrue = Self.notTrue(speakers, profile: profile)
            if let req = PersonaExtractor.request(for: r, speakers: speakers, owner: owner, notTrue: notTrue),
               !canSpend(price((req.system.count + req.user.count) / 4, Self.extractOutputTokens)) {
                report.stopped = "the cap"
                break
            }
            do {
                let result = try await extractor.extract(r, speakers: speakers, owner: owner, notTrue: notTrue)
                if result.sent { report.requests += 1 }
                for id in Set(result.evidence.keys).union(store.people().filter { (try? store.load($0))?.calls.contains(r.id) == true }) {
                    var p = (try store.load(id)) ?? Persona(person: id, updated: now())
                    p.replace(callID: r.id, with: result.evidence[id] ?? [], at: now())
                    if p.evidence.isEmpty, p.texts.isEmpty { store.delete(id) } else { try store.save(p) }
                    if !touched.contains(saved.canonical(id)) { touched.append(saved.canonical(id)) }
                }
                ledger.calls[r.id] = PersonaExtractor.promptVersion
                ledger.save(to: store.directory)
                report.calls += 1
                // Counts and keys only, never words.
                Log.info("Persona step for \(r.id): \(result.kept) of \(result.proposed) pieces kept, \(speakers.count) people")
            } catch {
                Log.error("The persona step for \(r.id) waits: \(error)")
                report.stopped = "an error"
                break
            }
        }

        // The sentences of the people whose evidence changed, a few each run.
        let saved = CoachPeople.read(paths: paths)
        var writes = 0
        for person in touched where writes < writeLimit {
            if await isLive() { report.stopped = "a call is being recorded"; break }
            if let last = ledger.written[person], now().timeIntervalSince(last) < Self.writeGapHours * 3600, since != nil { continue }
            guard let name = saved.name(of: person), !saved.notProfiled.contains(person), let persona = store.persona(of: person, saved: saved) else { continue }
            let traits = PersonaTraits.build(persona, answers: profile.answers)
            guard traits.contains(where: PersonaWriter.needsText) else { continue }
            guard canSpend(price(Self.writeInputTokens, Self.writeOutputTokens)) else { report.stopped = "the cap"; break }
            let first = name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? name
            let calls = persona.calls.compactMap { byID[$0] }
            let names = Set(saved.others.map(\.name)).union(calls.flatMap { $0.speakerNames.values }).union([owner]).subtracting([name])
            do {
                let owner = owner
                let texts = try await writer.write(traits, first: first, line: { Self.line($0, records: byID, name: name, owner: owner) },
                                                   notTrue: Self.rejected(person, profile: profile, first: first), topicTerms: PersonaWords.topicTerms(calls),
                                                   names: names, now: now())
                report.requests += 1
                writes += 1
                guard !texts.isEmpty else { continue }
                var own = (try store.load(person)) ?? Persona(person: person, updated: now())
                for (id, text) in texts { own.texts[id] = text }
                own.updated = now()
                try store.save(own)
                ledger.written[person] = now()
                ledger.save(to: store.directory)
                report.people += 1
                Log.info("Persona sentences for one person: \(texts.count) traits, \(texts.values.filter { $0.statement.isEmpty }.count) failed the word check")
            } catch {
                Log.error("The persona sentences wait: \(error)")
                report.stopped = "an error"
                break
            }
        }
        return report
    }

    /// The words of a moment and the line before it, with the person as P1, the owner as Owner, and others' names
    /// as "another person".
    static func line(_ p: PersonaPointer, records: [String: CallRecord], name: String, owner: String) -> (text: String, before: String?)? {
        guard let r = records[p.callID], let u = p.utterance(in: r), let i = r.utterances.firstIndex(of: u) else { return nil }
        var names: [(String, String)] = [(name, "P1"), (owner, "Owner")]
        for other in Set(r.speakerNames.values).subtracting([name, owner]) where !other.hasPrefix("Speaker ") { names.append((other, "another person")) }
        if let first = name.split(whereSeparator: \.isWhitespace).first.map(String.init) { names.append((first, "P1")) }
        names.sort { $0.0.count > $1.0.count }
        let before = i > 0 ? PersonaExtractor.replaceNames(String(r.utterances[i - 1].text.prefix(PersonaExtractor.lineCharacters)), names) : nil
        return (PersonaExtractor.replaceNames(String(u.text.prefix(PersonaExtractor.lineCharacters)), names), before)
    }

    /// What the owner said is not true of these people, with their handles: the statements of blocked traits.
    static func notTrue(_ speakers: [PersonaExtractor.Speaker], profile: CoachProfile) -> [String] {
        speakers.flatMap { s -> [String] in
            let first = s.name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? s.name
            return rejected(s.person, profile: profile, first: first).map { $0.replacingOccurrences(of: "P1", with: s.handle) }
        }
    }

    /// The statements the owner answered "No, never again" for a person, with the person as P1, and the reasons the
    /// owner gave for a no about them.
    static func rejected(_ person: String, profile: CoachProfile, first: String) -> [String] {
        let blocked = profile.answers.filter { $0.trait != nil && $0.person == person && $0.verdict == .never }.map(\.text)
        let reasons = profile.guidance(about: person).map(\.text)
        return (blocked + reasons).map { $0.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: first))\\b", with: "P1", options: .regularExpression) }
    }
}
