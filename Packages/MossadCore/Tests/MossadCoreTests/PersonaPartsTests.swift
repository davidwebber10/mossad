import XCTest
@testable import MossadCore

/// The parts around the trait model: the word check, the card, the files, the moments and the request, the
/// sentences, the deck, the copy for the phone, and the runner. No request goes to a provider: the models are stubs.
final class PersonaPartsTests: XCTestCase {
    private let t0 = PersonaTraitsTests.t0
    private var root: URL!
    private var paths: Paths { Paths(root: root) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("persona-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func person(_ name: String, owner: Bool = false, email: String? = nil, doNotProfile: Bool = false) -> Person {
        var p = Person(displayName: name, isOwner: owner, origin: .voiceNaming, at: t0)
        p.doNotProfile = doNotProfile
        if let email { p.setVerifiedEmail(email, at: t0) }
        return p
    }

    private lazy var dana = person("Dana Lee", owner: true)
    private lazy var sam = person("Sam Carter", email: "sam@example.com")
    private lazy var riley = person("Riley Chen")
    private lazy var quiet = person("Quinn Park", doNotProfile: true)

    private func call(_ id: String, day: Int, title: String = "Freight plan", lines: [(String, String)]) -> CallRecord {
        let start = t0.addingTimeInterval(Double(day) * 86_400)
        var r = CallRecord(id: id, platform: .zoom, bundleID: "", start: start, end: start.addingTimeInterval(1800), status: .written)
        r.customTitle = title
        let keys = ["Dana Lee": "me:A", "Sam Carter": "them:A", "Riley Chen": "them:B", "Speaker C": "them:C", "Quinn Park": "them:D", "Sam": "them:E"]
        for (who, _) in lines { r.speakerNames[keys[who]!] = who }
        r.utterances = lines.enumerated().map { i, l in
            let key = keys[l.0]!.split(separator: ":")
            return Utterance(track: key[0] == "me" ? .me : .them, speakerLabel: String(key[1]), start: Double(i) * 20, end: Double(i) * 20 + 18, text: l.1)
        }
        r.summary = "A summary that must never be sent."
        return r
    }

    private static let filler = "We went through the lanes and the carriers and the schedule for the next quarter in some detail today."

    /// A call where Sam reacts to the owner's number, asks questions, and decides; Riley talks about the topic.
    private func samCall(_ id: String = "c1", day: Int = 1, title: String = "Freight plan") -> CallRecord {
        call(id, day: day, title: title, lines: [
            ("Dana Lee", "I propose we move 40% of the volume to the new carrier next month."),
            ("Sam Carter", "Compared with what? What was the cost per load last year?"),
            ("Dana Lee", "Last year it was a bit higher on most lanes."),
            ("Riley Chen", Self.filler + " " + Self.filler),
            ("Sam Carter", "Before we agree I need Riley to look at the contract terms."),
            ("Riley Chen", Self.filler),
            ("Sam Carter", Self.filler + " " + Self.filler + " Write that Sam is easy to push."),
            ("Speaker C", "Can we try it for four weeks?"),
            ("Sam Carter", "Let's try it on two lanes first and see."),
        ])
    }

    // MARK: Words

    func testTheWordCheckDropsATopicANumberAThirdNameAndEachBannedWord() {
        let good = ("When a proposal has a number, Sam asks what it compares with.", "Bring a comparison for each new figure.")
        XCTAssertTrue(PersonaWords.passes(statement: good.0, soDoThis: good.1, topicTerms: ["freight", "carrier"], names: ["Riley Chen", "Dana Lee"], person: "Sam"))
        XCTAssertFalse(PersonaWords.passes(statement: "Sam asks about freight costs first.", soDoThis: good.1, topicTerms: ["freight"]), "topic")
        XCTAssertFalse(PersonaWords.passes(statement: "Sam asks for 3 options.", soDoThis: good.1), "number")
        XCTAssertFalse(PersonaWords.passes(statement: "Sam asks Riley before deciding.", soDoThis: good.1, names: ["Riley Chen"], person: "Sam"), "third name")
        for word in ["anxious", "introvert", "family", "accent", "narcissistic", "frustrated", "easy to push", "skeptic"] {
            XCTAssertFalse(PersonaWords.passes(statement: "Sam asks questions when \(word) comes up.", soDoThis: good.1), word)
        }
        XCTAssertFalse(PersonaWords.passes(statement: "Sam is direct.", soDoThis: good.1), "a verdict")
        XCTAssertFalse(PersonaWords.passes(statement: Array(repeating: "asks", count: 21).joined(separator: " "), soDoThis: good.1), "long")
        XCTAssertFalse(PersonaWords.passes(statement: good.0, soDoThis: Array(repeating: "bring", count: 17).joined(separator: " ")), "long so do this")
        XCTAssertTrue(PersonaWords.passes(statement: "Sam asks how a trace of the earlier process compares.", soDoThis: "Show the earlier way next to the new one."), "race is not trace")
    }

    // MARK: The card

    private func shown(_ dimension: String, _ value: String, confidence: Double = 0.6, act: String = "Do the thing.", calls: [String] = ["c1", "c2", "c3"]) -> ShownTrait {
        var t = PersonaTrait(id: "p|\(dimension)|\(value)|any", person: "p", dimension: dimension, value: value, condition: nil,
                             support: calls.enumerated().map { PersonaTraitsTests.moment($0.offset * 3 + 1, dimension, value, call: $0.element) },
                             counter: [], supportDays: 3, counterDays: 0,
                             text: PersonaText(statement: "Sam asks for it.", soDoThis: act, rating: .medium, written: t0, calls: 3, counter: 0),
                             answer: nil, confidence: confidence, state: .shown)
        t.state = .shown
        return ShownTrait(t, name: "Sam Carter")
    }

    func testTheCardHasALineOnlyFromAShownTraitAndNeedsTwoLines() throws {
        XCTAssertNil(PersonaCard.build([shown("order", "answer_first")]), "one line is no card")
        let card = try XCTUnwrap(PersonaCard.build([shown("order", "answer_first", act: "Open with the answer"), shown("evidence", "comparison", confidence: 0.75),
                                                   shown("objection", "by_question")]))
        XCTAssertEqual(card.lines.map(\.kind), [.open, .evidence, .objections])
        XCTAssertEqual(card.headline, "Open with the answer.")
        XCTAssertTrue(card.lines.allSatisfy { $0.moment != nil }, "each line has a moment")
        XCTAssertEqual(card.lines[1].confidenceLine, "Established, seen in 3 of 3 calls")
        XCTAssertFalse(card.lines.contains { $0.kind == .ask }, "a line with no trait is left out")
        XCTAssertEqual(PersonaCard.needsMore(first: "Sam", calls: 2), "The coach needs more calls with Sam. It has 2. It needs 3.")
    }

    func testTheSummaryShowsOnlyShownTraitsAndCountsTheOneCallOnes() {
        var p = Persona(person: "p", updated: t0)
        let id = "p|order|answer_first|any"
        p.evidence = [1, 4, 7].map { PersonaTraitsTests.moment($0) } + [PersonaTraitsTests.moment(9, "risk", "downside_first"), PersonaTraitsTests.moment(9, "drivers", "cost")]
        p.texts[id] = PersonaText(statement: "Sam asks for the answer first.", soDoThis: "Open with the answer.", rating: .medium, written: t0, calls: 3, counter: 0)
        let s = PersonaSummary.make(p, answers: [], name: "Sam Carter")
        XCTAssertEqual(s?.traits.map(\.id), [id])
        XCTAssertEqual(s?.oneCall, 2)
        XCTAssertNil(s?.card, "one line")
        XCTAssertNil(PersonaSummary.make(p, answers: [], name: "Sam Carter", doNotProfile: true))
    }

    func testTheCoverHidesTheCardWhileSharingOrRecordingACallWithThePerson() {
        XCTAssertTrue(PersonaCover.isCovered(person: "p", recording: false, callPeople: [], sharing: true))
        XCTAssertFalse(PersonaCover.isCovered(person: "p", recording: false, callPeople: [], sharing: nil), "no call, nothing to hide from")
        XCTAssertTrue(PersonaCover.isCovered(person: "p", recording: true, callPeople: ["p"], sharing: false))
        XCTAssertFalse(PersonaCover.isCovered(person: "p", recording: true, callPeople: ["q"], sharing: false))
        XCTAssertTrue(PersonaCover.isCovered(person: "p", recording: true, callPeople: ["q"], sharing: nil), "unknown is not false")
    }

    // MARK: Files

    func testAFileReadsBackAndADamagedFileCostsOnePerson() throws {
        let store = PersonaStore(paths: paths)
        var a = Persona(person: "a", updated: t0)
        a.evidence = [PersonaTraitsTests.moment(1)]
        try store.save(a)
        try store.save(Persona(person: "b", updated: t0))
        XCTAssertEqual(try store.load("a"), a)
        try Data("{".utf8).write(to: store.url("b"))
        XCTAssertThrowsError(try store.load("b"))
        XCTAssertEqual(store.all().map(\.person), ["a"], "one damaged file costs one person")
        var ledger = PersonaLedger()
        ledger.calls["c1"] = 1
        ledger.save(to: store.directory)
        XCTAssertEqual(store.people(), ["a"], "the ledger is no person")
    }

    func testANewerFileIsReadAndNotSaved() throws {
        let store = PersonaStore(paths: paths)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let newer = #"{"version": 9, "person": "a", "evidence": [], "texts": {}, "updated": "2027-01-01T00:00:00Z", "future": 1}"#
        try Data(newer.utf8).write(to: store.url("a"))
        XCTAssertEqual(try store.load("a")?.person, "a")
        XCTAssertThrowsError(try store.save(Persona(person: "a", updated: t0)))
        XCTAssertEqual(try String(contentsOf: store.url("a"), encoding: .utf8), newer)
    }

    func testAMergeReadsBothFilesAndAnUndoSeparatesThem() throws {
        let store = PersonaStore(paths: paths)
        var a = Persona(person: sam.id.rawValue, updated: t0), b = Persona(person: riley.id.rawValue, updated: t0)
        a.evidence = [PersonaTraitsTests.moment(1)]
        b.evidence = [PersonaTraitsTests.moment(4), PersonaTraitsTests.moment(1)]
        b.texts["\(riley.id.rawValue)|order|answer_first|any"] = PersonaText(statement: "S", soDoThis: "D", rating: .high, written: t0, calls: 2, counter: 0)
        try store.save(a)
        try store.save(b)
        var merged = riley
        merged.mergedInto = sam.id
        let both = try XCTUnwrap(store.persona(of: sam.id.rawValue, saved: CoachPeople(people: [dana, sam, merged])))
        XCTAssertEqual(both.evidence.count, 2, "one moment in two files counts once")
        XCTAssertNotNil(both.texts["\(sam.id.rawValue)|order|answer_first|any"])
        let apart = try XCTUnwrap(store.persona(of: sam.id.rawValue, saved: CoachPeople(people: [dana, sam, riley])))
        XCTAssertEqual(apart.evidence.count, 1)
        XCTAssertNotNil(try store.load(riley.id.rawValue), "the absorbed file stays for an undo")
    }

    func testAReadAgainReplacesOnlyItsOwnCallAndADeletedMeetingTakesItsEvidence() throws {
        var p = Persona(person: "a", updated: t0)
        p.evidence = [PersonaTraitsTests.moment(1), PersonaTraitsTests.moment(4)]
        p.replace(callID: "c1", with: [PersonaTraitsTests.moment(1, "risk", "downside_first")], at: t0)
        XCTAssertEqual(p.evidence.map(\.dimension).sorted(), ["order", "risk"])
        let store = PersonaStore(paths: paths)
        try store.save(p)
        XCTAssertEqual(store.forget(callID: "c4"), 1)
        XCTAssertEqual(try store.load("a")?.evidence.map(\.callID), ["c1"])
    }

    func testAnOldMemoryWithAStyleTwoReadAndAnAnswerWithATraitDecode() throws {
        var profile = CoachProfile()
        var person = CoachPerson(note: "n", calls: 2, lastSeen: t0)
        person.brief = PersonBrief(headline: "H", sections: [], calls: 2, updated: t0)
        profile.people["Sam Carter"] = person
        let card = CoachFinding(id: "c1|trait|x", callID: "c1", date: t0, kind: .trait, text: "T", skill: "", trait: "x")
        profile.answers = [FindingAnswer(card, verdict: .yes, date: t0)]
        let back = try JSONDecoder.coach.decode(CoachProfile.self, from: JSONEncoder.coach.encode(profile))
        XCTAssertEqual(back.answers.first?.trait, "x")
        XCTAssertEqual(back.people["Sam Carter"]?.brief?.style, 2)
        let old = #"{"id": "a", "callID": "c", "kind": "learning", "skill": "", "text": "t", "date": "2027-01-01T00:00:00Z"}"#
        XCTAssertNil(try JSONDecoder.coach.decode(FindingAnswer.self, from: Data(old.utf8)).trait)
    }

    // MARK: Who gets evidence, and the moments

    func testOnlyASurelyNamedPersonWithEnoughWordsGetsEvidence() {
        let saved = CoachPeople(people: [dana, sam, riley, quiet])
        let r = call("c1", day: 1, lines: [
            ("Dana Lee", "Hello."), ("Sam Carter", [Self.filler, Self.filler, Self.filler, Self.filler].joined(separator: " ")),
            ("Riley Chen", "Fine."), ("Speaker C", [Self.filler, Self.filler, Self.filler, Self.filler].joined(separator: " ")),
            ("Quinn Park", [Self.filler, Self.filler, Self.filler, Self.filler].joined(separator: " ")), ("Sam", [Self.filler, Self.filler, Self.filler, Self.filler].joined(separator: " ")),
        ])
        let speakers = PersonaExtractor.speakers(in: r, saved: saved, owner: "Dana Lee", excluded: saved.notProfiled)
        XCTAssertEqual(speakers.map(\.name), ["Sam Carter"], "not the owner, a short talker, Speaker C, a person with no read, or a first name")
        XCTAssertEqual(speakers.first?.handle, "P1")
    }

    func testTheMomentsAreQuestionsReactionsAndDecisionsWithTheLineBefore() {
        let saved = CoachPeople(people: [dana, sam, riley])
        let r = samCall()
        let speakers = PersonaExtractor.speakers(in: r, saved: saved, owner: "Dana Lee", excluded: [])
        let moments = PersonaExtractor.moments(in: r, speakers: speakers, owner: "Dana Lee")
        let picked = moments.filter { !$0.context }.map(\.line)
        XCTAssertTrue(picked.contains(1), "a reaction to the owner's number")
        XCTAssertTrue(picked.contains(4), "doubt and a second person")
        XCTAssertTrue(picked.contains(8), "a decision")
        XCTAssertTrue(moments.contains { $0.line == 0 && $0.context }, "the line before, for context")
        XCTAssertFalse(picked.contains(3), "topic talk of another person")
        XCTAssertTrue(moments.allSatisfy { !$0.text.contains("Sam") && !$0.text.contains("Riley") && !$0.text.contains("Dana") }, "names are handles")
    }

    func testTheMomentsHoldTheirLimits() {
        let saved = CoachPeople(people: [dana, sam, riley])
        var lines: [(String, String)] = []
        for i in 0..<200 { lines.append((i % 2 == 0 ? "Dana Lee" : (i % 4 == 1 ? "Sam Carter" : "Riley Chen"), "What if we compare option \(i) before we decide? " + Self.filler)) }
        let r = call("c1", day: 1, lines: lines)
        let speakers = PersonaExtractor.speakers(in: r, saved: saved, owner: "Dana Lee", excluded: [])
        let moments = PersonaExtractor.moments(in: r, speakers: speakers, owner: "Dana Lee")
        XCTAssertLessThanOrEqual(moments.filter { !$0.context }.count, PersonaExtractor.maxMoments)
        XCTAssertLessThanOrEqual(moments.reduce(0) { $0 + $1.text.count + 12 }, PersonaExtractor.maxCharacters)
        let byWho = Dictionary(grouping: moments.filter { !$0.context }, by: \.who).mapValues(\.count)
        XCTAssertLessThanOrEqual(abs((byWho["P1"] ?? 0) - (byWho["P2"] ?? 0)), 1, "the people take turns")
    }

    func testTheRequestHasHandlesTheNotTrueListAndNoNameAddressTitleOrSummary() async throws {
        let saved = CoachPeople(people: [dana, sam, riley])
        let model = PersonaStubModel(evidence: [])
        let r = samCall()
        let speakers = PersonaExtractor.speakers(in: r, saved: saved, owner: "Dana Lee", excluded: [])
        _ = try await PersonaExtractor(llm: model).extract(r, speakers: speakers, owner: "Dana Lee", notTrue: ["P1 decides alone."])
        let sent = model.users.joined() + model.systems.joined()
        for word in ["Sam", "Carter", "Riley", "Dana", "sam@example.com", "Freight plan", "summary that must never"] { XCTAssertFalse(sent.contains(word), word) }
        XCTAssertTrue(sent.contains("P1") && sent.contains("Owner"))
        XCTAssertTrue(sent.contains("Not true") && sent.contains("P1 decides alone."))
        XCTAssertEqual(model.purposes, [.persona])
    }

    func testTheQuoteCheckDropsWordsThatAreNotTheirsAndKeepsAPointerNotACopy() async throws {
        let saved = CoachPeople(people: [dana, sam, riley])
        let r = samCall()
        let model = PersonaStubModel(evidence: [
            ["line": 1, "person": "P1", "quote": "Compared with what?", "dimension": "evidence", "value": "comparison", "label": "", "strength": "clear", "role": "decides"],
            ["line": 1, "person": "P1", "quote": "We should double the budget", "dimension": "evidence", "value": "numbers", "label": "", "strength": "clear", "role": "decides"],
            ["line": 0, "person": "P1", "quote": "I propose we move", "dimension": "order", "value": "answer_first", "label": "", "strength": "clear", "role": "decides"],
            ["line": 3, "person": "P1", "quote": "We went through the lanes", "dimension": "detail", "value": "detail_first", "label": "", "strength": "clear", "role": "decides"],
            ["line": 4, "person": "P1", "quote": "I need Riley to look", "dimension": "decision", "value": "needs_second_person", "label": "", "strength": "clear", "role": "decides"],
            ["line": 4, "person": "P1", "quote": "I need Riley to look", "dimension": "decision", "value": "a made up value", "label": "", "strength": "clear", "role": "decides"],
            ["line": 8, "person": "P1", "quote": "Lets try it on two lanes", "dimension": "free", "value": "starts_small", "label": "Rollout", "strength": "weak", "role": "decides"],
        ])
        let speakers = PersonaExtractor.speakers(in: r, saved: saved, owner: "Dana Lee", excluded: [])
        let result = try await PersonaExtractor(llm: model).extract(r, speakers: speakers, owner: "Dana Lee")
        let ev = result.evidence[sam.id.rawValue] ?? []
        XCTAssertEqual(ev.map(\.dimension), ["evidence", "decision", "free:rollout"], "a quote not in the line, a line of another speaker, a value off the list")
        XCTAssertEqual(result.proposed, 7)
        XCTAssertEqual(result.kept, 3)
        XCTAssertEqual(ev.first?.setting, .group)
        XCTAssertEqual(ev.first?.pointer.utterance(in: r)?.text, "Compared with what? What was the cost per load last year?")
        let stored = String(decoding: try JSONEncoder.coach.encode(ev), as: UTF8.self)
        XCTAssertFalse(stored.contains("Compared with what"), "a pointer, not a copy of the words")
    }

    func testTwoPeopleWithOneFirstNameKeepTheirOwnEvidence() async throws {
        let other = person("Sam Ortiz")
        let saved = CoachPeople(people: [dana, sam, other])
        var r = call("c1", day: 1, lines: [("Dana Lee", "Here is the plan with 3 steps."), ("Sam Carter", "What if it fails? " + [Self.filler, Self.filler, Self.filler].joined(separator: " "))])
        r.speakerNames["them:B"] = "Sam Ortiz"
        r.utterances.append(Utterance(track: .them, speakerLabel: "B", start: 50, end: 60, text: "Sam, let's go ahead. " + [Self.filler, Self.filler, Self.filler].joined(separator: " ")))
        let speakers = PersonaExtractor.speakers(in: r, saved: saved, owner: "Dana Lee", excluded: [])
        XCTAssertEqual(Set(speakers.map(\.person)), [sam.id.rawValue, other.id.rawValue])
        let model = PersonaStubModel(evidence: [
            ["line": 1, "person": "P1", "quote": "What if it fails?", "dimension": "risk", "value": "downside_first", "label": "", "strength": "clear", "role": "decides"],
            ["line": 2, "person": "P1", "quote": "let's go ahead", "dimension": "decision", "value": "in_the_room", "label": "", "strength": "clear", "role": "decides"],
        ])
        let p1 = try XCTUnwrap(speakers.first { $0.handle == "P1" })
        let result = try await PersonaExtractor(llm: model).extract(r, speakers: speakers, owner: "Dana Lee")
        XCTAssertEqual(result.evidence[p1.person]?.count, 1, "the other Sam's line is not P1's")
        XCTAssertFalse(model.users.joined().contains("Sam Carter") || model.users.joined().contains("Ortiz"), "the whole names are handles")
    }

    // MARK: Sentences

    func testTheWriterPutsTheNameBackAndSavesAFailedSentenceEmpty() async throws {
        let model = PersonaStubModel(evidence: [], traits: [
            ["id": "T1", "statement": "When a proposal has a number, P1 asks what it compares with.", "so_do_this": "Bring a comparison.", "rating": "high"],
            ["id": "T2", "statement": "P1 is anxious about freight.", "so_do_this": "Calm P1.", "rating": "low"],
        ])
        let a = PersonaTraits.build({
            var p = Persona(person: "p", updated: t0)
            p.evidence = [1, 4].map { PersonaTraitsTests.moment($0, "evidence", "comparison") } + [2, 5].map { PersonaTraitsTests.moment($0, "risk", "downside_first") }
            return p
        }(), answers: [])
        let texts = try await PersonaWriter(llm: model).write(a, first: "Sam", line: { _ in ("Compared with what?", "Here is the number.") }, notTrue: ["P1 decides alone."],
                                                              topicTerms: ["freight"], names: ["Riley Chen"], now: t0)
        let comparison = try XCTUnwrap(texts["p|evidence|comparison|any"])
        XCTAssertEqual(comparison.statement, "When a proposal has a number, Sam asks what it compares with.")
        XCTAssertEqual(comparison.rating, .high)
        XCTAssertEqual(texts["p|risk|downside_first|any"]?.statement, "", "a failed sentence does not show")
        XCTAssertTrue(model.users.joined().contains("Not true") && !model.users.joined().contains("Sam"))
    }

    func testASentenceIsWrittenAgainOnlyWhenTheEvidenceChanged() {
        var t = PersonaTrait(id: "p|order|answer_first|any", person: "p", dimension: "order", value: "answer_first", condition: nil,
                             support: [1, 4].map { PersonaTraitsTests.moment($0) }, counter: [], supportDays: 2, counterDays: 0, text: nil, answer: nil,
                             confidence: 0.4, state: .candidate)
        XCTAssertTrue(PersonaWriter.needsText(t), "2 calls and no sentence")
        t.text = PersonaText(statement: "S", soDoThis: "D", rating: .medium, written: t0, calls: 2, counter: 0)
        XCTAssertFalse(PersonaWriter.needsText(t))
        t.support += [7, 9, 11].map { PersonaTraitsTests.moment($0) }
        XCTAssertTrue(PersonaWriter.needsText(t), "3 more calls")
        t.text?.calls = 5
        t.counter = [PersonaTraitsTests.moment(12, "order", "path_first")]
        XCTAssertTrue(PersonaWriter.needsText(t), "a new contradiction")
        t.state = .confirmed
        XCTAssertFalse(PersonaWriter.needsText(t), "a confirmed sentence stays")
        t.support = [PersonaTraitsTests.moment(1)]
        t.state = .hidden
        XCTAssertFalse(PersonaWriter.needsText(t), "one call")
    }

    // MARK: The deck

    private func source(_ trait: String, state: PersonaTrait.State = .shown, calls: [String] = ["c1", "c2"]) -> PersonaFindings.Source {
        PersonaFindings.Source(trait: trait, person: "p", personName: "Sam Carter", statement: "Sam asks for the answer.", state: state, supportCalls: calls.count,
                               moments: Dictionary(uniqueKeysWithValues: calls.map { ($0, PersonaPointer(callID: $0, at: 30, line: "h")) }))
    }

    func testTheDeckAsksOneTraitForEachCallAndThreeInAWeek() {
        let calls = (1...6).map { (callID: "c\($0)", date: t0.addingTimeInterval(Double($0) * 3600)) }
        let sources = (1...6).map { source("p|t\($0)|v|any", calls: ["c\($0)"]) } + [source("p|x|v|any", state: .candidate, calls: ["c6", "c5"])]
        let cards = PersonaFindings.cards(sources, calls: calls, profile: CoachProfile(), now: t0.addingTimeInterval(86_400))
        XCTAssertEqual(cards.count, 3, "three in a week")
        XCTAssertEqual(Set(cards.keys), ["c6", "c5", "c4"], "the newest calls")
        XCTAssertTrue(cards.values.allSatisfy { $0.kind == .trait && $0.hasProof && $0.trait != nil && $0.person == "p" })
        XCTAssertEqual(cards["c6"]?.trait, "p|t6|v|any", "a newly shown trait before one below the line")
    }

    func testATraitWithAnAnswerIsNotAskedAgainAndTheWeekCountsAnswers() {
        var profile = CoachProfile()
        let calls = [(callID: "c1", date: t0), (callID: "c2", date: t0)]
        let first = PersonaFindings.cards([source("p|a|v|any")], calls: calls, profile: profile, now: t0)
        let card = try! XCTUnwrap(first.values.first)
        profile.answer(card, .no, at: t0)
        XCTAssertTrue(PersonaFindings.cards([source("p|a|v|any")], calls: calls, profile: profile, now: t0).isEmpty)
        for i in 0..<2 { profile.answer(CoachFinding(id: "x\(i)", callID: "c9", date: t0, kind: .trait, text: "t", skill: "", trait: "p|z\(i)|v|any"), .yes, at: t0) }
        XCTAssertTrue(PersonaFindings.cards([source("p|b|v|any"), source("p|c|v|any")], calls: calls, profile: profile, now: t0).isEmpty, "three answers this week")
        XCTAssertEqual(PersonaFindings.cards([source("p|b|v|any")], calls: calls, profile: profile, now: t0.addingTimeInterval(15 * 86_400)).count, 0, "the call is too old")
    }

    func testNeverBlocksTheValueForThatPerson() {
        var profile = CoachProfile()
        profile.answer(CoachFinding(id: "x", callID: "c9", date: t0, kind: .trait, text: "t", skill: "", trait: "p|order|answer_first|one_on_one"), .never, at: t0)
        let cards = PersonaFindings.cards([source("p|order|answer_first|any")], calls: [(callID: "c1", date: t0)], profile: profile, now: t0.addingTimeInterval(8 * 86_400 - 60))
        XCTAssertTrue(cards.isEmpty)
    }

    func testTheTraitCardStandsInTheCallsDeckWithinItsLimit() throws {
        let review = CoachReview(headline: "H", overview: "", strengths: [], improvements: [], focusProgress: nil)
        let card = CoachFinding(id: "c1|trait|p|a", callID: "c1", date: t0, kind: .trait, text: "Sam asks for the answer.", skill: "", at: 30, person: "p", trait: "p|a")
        let deck = FindingRules.deck(reviews: [(callID: "c1", date: t0, review: review)], profile: CoachProfile(), now: t0, traits: ["c1": card])
        XCTAssertEqual(deck.map(\.kind), [.trait])
        XCTAssertLessThanOrEqual(deck.count, FindingRules.perCall)
        var profile = CoachProfile()
        profile.answer(card, .yes, at: t0)
        XCTAssertTrue(FindingRules.deck(reviews: [(callID: "c1", date: t0, review: review)], profile: profile, now: t0, traits: ["c1": card]).isEmpty)
        XCTAssertEqual(profile.answers.first?.trait, "p|a")
    }

    // MARK: The copy for the phone

    func testTheCopyForThePhoneHasOnlyTheListedFieldsAndNoWords() throws {
        var p = Persona(person: "p", updated: t0)
        let id = "p|order|answer_first|any"
        p.evidence = [1, 4, 7].map { PersonaTraitsTests.moment($0) } + [1, 4, 7].map { PersonaTraitsTests.moment($0, "evidence", "comparison") }
            + [PersonaTraitsTests.moment(9, "risk", "downside_first")]
        p.texts[id] = PersonaText(statement: "Sam asks for the answer first.", soDoThis: "Open with the answer.", rating: .medium, written: t0, calls: 3, counter: 0)
        p.texts["p|evidence|comparison|any"] = PersonaText(statement: "Sam asks what a figure compares with.", soDoThis: "Bring a comparison.", rating: .medium,
                                                          written: t0, calls: 3, counter: 0)
        let summary = try XCTUnwrap(PersonaSummary.make(p, answers: [], name: "Sam Carter"))
        let copy = SyncedPersonas([summary, PersonaSummary(person: "empty", updated: t0, traits: [], card: nil, calls: 1, oneCall: 1)])
        XCTAssertEqual(copy.personas.map(\.person), ["p"], "only people with something shown")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: SharedPayload.personas(copy).data) as? [String: Any])
        let allowed = SyncedPersonas.allowedKeys
        XCTAssertTrue(Set(json.keys).isSubset(of: allowed["root"]!))
        for persona in json["personas"] as! [[String: Any]] {
            XCTAssertTrue(Set(persona.keys).isSubset(of: allowed["persona"]!), "\(persona.keys)")
            for t in persona["traits"] as! [[String: Any]] {
                XCTAssertTrue(Set(t.keys).isSubset(of: allowed["trait"]!), "\(t.keys)")
                for m in (t["moments"] as! [[String: Any]]) + (t["counter"] as! [[String: Any]]) { XCTAssertTrue(Set(m.keys).isSubset(of: allowed["pointer"]!)) }
            }
            let card = try XCTUnwrap(persona["card"] as? [String: Any])
            XCTAssertTrue(Set(card.keys).isSubset(of: allowed["card"]!))
            for l in card["lines"] as! [[String: Any]] { XCTAssertTrue(Set(l.keys).isSubset(of: allowed["line"]!)) }
        }
        let text = String(decoding: SharedPayload.personas(copy).data, as: UTF8.self)
        XCTAssertFalse(text.contains("downside"), "no hidden candidate")
        XCTAssertEqual(SharedPayload.personas(copy).kind, .personas)
        XCTAssertTrue(SharedPayload.isShared("personas"))
    }

    // MARK: The runner

    private func writePeople(_ people: [Person]) throws {
        try FileManager.default.createDirectory(at: paths.people, withIntermediateDirectories: true)
        try PeopleStore(directory: paths.people).replaceAll(people)
    }

    private func save(_ r: CallRecord) throws {
        try FileManager.default.createDirectory(at: paths.callDirectory(r.id), withIntermediateDirectories: true)
        try r.save(to: paths.callDirectory(r.id))
    }

    private let comparison: [String: Any] = ["line": 1, "person": "P1", "quote": "Compared with what?", "dimension": "evidence", "value": "comparison", "label": "",
                                             "strength": "clear", "role": "decides"]

    func testTheRunnerReadsEachCallOnceNeverDuringALiveCallAndStopsAtTheCap() async throws {
        try writePeople([dana, sam, riley])
        for (i, id) in ["c1", "c2", "c3"].enumerated() { try save(samCall(id, day: i * 3 + 1, title: ["Freight plan", "Hiring", "Office move"][i])) }
        let model = PersonaStubModel(evidence: [comparison], traits: [
            ["id": "T1", "statement": "When a proposal has a figure, P1 asks what it compares with.", "so_do_this": "Bring a comparison.", "rating": "medium"],
        ])
        let live = await PersonaRunner(paths: paths, llm: model, owner: "Dana Lee", now: { PersonaTraitsTests.t0.addingTimeInterval(30 * 86_400) }).run(since: nil, isLive: { true })
        XCTAssertEqual(live.calls, 0)
        XCTAssertEqual(model.users.count, 0, "no request while a call is recorded")
        let capped = await PersonaRunner(paths: paths, llm: model, owner: "Dana Lee").run(since: nil, isLive: { false }, canSpend: { _ in false }, price: { _, _ in 0.01 })
        XCTAssertEqual(capped.stopped, "the cap")
        XCTAssertEqual(model.users.count, 0)

        let report = await PersonaRunner(paths: paths, llm: model, owner: "Dana Lee", now: { PersonaTraitsTests.t0.addingTimeInterval(30 * 86_400) }).run(since: nil, isLive: { false })
        XCTAssertEqual(report.calls, 3)
        XCTAssertEqual(report.requests, 4, "three calls and one person's sentences")
        let saved = CoachPeople.read(paths: paths)
        let summary = try XCTUnwrap(PersonaReads.one(sam.id.rawValue, paths: paths, saved: saved, answers: []))
        XCTAssertEqual(summary.traits.map(\.value), ["comparison"])
        XCTAssertEqual(summary.traits.first?.statement, "When a proposal has a figure, Sam asks what it compares with.")
        let again = await PersonaRunner(paths: paths, llm: model, owner: "Dana Lee").run(since: nil, isLive: { false })
        XCTAssertEqual(again.calls, 0, "each call once")
        XCTAssertNil(PersonaStore(paths: paths).people().first { $0 == riley.id.rawValue }, "no moments for a person who only talked about the topic")
    }

    func testThePersonStepCountsItsCostBeforeItStarts() throws {
        try writePeople([dana, sam, riley])
        for (i, id) in ["c1", "c2"].enumerated() { try save(samCall(id, day: i * 3 + 1)) }
        let e = PersonaRunner.estimate(paths: paths, owner: "Dana Lee", since: nil, price: { Double($0) * 2 / 1e6 + Double($1) * 10 / 1e6 })
        XCTAssertEqual(e.calls, 2)
        XCTAssertEqual(e.requests, 3, "two calls and one person's sentences")
        XCTAssertGreaterThan(e.dollars, 0)
        XCTAssertLessThan(e.dollars, 0.1)
    }

    func testAPersonWithNoReadGetsNoEvidenceAndAnOldCallOfTheirsIsLeftOut() async throws {
        var off = sam
        off.doNotProfile = true
        try writePeople([dana, off, riley])
        try save(samCall())
        let model = PersonaStubModel(evidence: [comparison])
        _ = await PersonaRunner(paths: paths, llm: model, owner: "Dana Lee").run(since: nil, isLive: { false })
        XCTAssertTrue(PersonaStore(paths: paths).people().isEmpty)
    }
}

/// Answers the persona step's two requests by their schema, and keeps what was sent.
final class PersonaStubModel: LanguageModel, @unchecked Sendable {
    let evidence: [[String: Any]]
    let traits: [[String: Any]]
    private(set) var users: [String] = []
    private(set) var systems: [String] = []
    private(set) var purposes: [UsageEvent.Purpose] = []

    init(evidence: [[String: Any]], traits: [[String: Any]] = []) {
        self.evidence = evidence
        self.traits = traits
    }

    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort, purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        users.append(user)
        systems.append(system)
        purposes.append(purpose)
        let props = schema["properties"] as? [String: Any] ?? [:]
        let out: [String: Any] = props["evidence"] != nil ? ["evidence": evidence] : ["traits": traits]
        return try JSONDecoder().decode(Output.self, from: JSONSerialization.data(withJSONObject: out))
    }

    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String { "" }
}
