import XCTest
@testable import MossadCore

final class SearchIndexTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let day: TimeInterval = 86_400

    func meeting(_ id: String, title: String, daysAgo: Double = 1, tags: [String] = [], kind: String? = nil,
                 names: [String: String] = [:], turns: [(String, String)] = [], decisions: [Decision] = [],
                 actions: [ActionItem] = []) -> CallRecord {
        let start = now.addingTimeInterval(-daysAgo * day)
        var r = CallRecord(id: id, platform: .meet, bundleID: "b", start: start, end: start.addingTimeInterval(1800), status: .written)
        r.calendarTitle = title
        r.tags = tags
        r.kind = kind
        r.speakerNames = names
        r.utterances = turns.enumerated().map { i, turn in
            let parts = turn.0.split(separator: ":")
            return Utterance(track: Track(rawValue: String(parts[0]))!, speakerLabel: String(parts[1]),
                             start: Double(i * 10), end: Double(i * 10 + 8), text: turn.1)
        }
        r.decisions = decisions
        r.actionItems = actions
        return r
    }

    func profile(_ name: String, email: String? = nil, owner: Bool = false) -> VoiceProfile {
        VoiceProfile(name: name, isOwner: owner, embeddings: [], email: email)
    }

    func search(_ index: SearchIndex, _ q: String) -> SearchResults { index.search(q, now: now) }

    /// Meeting ids of the top hit (when a meeting) followed by the meetings group.
    func meetingIDs(_ r: SearchResults) -> [String] {
        var ids: [String] = []
        if case .meeting(let m) = r.topHit { ids.append(m.callID) }
        return ids + r.meetings.map(\.callID)
    }

    func momentIDs(_ r: SearchResults) -> [String] {
        var ids: [String] = []
        if case .moment(let m) = r.topHit { ids.append(m.callID) }
        return ids + r.moments.flatMap { $0.moments.map(\.callID) }
    }

    func personNames(_ r: SearchResults) -> [String] {
        var names: [String] = []
        if case .person(let p) = r.topHit { names.append(p.name.text) }
        return names + r.people.map(\.name.text)
    }

    // MARK: Matching

    func testWordsMatchInAnyOrderAndAllMustMatch() {
        let index = SearchIndex(records: [meeting("1", title: "Freight budget review")])
        XCTAssertEqual(meetingIDs(search(index, "review freight")), ["1"])
        XCTAssertEqual(meetingIDs(search(index, "budget  FREIGHT review")), ["1"])
        XCTAssertEqual(meetingIDs(search(index, "freight missing")), [])
    }

    func testPrefixMatchesEveryWord() {
        let index = SearchIndex(records: [meeting("1", title: "Freight budget review")])
        XCTAssertEqual(meetingIDs(search(index, "freig")), ["1"])
        XCTAssertEqual(meetingIDs(search(index, "bud rev")), ["1"])
        XCTAssertEqual(meetingIDs(search(index, "eight")), [], "Only word starts match")
    }

    func testFoldsCaseDiacriticsAndCurlyQuotes() {
        let index = SearchIndex(records: [
            meeting("1", title: "Café plans", turns: [("them:A", "We don’t ship to Zürich yet")]),
        ])
        XCTAssertEqual(meetingIDs(search(index, "cafe")), ["1"])
        XCTAssertEqual(meetingIDs(search(index, "CAFÉ PLANS")), ["1"])
        XCTAssertEqual(momentIDs(search(index, "don't zurich")), ["1"])
        XCTAssertEqual(momentIDs(search(index, "dont")), ["1"])
        let moment = search(index, "zurich").allMoments.first
        XCTAssertEqual(moment?.snippet.matchedStrings, ["Zürich"])
    }

    func testOneTypoOnNamesAndTitlesButNotTranscript() {
        let index = SearchIndex(
            records: [
                meeting("1", title: "Quarterly forecast", names: ["them:A": "Michael Ross"]),
                meeting("2", title: "Standup", turns: [("them:A", "The shipment arrives Tuesday")]),
            ],
            people: [profile("Michael Ross")])
        XCTAssertEqual(personNames(search(index, "Micheal")), ["Michael Ross"], "A swap of two letters is one typo")
        XCTAssertEqual(meetingIDs(search(index, "forcast")), ["1"])
        XCTAssertEqual(meetingIDs(search(index, "quartrly forecast")), ["1"])
        XCTAssertEqual(momentIDs(search(index, "shipmnt")), [], "No typo tolerance in the transcript")
        XCTAssertEqual(momentIDs(search(index, "shipment")), ["2"])
        XCTAssertEqual(meetingIDs(search(index, "stnd")), [], "Words under 5 letters need an exact prefix")
    }

    func testNicknamesFindPeople() {
        let index = SearchIndex(
            records: [meeting("1", title: "Pricing", names: ["them:A": "Michael Ross"])],
            people: [profile("Michael Ross", email: "mross@acme.com")])
        XCTAssertEqual(personNames(search(index, "mike")), ["Michael Ross"])
        XCTAssertEqual(meetingIDs(search(index, "mike pricing")), ["1"])
        XCTAssertEqual(personNames(search(index, "mross")), ["Michael Ross"], "Email matches too")
    }

    func testExactPhraseRanksAboveScatteredWords() {
        let index = SearchIndex(records: [
            meeting("phrase", title: "Freight cost review", daysAgo: 30),
            meeting("scattered", title: "Cost review of freight", daysAgo: 1),
        ])
        XCTAssertEqual(meetingIDs(search(index, "freight cost")), ["phrase", "scattered"])
    }

    func testPhraseRanksAboveScatteredWordsInTranscript() {
        let index = SearchIndex(records: [
            meeting("phrase", title: "A", daysAgo: 30, turns: [("them:A", "the freight cost went up")]),
            meeting("scattered", title: "B", daysAgo: 1, turns: [("them:A", "cost is fine but freight is late")]),
        ])
        XCTAssertEqual(momentIDs(search(index, "freight cost")), ["phrase", "scattered"])
    }

    func testTitleOutranksTranscript() {
        let index = SearchIndex(records: [
            meeting("title", title: "Databricks migration", daysAgo: 60),
            meeting("talk", title: "Weekly sync", daysAgo: 1, turns: [("them:A", "Databricks is slow again")]),
        ])
        let r = search(index, "databricks")
        guard case .meeting(let top) = r.topHit else { return XCTFail("Expected a meeting as the top hit") }
        XCTAssertEqual(top.callID, "title")
        XCTAssertEqual(top.title.matchedStrings, ["Databricks"])
        XCTAssertTrue(r.meetings.isEmpty, "The top hit is not repeated in its group")
        XCTAssertEqual(r.moments.map(\.callID), ["talk"])
    }

    func testFieldWeightsOrderTitleTagPersonDecisionTranscript() {
        let index = SearchIndex(records: [
            meeting("transcript", title: "A", daysAgo: 1, turns: [("them:A", "orion")]),
            meeting("decision", title: "B", daysAgo: 2, decisions: [Decision(text: "Ship orion", at: 30)]),
            meeting("person", title: "C", daysAgo: 3, names: ["them:A": "Orion Black"]),
            meeting("tag", title: "D", daysAgo: 4, tags: ["Orion"]),
            meeting("title", title: "Orion launch", daysAgo: 5),
        ])
        let r = search(index, "orion")
        XCTAssertEqual(meetingIDs(r), ["title", "tag", "person"])
        XCTAssertEqual(r.decisionsAndActions.map(\.callID), ["decision"])
        XCTAssertEqual(r.decisionsAndActions.first?.time, 30)
        XCTAssertEqual(r.moments.map(\.callID), ["transcript"])
    }

    func testRecencyBreaksTies() {
        let index = SearchIndex(records: [
            meeting("old", title: "Weekly sync", daysAgo: 40),
            meeting("new", title: "Weekly sync", daysAgo: 2),
            meeting("mid", title: "Weekly sync", daysAgo: 10),
        ])
        XCTAssertEqual(meetingIDs(search(index, "weekly")), ["new", "mid", "old"])
    }

    // MARK: Filters

    func testTagFilterRestrictsToTheTag() {
        let index = SearchIndex(records: [
            meeting("1", title: "Plan", tags: ["Budget"], turns: [("them:A", "freight is up")]),
            meeting("2", title: "Plan", tags: ["Hiring"], turns: [("them:A", "freight is down")]),
        ])
        XCTAssertEqual(meetingIDs(search(index, "#budget")), ["1"])
        XCTAssertEqual(momentIDs(search(index, "#budget freight")), ["1"])
        XCTAssertEqual(meetingIDs(search(index, "#Budget plan")), ["1"])
        XCTAssertEqual(meetingIDs(search(index, "#nothing")), [])
    }

    func testPersonFilterRestrictsToMeetingsWithThatPerson() {
        let index = SearchIndex(records: [
            meeting("1", title: "Pricing", names: ["them:A": "Alex Rivera"], turns: [("them:A", "pricing is final")]),
            meeting("2", title: "Pricing", names: ["them:A": "Dana Fox"], turns: [("them:A", "pricing is open")]),
        ])
        XCTAssertEqual(momentIDs(search(index, "@alex pricing")), ["1"])
        XCTAssertEqual(meetingIDs(search(index, "@alex")), ["1"])
        XCTAssertEqual(meetingIDs(search(index, "@dana pricing")), ["2"])
    }

    // MARK: Moments

    func testMomentsUseSpeakerNames() {
        let index = SearchIndex(records: [
            meeting("1", title: "Sync", names: ["me:A": "David Webber"],
                    turns: [("me:A", "the pallet count"), ("them:B", "pallet numbers are wrong")]),
        ])
        let moments = search(index, "pallet").allMoments.sorted { $0.time < $1.time }
        XCTAssertEqual(moments.map(\.speaker), ["David Webber", "Speaker A"])
        XCTAssertEqual(moments.map(\.time), [0, 10])
    }

    func testMomentsCappedAtThreePerMeetingWithRemainingCount() {
        let turns = (0..<5).map { ("them:A", "turn \($0) about the warehouse") }
        let index = SearchIndex(records: [meeting("1", title: "Ops", turns: turns + [("them:A", "unrelated")])])
        let r = search(index, "warehouse")
        let group = r.moments.first { $0.callID == "1" }
        let shown = (group?.moments.count ?? 0) + (r.topHit.flatMap { if case .moment = $0 { 1 } else { nil } } ?? 0)
        XCTAssertEqual(shown, 3)
        XCTAssertEqual(group?.moreCount, 2)
        XCTAssertEqual(index.moments(in: "1", matching: "warehouse").map(\.time), [0, 10, 20, 30, 40])
    }

    func testSnippetCentersOnTheMatch() {
        let before = String(repeating: "alpha beta gamma ", count: 12)
        let after = String(repeating: " delta epsilon", count: 12)
        let text = before + "zebra" + after
        let index = SearchIndex(records: [meeting("1", title: "X", turns: [("them:A", text)])])
        let snippet = search(index, "zebra").allMoments[0].snippet
        XCTAssertLessThanOrEqual(snippet.text.count, 125)
        XCTAssertTrue(snippet.text.hasPrefix("…"))
        XCTAssertTrue(snippet.text.hasSuffix("…"))
        XCTAssertEqual(snippet.matchedStrings, ["zebra"])
        let r = snippet.matches[0]
        let left = snippet.text.distance(from: snippet.text.startIndex, to: r.lowerBound)
        let right = snippet.text.distance(from: r.upperBound, to: snippet.text.endIndex)
        XCTAssertLessThan(abs(left - right), 20, "The match sits near the middle")
    }

    func testSnippetAtTheEdgesOfTheText() {
        let filler = String(repeating: " alpha beta gamma", count: 12)
        let index = SearchIndex(records: [
            meeting("start", title: "X", turns: [("them:A", "Zebra" + filler)]),
            meeting("end", title: "Y", turns: [("them:A", String(filler.dropFirst()) + " zebra.")]),
            meeting("short", title: "Z", turns: [("them:A", "a zebra")]),
        ])
        let moments = Dictionary(uniqueKeysWithValues: search(index, "zebra").allMoments.map { ($0.callID, $0.snippet) })
        let start = moments["start"]!
        XCTAssertTrue(start.text.hasPrefix("Zebra"))
        XCTAssertEqual(start.matches.first?.lowerBound, start.text.startIndex)
        XCTAssertTrue(start.text.hasSuffix("…"))
        let end = moments["end"]!
        XCTAssertTrue(end.text.hasSuffix("zebra."))
        XCTAssertTrue(end.text.hasPrefix("…"))
        XCTAssertEqual(end.matchedStrings, ["zebra"])
        XCTAssertEqual(moments["short"]?.text, "a zebra")
        XCTAssertEqual(moments["short"]?.matchedStrings, ["zebra"])
    }

    func testSnippetOfAMatchLongerThanTheSnippet() {
        let long = "zebra" + String(repeating: "x", count: 200)
        let snippet = Snippet.make("see " + long + " here", matches: [])
        XCTAssertLessThanOrEqual(snippet.text.count, 125)
        let text = "see " + long + " here"
        let r = text.range(of: long)!
        let made = Snippet.make(text, matches: [r])
        XCTAssertEqual(made.matches.count, 1)
        XCTAssertTrue(made.text.contains("zebra"))
    }

    // MARK: Other groups

    func testActionItemsTasksAndChats() {
        var task = Commitment(text: "Send the pallet quote", to: "Alex Rivera", callID: "1", callTitle: "Ops",
                              madeAt: now, at: 42, due: nil)
        task.deleted = false
        var gone = Commitment(text: "Pallet audit", to: nil, callID: nil, callTitle: nil, madeAt: now, due: nil)
        gone.deleted = true
        var chat = Chat(title: "Warehouse questions")
        chat.messages = [ChatMessage(role: .user, text: "How many pallets moved last week?")]
        let index = SearchIndex(
            records: [meeting("1", title: "Ops", actions: [ActionItem(owner: "Dana", task: "Count every pallet")])],
            tasks: [task, gone], chats: [chat])
        let r = search(index, "pallet")
        XCTAssertEqual(r.decisionsAndActions.map(\.text.text), ["Dana: Count every pallet"])
        XCTAssertEqual(r.decisionsAndActions.first?.kind, .actionItem)
        let tasks = r.tasks + [r.topHit].compactMap { if case .task(let t) = $0 { t } else { nil } }
        XCTAssertEqual(tasks.map(\.commitmentID), [task.id])
        XCTAssertEqual(tasks.first?.text.matchedStrings, ["pallet"])
        let chats = r.chats + [r.topHit].compactMap { if case .chat(let c) = $0 { c } else { nil } }
        XCTAssertEqual(chats.map(\.chatID), [chat.id])
        XCTAssertEqual(chats.first?.snippet?.matchedStrings, ["pallets"])
    }

    func testGroupsComeInOrderAndHitsAreFlattened() {
        let index = SearchIndex(
            records: [meeting("1", title: "Orion", names: ["them:A": "Orion Black"], turns: [("them:A", "orion")],
                              decisions: [Decision(text: "Orion ships")])],
            people: [profile("Orion Black")])
        let r = search(index, "orion")
        XCTAssertEqual(r.sections.map(\.group), [.topHit, .people, .moments, .decisionsAndActions])
        XCTAssertEqual(r.hits.count, r.sections.reduce(0) { $0 + $1.hits.count })
        XCTAssertEqual(Set(r.hits.map(\.id)).count, r.hits.count, "Ids are unique for SwiftUI lists")
    }

    // MARK: Updates and edge cases

    func testUpdatingOneMeetingMatchesAFullRebuild() {
        let a = meeting("1", title: "Old title", turns: [("them:A", "legacy words here")])
        let b = meeting("2", title: "Other", turns: [("them:A", "legacy too")])
        var index = SearchIndex(records: [a, b])
        var changed = a
        changed.customTitle = "Fresh title"
        changed.utterances[0].text = "brand new words"
        index.update(changed)
        XCTAssertEqual(meetingIDs(search(index, "fresh")), ["1"])
        XCTAssertEqual(meetingIDs(search(index, "old")), [])
        XCTAssertEqual(momentIDs(search(index, "legacy")), ["2"])
        XCTAssertEqual(momentIDs(search(index, "brand")), ["1"])
        let rebuilt = SearchIndex(records: [changed, b])
        for q in ["fresh", "legacy", "brand new", "title", "words"] {
            XCTAssertEqual(search(index, q), search(rebuilt, q), q)
        }
        index.removeMeeting(id: "1")
        XCTAssertEqual(meetingIDs(search(index, "fresh")), [])
        XCTAssertEqual(momentIDs(search(index, "brand")), [])
        index.update(meeting("3", title: "Added later"))
        XCTAssertEqual(meetingIDs(search(index, "added")), ["3"])
    }

    func testManyUpdatesStayCorrect() {
        var index = SearchIndex(records: [meeting("1", title: "Start", turns: [("them:A", "word0")])])
        for i in 1...50 {
            index.update(meeting("1", title: "Start", turns: [("them:A", "word\(i)")]))
        }
        XCTAssertEqual(momentIDs(search(index, "word50")), ["1"])
        XCTAssertEqual(momentIDs(search(index, "word49")), [])
        XCTAssertEqual(search(index, "word").allMoments.count, 1)
    }

    func testEmptyWhitespaceAndPunctuationQueries() {
        let index = SearchIndex(records: [meeting("1", title: "Sync", turns: [("them:A", "hello?")])])
        XCTAssertEqual(search(index, ""), .empty)
        XCTAssertEqual(search(index, "   \n\t"), .empty)
        XCTAssertEqual(search(index, "?!… — ,."), .empty)
        XCTAssertEqual(search(index, "#"), .empty)
        XCTAssertTrue(SearchResults.empty.isEmpty)
    }

    func testSuggestionsShowRecentMeetingsAndMostMetPeople() {
        let index = SearchIndex(
            records: [
                meeting("1", title: "One", daysAgo: 3, tags: ["Budget"], names: ["me:A": "David Webber", "them:A": "Alex Rivera"]),
                meeting("2", title: "Two", daysAgo: 1, tags: ["Budget", "Hiring"], names: ["me:A": "David Webber", "them:A": "Alex Rivera"]),
                meeting("3", title: "Three", daysAgo: 2, names: ["me:A": "David Webber", "them:A": "Dana Fox"]),
            ],
            people: [profile("David Webber", owner: true), profile("Alex Rivera"), profile("Dana Fox")])
        let s = index.suggestions(meetings: 2, people: 5)
        XCTAssertEqual(s.meetings.map(\.callID), ["2", "3"])
        XCTAssertEqual(s.people.map(\.name.text), ["Alex Rivera", "Dana Fox"], "The owner is left out")
        XCTAssertEqual(s.people.first?.meetings, 2)
        XCTAssertEqual(s.tags, ["Budget", "Hiring"])
    }

    // MARK: Speed

    func testTwoWordQueryOn500MeetingsOf800TurnsIsFast() throws {
        let words = (0..<3000).map { i -> String in
            let syllables = ["ka", "lo", "mi", "ret", "san", "tu", "vor", "pel", "dra", "nix", "qu", "bo"]
            return syllables[i % 12] + syllables[(i / 12) % 12] + syllables[(i / 144) % 12] + "s"
        }
        let common = ["the", "and", "we", "to", "is", "that", "it", "of"]
        var rng = SplitMix(seed: 7)
        var records: [CallRecord] = []
        records.reserveCapacity(500)
        for m in 0..<500 {
            var r = CallRecord(id: "m\(m)", platform: .zoom, bundleID: "b", start: now.addingTimeInterval(-Double(m) * day),
                               end: now, status: .written)
            r.calendarTitle = "\(words[m % 3000]) review \(m)"
            r.speakerNames = ["me:A": "David Webber", "them:A": "Person \(m % 40)"]
            r.utterances = (0..<800).map { t in
                var line: [String] = []
                for k in 0..<14 { line.append(k % 3 == 0 ? common[Int(rng.next() % 8)] : words[Int(rng.next() % 3000)]) }
                return Utterance(track: t % 2 == 0 ? .me : .them, speakerLabel: "A", start: Double(t * 5), end: Double(t * 5 + 4),
                                 text: line.joined(separator: " "))
            }
            records.append(r)
        }
        let index = SearchIndex(records: records)
        let queries = ["\(words[17]) \(words[905])", "\(words[1200]) \(words[33].prefix(4))", "the \(words[2000])"]
        _ = index.search(queries[0], now: now)
        let clock = ContinuousClock()
        var worst = Duration.zero
        for q in queries {
            let elapsed = clock.measure { _ = index.search(q, now: now) }
            worst = max(worst, elapsed)
        }
        let r = index.search(queries[0], now: now)
        XCTAssertFalse(r.allMoments.isEmpty)
        // One limit for both builds: the slowest query measured about 10 ms in the unoptimized build that
        // `swift test` makes and under 1 ms in release, so 50 ms needs no extra margin for debug.
        let limit = Duration.milliseconds(50)
        if isDebuggerAttached() { throw XCTSkip("Timing is not meaningful under the debugger (took \(worst))") }
        XCTAssertLessThan(worst, limit, "Slowest query took \(worst)")
    }
}

/// A small seeded generator, so the speed test builds the same data every run.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func isDebuggerAttached() -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
    return info.kp_proc.p_flag & P_TRACED != 0
}
