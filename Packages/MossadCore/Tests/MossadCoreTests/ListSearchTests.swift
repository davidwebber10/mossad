import XCTest
@testable import MossadCore

final class ListSearchTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let day: TimeInterval = 86_400

    func meeting(_ id: String, title: String, tags: [String] = [], names: [String: String] = [:], attendees: [String] = [],
                 turns: [(String, String)] = []) -> CallRecord {
        let start = now.addingTimeInterval(-day)
        var r = CallRecord(id: id, platform: .zoom, bundleID: "b", start: start, end: start.addingTimeInterval(1800), status: .written)
        r.calendarTitle = title
        r.tags = tags
        r.speakerNames = names
        r.attendees = attendees
        r.utterances = turns.enumerated().map { i, turn in
            let parts = turn.0.split(separator: ":")
            return Utterance(track: Track(rawValue: String(parts[0]))!, speakerLabel: String(parts[1]),
                             start: Double(i * 10), end: Double(i * 10 + 8), text: turn.1)
        }
        return r
    }

    // MARK: A page's own list

    func testListSearchNeedsEveryWordAndMarksTheTitle() {
        let s = ListSearch("dan rey")
        let m = s.match(title: "Dana Reyes", fields: [ListField("Email", "dana@example.com")])
        XCTAssertEqual(m?.source, .title)
        XCTAssertNil(m?.context)
        XCTAssertEqual(m?.title.matchedStrings, ["Dana", "Reyes"])
        XCTAssertNil(s.match(title: "Dana Fox", fields: [ListField("Email", "dana@example.com")]))
    }

    func testListSearchShowsTheFieldThatHoldsTheWords() {
        let fields = [ListField("Email", "dana@example.com"), ListField("Job title", "Head of Freight"),
                      ListField("Note", "Prefers short updates before the Monday freight call")]
        let byTitle = ListSearch("freight").match(title: "Dana Reyes", fields: fields)
        XCTAssertEqual(byTitle?.source, .field("Job title"), "A tie goes to the earlier field")
        XCTAssertEqual(byTitle?.context?.matchedStrings, ["Freight"])
        let byNote = ListSearch("monday freight").match(title: "Dana Reyes", fields: fields)
        XCTAssertEqual(byNote?.source, .field("Note"), "The field with the most words wins")
        XCTAssertEqual(byNote?.context?.matchedStrings, ["Monday", "freight"])
        let spread = ListSearch("dana head").match(title: "Dana Reyes", fields: fields)
        XCTAssertEqual(spread?.source, .field("Job title"), "Words across the title and a field still match")
        XCTAssertEqual(spread?.title.matchedStrings, ["Dana"])
    }

    func testListSearchFoldsCaseAndAccentsAndMatchesWordStarts() {
        XCTAssertNotNil(ListSearch("zoe").match(title: "Zoë Müller", fields: []))
        XCTAssertNotNil(ListSearch("MULL").match(title: "Zoë Müller", fields: []))
        XCTAssertNil(ListSearch("uller").match(title: "Zoë Müller", fields: []), "Only word starts match")
    }

    func testAnEmptyListSearchKeepsEveryRow() {
        let s = ListSearch("  ?! ")
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.match(title: "Anything", fields: []), ListMatch(title: SearchText("Anything")))
    }

    func testALongFieldIsCutAroundTheMatch() {
        let note = String(repeating: "filler words here ", count: 20) + "the pallet count" + String(repeating: " more filler", count: 20)
        let m = ListSearch("pallet").match(title: "Task", fields: [ListField("Note", note)])
        let text = m?.context?.text ?? ""
        XCTAssertLessThanOrEqual(text.count, ListSearch.snippetLength + 2)
        XCTAssertTrue(text.hasPrefix("…") && text.hasSuffix("…"))
        XCTAssertEqual(m?.context?.matchedStrings, ["pallet"])
    }

    // MARK: The Meetings list

    func testTheTitleNeedsNoLineUnderIt() {
        let index = SearchIndex(records: [meeting("1", title: "Freight budget", turns: [("them:A", "freight is late")])])
        let m = index.listMatches("freight")["1"]
        XCTAssertEqual(m?.source, .title)
        XCTAssertNil(m?.context)
        XCTAssertEqual(m?.title.matchedStrings, ["Freight"])
    }

    func testATranscriptHitShowsTheLineWithItsSpeakerAndTime() {
        let index = SearchIndex(records: [
            meeting("1", title: "Weekly sync", names: ["them:A": "Dana Reyes"],
                    turns: [("me:A", "hello"), ("them:A", "the pallet count is off by forty"), ("them:A", "pallet again")]),
            meeting("2", title: "Other", turns: [("them:A", "nothing to see")]),
        ])
        let found = index.listMatches("pallet count")
        XCTAssertEqual(Array(found.keys), ["1"])
        let m = found["1"]
        XCTAssertEqual(m?.source, .transcript(speaker: "Dana Reyes"))
        XCTAssertEqual(m?.time, 10, "The line that holds every word, not the first with one of them")
        XCTAssertEqual(m?.context?.text, "the pallet count is off by forty")
        XCTAssertEqual(m?.context?.matchedStrings, ["pallet", "count"])
    }

    func testTheTextOnAScreenIsALineOfTheScreen() {
        var r = meeting("1", title: "Review")
        r.screens = [SharedScreen(offset: 64, file: "1000.heic", text: "Warehouse capacity by region")]
        let m = SearchIndex(records: [r]).listMatches("warehouse")["1"]
        XCTAssertEqual(m?.source, .transcript(speaker: "Screen"))
        XCTAssertEqual(m?.time, 64)
    }

    func testPeopleTagsSummaryAndOutcomesAreSearched() {
        var r = meeting("1", title: "Weekly sync", tags: ["Budget"], names: ["them:A": "Dana Reyes"], attendees: ["lee@example.com"])
        r.summary = "We agreed to move the **launch** to March."
        r.topics = [SummaryTopic(title: "Hiring", summary: "Two roles stay open until **Q3**.")]
        r.decisions = [Decision(text: "Ship the carrier switch", at: 125)]
        r.actionItems = [ActionItem(parsing: "Send the rate sheet")]
        r.markers = [TranscriptMarker(offset: 300, text: "Bookmark", isBookmark: true, note: "Ask about dock doors")]
        let index = SearchIndex(records: [r])
        func place(_ q: String) -> ListMatch? { index.listMatches(q)["1"] }
        XCTAssertEqual(place("dana")?.source, .field("People"))
        XCTAssertEqual(place("lee")?.source, .field("People"))
        XCTAssertEqual(place("budget")?.source, .field("Tag"))
        XCTAssertEqual(place("launch march")?.source, .field("Summary"))
        XCTAssertEqual(place("launch march")?.context?.text, "We agreed to move the launch to March.", "No bold marks")
        XCTAssertEqual(place("roles open")?.context?.text, "Hiring: Two roles stay open until Q3.")
        XCTAssertEqual(place("carrier")?.source, .field("Decision"))
        XCTAssertEqual(place("carrier")?.time, 125)
        XCTAssertEqual(place("rate sheet")?.source, .field("Action item"))
        XCTAssertEqual(place("dock doors")?.source, .field("Bookmark"))
        XCTAssertEqual(place("dock doors")?.time, 300)
        XCTAssertNil(place("nothing here"))
    }

    func testAFieldWithEveryWordComesBeforeTheTranscript() {
        var r = meeting("1", title: "Sync", names: ["them:A": "Dana Reyes"], turns: [("them:A", "the carrier rates went up")])
        r.decisions = [Decision(text: "Switch carrier rates next month")]
        let m = SearchIndex(records: [r]).listMatches("carrier rates")["1"]
        XCTAssertEqual(m?.source, .field("Decision"))
    }

    func testWordsInDifferentPlacesStillMatch() {
        let r = meeting("1", title: "Freight sync", names: ["them:A": "Dana Reyes"], turns: [("them:A", "the pallets are late")])
        let m = SearchIndex(records: [r]).listMatches("freight pallets")["1"]
        XCTAssertNotNil(m, "Each word is somewhere in the meeting")
        XCTAssertEqual(m?.title.matchedStrings, ["Freight"])
        XCTAssertEqual(m?.source, .transcript(speaker: "Dana Reyes"), "The line shows the word the title lacks")
        XCTAssertEqual(m?.context?.matchedStrings, ["pallets"])
    }

    func testTagAndPersonFiltersNarrowTheList() {
        let a = meeting("a", title: "One", tags: ["Budget"], names: ["them:A": "Dana Reyes"], turns: [("them:A", "pallets")])
        let b = meeting("b", title: "Two", tags: ["Hiring"], names: ["them:A": "Lee Park"], turns: [("them:A", "pallets")])
        let index = SearchIndex(records: [a, b])
        XCTAssertEqual(Set(index.listMatches("#budget").keys), ["a"])
        XCTAssertEqual(index.listMatches("#budget")["a"]?.source, .field("Tag"))
        XCTAssertEqual(Set(index.listMatches("@lee").keys), ["b"])
        XCTAssertEqual(index.listMatches("@lee")["b"]?.context?.matchedStrings, ["Lee"])
        XCTAssertEqual(Set(index.listMatches("@dana pallets").keys), ["a"])
        XCTAssertEqual(Set(index.listMatches("pallets").keys), ["a", "b"])
    }

    func testAWholeEmailFindsItsMeetings() {
        let a = meeting("a", title: "One", attendees: ["dana@example.com"])
        let b = meeting("b", title: "Two", attendees: ["lee@example.com"])
        let found = SearchIndex(records: [a, b]).listMatches("Dana@Example.com")
        XCTAssertEqual(Array(found.keys), ["a"])
        XCTAssertEqual(found["a"]?.context?.matchedStrings, ["dana@example.com"])
    }

    func testOneLetterWordsMatchTitlesAndNamesOnly() {
        let r = meeting("1", title: "Q review", turns: [("them:A", "a b c")])
        let index = SearchIndex(records: [r])
        XCTAssertEqual(index.listMatches("q")["1"]?.source, .title)
        XCTAssertNil(index.listMatches("b")["1"])
    }

    func testTheListFollowsUpdatesAndRemovals() {
        let a = meeting("a", title: "One", turns: [("them:A", "old words")])
        var index = SearchIndex(records: [a, meeting("b", title: "Two")])
        XCTAssertEqual(Set(index.listMatches("old").keys), ["a"])
        var changed = a
        changed.utterances[0].text = "fresh words"
        changed.summary = "A new summary"
        index.update(changed)
        XCTAssertEqual(index.listMatches("old"), [:])
        XCTAssertEqual(index.listMatches("fresh")["a"]?.source, .transcript(speaker: "Speaker A"))
        XCTAssertEqual(index.listMatches("summary")["a"]?.source, .field("Summary"))
        XCTAssertEqual(index.listMatches("fresh"), SearchIndex(records: [changed, meeting("b", title: "Two")]).listMatches("fresh"))
        index.removeMeeting(id: "a")
        XCTAssertEqual(index.listMatches("fresh"), [:])
        index.update(meeting("c", title: "Three", turns: [("them:A", "fresh again")]))
        XCTAssertEqual(Set(index.listMatches("fresh").keys), ["c"])
    }

    func testAnEmptyQueryMatchesNothing() {
        let index = SearchIndex(records: [meeting("1", title: "One")])
        XCTAssertEqual(index.listMatches(""), [:])
        XCTAssertEqual(index.listMatches(" ?! "), [:])
    }

    func testATagClickOfMoreWordsFindsExactlyThatTag() {
        let a = meeting("a", title: "One", tags: ["Budget review"])
        let b = meeting("b", title: "Two", tags: ["Budget"], turns: [("them:A", "please review the numbers")])
        let c = meeting("c", title: "Three", tags: ["Budget"])
        let index = SearchIndex(records: [a, b, c])
        let multi = TagToken.query("Budget review")
        XCTAssertEqual(multi, "#\"Budget review\"")
        XCTAssertEqual(Set(index.listMatches(multi).keys), ["a"])
        XCTAssertEqual(MeetingSearch.matchingIDs([a, b, c], multi), ["a"], "The search before the index agrees")
        let single = TagToken.query("Budget")
        XCTAssertEqual(single, "#Budget")
        XCTAssertEqual(Set(index.listMatches(single).keys), ["b", "c"])
        XCTAssertEqual(MeetingSearch.matchingIDs([a, b, c], single), ["b", "c"])
        let palette = index.search(multi, now: now)
        var shown = palette.meetings.map(\.callID)
        if case .meeting(let m)? = palette.topHit { shown.append(m.callID) }
        XCTAssertEqual(shown, ["a"], "The palette reads the tag whole too")
        XCTAssertEqual(Set(index.listMatches("#\"Budget review\" numbers").keys), [], "Words after the tag still narrow it")
        XCTAssertEqual(Set(index.listMatches("#\"Budget\" numbers").keys), ["b"])
    }

    func testTheCallThatRecordsStaysUnderAnySearchAndFilter() {
        var live = meeting("live", title: "Current call")
        live.status = .recording
        let a = meeting("a", title: "One"), b = meeting("b", title: "Two")
        let all = [live, a, b]
        XCTAssertEqual(MeetingListRows.visible(all, found: nil, kept: nil).map(\.id), ["live", "a", "b"])
        XCTAssertEqual(MeetingListRows.visible(all, found: ["a"], kept: nil).map(\.id), ["live", "a"])
        XCTAssertEqual(MeetingListRows.visible(all, found: nil, kept: ["b"]).map(\.id), ["live", "b"])
        XCTAssertEqual(MeetingListRows.visible(all, found: ["a"], kept: ["b"]).map(\.id), ["live"])
        XCTAssertEqual(MeetingListRows.visible(all, found: [], kept: []).map(\.id), ["live"])
    }

    func testTheLineCentersOnTheWordTheTitleLacks() {
        var r = meeting("1", title: "Freight sync")
        r.summary = "Freight " + String(repeating: "and some other words ", count: 14) + "until the pallets arrive on time."
        let m = SearchIndex(records: [r]).listMatches("freight pallets")["1"]
        XCTAssertEqual(m?.source, .field("Summary"))
        XCTAssertTrue(m?.context?.matchedStrings.contains("pallets") ?? false, m?.context?.text ?? "")
        let note = "Freight " + String(repeating: "and some other words ", count: 14) + "the pallets"
        let p = ListSearch("freight pallets").match(title: "Freight lead", fields: [ListField("Note", note)])
        XCTAssertEqual(p?.context?.matchedStrings, ["pallets"])
    }

    func testASnippetNeverSplitsAMatchedWord() {
        let text = String(repeating: "x", count: 40) + " pallet " + String(repeating: "y ", count: 20) + "forklift " + String(repeating: "z ", count: 60)
        let ranges = ["pallet", "forklift"].compactMap { text.range(of: $0) }
        let s = Snippet.make(text, matches: ranges, length: 70)
        for m in s.matchedStrings { XCTAssertTrue(["pallet", "forklift"].contains(m), "Split: \(m)") }
        XCTAssertEqual(Set(s.matchedStrings), ["pallet", "forklift"], "The window with both words wins")
    }

    func testMarkingFindsWordsInsideWords() {
        let t = SearchText.marking("Call with Jóhnson about the Johnson file", query: "johnson")
        XCTAssertEqual(t.matchedStrings, ["Jóhnson", "Johnson"])
        XCTAssertEqual(SearchText.marking("Rack 12 in the north", query: "ack nor").matchedStrings, ["ack", "nor"])
        XCTAssertEqual(SearchText.marking("abc", query: "").matches, [])
    }

    func testAQueryWithNoWordsIsNoSearch() {
        XCTAssertFalse(SearchIndex.isSearch("#"))
        XCTAssertFalse(SearchIndex.isSearch("@ ?!"))
        XCTAssertFalse(SearchIndex.isSearch("#\"\""))
        XCTAssertTrue(SearchIndex.isSearch("#budget"))
        XCTAssertTrue(SearchIndex.isSearch("pallet"))
    }

    func testGeminiNotesOfANotesOnlyMeetingAreSearched() {
        var r = meeting("1", title: "Planning")
        r.gemini = GeminiNotesRef(docID: "d", title: "Notes", url: nil, eventID: nil, imported: now, notes: "Agreed to trial the forklift rental.")
        let m = SearchIndex(records: [r]).listMatches("forklift")["1"]
        XCTAssertEqual(m?.source, .field("Notes"))
    }

    // MARK: The palette

    func testBookmarkNotesHaveTheirOwnGroup() {
        var r = meeting("1", title: "Sync")
        r.markers = [TranscriptMarker(offset: 42, text: "Bookmark", isBookmark: true, note: "Dock doors quote"),
                     TranscriptMarker(offset: 50, text: "Bookmark", isBookmark: true)]
        r.decisions = [Decision(text: "Order dock doors")]
        let results = SearchIndex(records: [r]).search("dock doors", now: now)
        let all = (results.topHit.map { [$0] } ?? []) + results.bookmarks.map(SearchHit.outcome) + results.decisionsAndActions.map(SearchHit.outcome)
        let kinds = all.compactMap { hit -> OutcomeHit.Kind? in if case .outcome(let o) = hit { o.kind } else { nil } }
        XCTAssertEqual(Set(kinds), [.bookmark, .decision])
        let bookmark = all.compactMap { hit -> OutcomeHit? in if case .outcome(let o) = hit, o.kind == .bookmark { o } else { nil } }.first
        XCTAssertEqual(bookmark?.time, 42)
        XCTAssertTrue(results.sections.contains { $0.group == .bookmarks } || { if case .outcome(let o) = results.topHit, o.kind == .bookmark { return true }; return false }())
    }

    func testPeopleShowAndAreFoundByTheirJobTitle() {
        var index = SearchIndex(records: [meeting("1", title: "Sync", names: ["them:A": "Dana Reyes"])],
                                people: [VoiceProfile(name: "Dana Reyes", isOwner: false, embeddings: [])])
        var dana = Person(displayName: "Dana Reyes", origin: .call, at: now)
        dana.directory = DirectoryDetails(jobTitle: "Head of Logistics", department: nil, photoURL: nil, source: .googleDirectory, updated: now)
        index.setOtherNames([dana])
        let r = index.search("logistics", now: now)
        guard case .person(let p)? = r.topHit else { return XCTFail("The person is the top hit") }
        XCTAssertEqual(p.title, "Head of Logistics")
        XCTAssertEqual(index.search("dana", now: now).topHit.flatMap { if case .person(let p) = $0 { p.title } else { nil } }, "Head of Logistics")
    }

    func testRecentSearchesComeFirstWhenNothingIsTyped() {
        let list = SearchList(suggestions: .empty, recent: ["pallets", "#budget"])
        XCTAssertEqual(list.sections.map(\.title), ["Recent searches"])
        XCTAssertEqual(list.rowIDs, ["recent:pallets", "recent:#budget"])
        XCTAssertEqual(list.row("recent:pallets"), .recent("pallets"))
        XCTAssertEqual(list.announcement, "No results", "A recent search is not a result")
    }

    func testRecentSearchesKeepTheNewestOnceEach() {
        var r = RecentSearches()
        r.add("pallets")
        r.add("  Freight   rates ")
        r.add("PALLETS")
        r.add("?!")
        r.add("#budget")
        XCTAssertEqual(r.items, ["#budget", "PALLETS", "Freight rates"])
        r.add("budget")
        XCTAssertEqual(r.items.prefix(2), ["budget", "#budget"], "A tag and a word are two searches")
        for i in 0..<20 { r.add("query \(i)") }
        XCTAssertEqual(r.items.count, RecentSearches.limit)
        XCTAssertEqual(r.items.first, "query 19")
        r.remove("QUERY 19")
        XCTAssertEqual(r.items.first, "query 18")
        XCTAssertEqual(RecentSearches(["b", "a", "B"]).items, ["b", "a"], "Read back newest first, once each")
        r.clear()
        XCTAssertEqual(r.items, [])
    }

    // MARK: Speed

    func testListSearchOn500MeetingsOf800TurnsIsFast() throws {
        let syllables = ["ka", "lo", "mi", "ret", "san", "tu", "vor", "pel", "dra", "nix", "qu", "bo"]
        let words = (0..<3000).map { (i: Int) -> String in
            let parts: [String] = [syllables[i % 12], syllables[(i / 12) % 12], syllables[(i / 144) % 12], "s"]
            return parts.joined()
        }
        let common = ["the", "and", "we", "to", "is", "that", "it", "of"]
        var rng = SplitMix(seed: 11)
        var records: [CallRecord] = []
        for m in 0..<500 {
            var r = CallRecord(id: "m\(m)", platform: .zoom, bundleID: "b", start: now.addingTimeInterval(-Double(m) * day),
                               end: now, status: .written)
            r.calendarTitle = "\(words[m % 3000]) review \(m)"
            r.speakerNames = ["me:A": "Sam Carter", "them:A": "Person \(m % 40)"]
            r.summary = (0..<40).map { _ in words[Int(rng.next() % 3000)] }.joined(separator: " ")
            r.utterances = (0..<800).map { t in
                var line: [String] = []
                for k in 0..<14 { line.append(k % 3 == 0 ? common[Int(rng.next() % 8)] : words[Int(rng.next() % 3000)]) }
                return Utterance(track: t % 2 == 0 ? .me : .them, speakerLabel: "A", start: Double(t * 5), end: Double(t * 5 + 4),
                                 text: line.joined(separator: " "))
            }
            records.append(r)
        }
        let index = SearchIndex(records: records)
        // "and" is spoken in most lines and is in no field: each meeting scores its lines.
        let queries = ["\(words[17]) \(words[905])", "the \(words[2000])", String(words[33].prefix(3)), "review", "and"]
        _ = index.listMatches(queries[0])
        let clock = ContinuousClock()
        var worst = Duration.zero
        for q in queries {
            worst = max(worst, clock.measure { _ = index.listMatches(q) })
        }
        XCTAssertFalse(index.listMatches(queries[1]).isEmpty)
        if isDebuggerAttached() { throw XCTSkip("Timing is not meaningful under the debugger (took \(worst))") }
        XCTAssertLessThan(worst, .milliseconds(50), "Slowest list search took \(worst)")
    }
}
