import XCTest
@testable import MossadCore

/// The digest: what the Mac computes for the server's MCP with the app's own rules, in parts that each change alone,
/// from allowed-field lists, with no calendar or invite data, and nothing the coach learned about a person who keeps
/// no read (nothing about any person with the switch for other AI apps off).
final class ServerDigestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // Jan 15, 2027, 02:00 in Chicago
    private var paths: Paths!
    private var zone: TimeZone!

    private var people: [Person] {
        var dana = Person(id: PersonID(rawValue: "id-dana"), displayName: "Dana Lee", origin: .migration, at: now)
        dana.doNotProfile = true
        return [Person(id: PersonID(rawValue: "id-owner"), displayName: "Avery Webb", isOwner: true, origin: .owner, at: now),
                Person(id: PersonID(rawValue: "id-sam"), displayName: "Sam Carter", origin: .migration, at: now), dana,
                Person(id: PersonID(rawValue: "id-riley"), displayName: "Riley Stone", origin: .migration, at: now)]
    }

    private func meeting(_ id: String, _ title: String, start: Date, minutes: Double, series: String? = nil) -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "b", start: start, end: start.addingTimeInterval(minutes * 60), status: .written)
        r.calendarTitle = title
        r.calendarSeriesID = series
        r.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter"]
        r.speakerPeople = ["me:A": "id-owner", "them:A": "id-sam"]
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 200, text: "Thanks all."),
                        Utterance(track: .them, speakerLabel: "A", start: 200, end: 400, text: "Sure.")]
        return r
    }

    /// Two meetings of a weekly series a week apart, invited with an address and a person who never spoke; one
    /// meeting of December; one call today; and a series that ended in September.
    private func records() -> [CallRecord] {
        var out: [CallRecord] = []
        for (n, id) in [(1, "20270108-100000"), (2, "20270113-100000")] {
            let start = now.addingTimeInterval(-Double(3 - n) * 6 * 86_400)
            var r = CallRecord(id: id, platform: .meet, bundleID: "b", start: start, end: start.addingTimeInterval(1800), status: .written)
            r.calendarTitle = "Weekly sync"
            r.calendarSeriesID = "g-weekly"
            r.attendees = ["Sam Carter", "Dana Lee", "Riley Stone", "guest.one@example.com"]
            r.invitees = [Invitee(name: nil, email: "guest.one@example.com"), Invitee(name: "Riley Stone", email: "riley@example.com")]
            r.plannedStart = start
            r.plannedEnd = start.addingTimeInterval(1500)
            r.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter", "them:B": "Dana Lee"]
            r.speakerPeople = ["me:A": "id-owner", "them:A": "id-sam", "them:B": "id-dana"]
            r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 300, text: "Let us look at the roadmap."),
                            Utterance(track: .them, speakerLabel: "A", start: 300, end: 900, text: "The roadmap slips."),
                            Utterance(track: .them, speakerLabel: "B", start: 900, end: 1200, text: "Agreed.")]
            r.summary = "Roadmap."
            r.actionItems = [ActionItem(owner: "Sam Carter", task: "Draft the plan", ownerID: "id-sam")]
            r.decisions = [Decision(text: "Ship in March")]
            r.markers = [TranscriptMarker(offset: 310, text: "★", isBookmark: true, note: "Slip \(n)")]
            if n == 2 {
                // A voice that was named by an address, with an item of its own.
                r.speakerNames["them:C"] = "pat.voice@example.com"
                r.utterances.append(Utterance(track: .them, speakerLabel: "C", start: 1200, end: 1500, text: "Sounds good."))
                r.actionItems.append(ActionItem(owner: "pat.voice@example.com", task: "Send the deck"))
            }
            out.append(r)
        }
        var dec = CallRecord(id: "20261220-090000", platform: .zoom, bundleID: "b", start: now.addingTimeInterval(-26 * 86_400),
                             end: now.addingTimeInterval(-26 * 86_400 + 900), status: .written)
        dec.calendarTitle = "Year end"
        dec.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter"]
        dec.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 200, text: "Thanks all.")]
        out.append(dec)
        out.append(meeting("20270115-010000", "Quick chat", start: now.addingTimeInterval(-3600), minutes: 10))
        out.append(meeting("20260917-030000", "Old standup", start: now.addingTimeInterval(-120 * 86_400), minutes: 15, series: "g-old"))
        out.append(meeting("20260924-030000", "Old standup", start: now.addingTimeInterval(-113 * 86_400), minutes: 15, series: "g-old"))
        return out
    }

    override func setUpWithError() throws {
        // The fixtures are the same in any time zone of the Mac that writes or checks them.
        zone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Chicago")!
        paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        for r in records() {
            try FileManager.default.createDirectory(at: paths.callDirectory(r.id), withIntermediateDirectories: true)
            try r.save(to: paths.callDirectory(r.id))
        }
        // In the last call: a card for the owner, and conclusions about Dana (who keeps no read) and about the call.
        var review = CoachReview(headline: "H", overview: "", strengths: [], improvements: [], focusProgress: nil)
        review.tryNext = CoachNote(text: "When you take an item, say the day.", quote: "Let us look at the roadmap.", at: 0,
                                   say: "I will send it by Friday.", skill: CoachSkill.commitmentDates.rawValue)
        try review.save(in: paths.callDirectory("20270113-100000"))
        // In today's call: a card on the owner's behavior that names Sam, and a conclusion about Sam.
        var first = CoachReview(headline: "H", overview: "", strengths: [], improvements: [], focusProgress: nil)
        first.tryNext = CoachNote(text: "Let Sam Carter finish before you answer.", quote: "Thanks all.", at: 0,
                                  say: "Go on, Sam.", skill: CoachSkill.interruptions.rawValue)
        try first.save(in: paths.callDirectory("20270115-010000"))
        var profile = CoachProfile()
        var dana = CoachQuestion(statement: "Dana prefers email.", kind: .relationship, evidence: "Agreed.", callID: "20270113-100000", at: 900, asked: now)
        dana.person = "id-dana"
        dana.id = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!
        var call = CoachQuestion(statement: "This call sets the plan for March.", kind: .thisCall, evidence: "The roadmap slips.", callID: "20270113-100000",
                                 at: 300, asked: now)
        call.id = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
        var sam = CoachQuestion(statement: "Sam reports to you.", kind: .relationship, evidence: "Sure.", callID: "20270115-010000", at: 200, asked: now)
        sam.person = "id-sam"
        sam.personName = "Sam Carter"
        sam.id = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        profile.questions = [dana, call, sam]
        var focus = CoachFocus(plan: "Name a date when you take an item", why: "Items without dates slip.", metric: nil, proposed: now)
        focus.status = .active
        profile.foci = [focus]
        try profile.save(to: paths.coach)
        // The calendar says the series meets tomorrow: none of it may go to the server.
        var e = CalendarEventInfo(title: "Weekly sync", start: now.addingTimeInterval(86_400), end: now.addingTimeInterval(88_200),
                                  attendees: ["Sam Carter", "secret.guest@example.com"], text: "https://meet.google.com/abc-defg-hij", isAllDay: false)
        e.seriesID = "g-weekly"
        try CalendarSnapshot([e], saved: now).save(to: paths.calendar)
    }

    override func tearDown() {
        NSTimeZone.default = zone
    }

    private func tools(coach: Bool = true, records: [CallRecord]? = nil) -> ChatTools {
        var s = ToolSettings()
        s.coach = coach
        return ChatTools(records: records ?? self.records(), owner: "Avery Webb", paths: paths, people: people, settings: s, now: now)
    }

    private func make(_ tools: ChatTools, personas: Bool = true, cache: DigestCache? = nil) -> [SharedPayload] {
        ServerDigest.parts(tools, personasInMCP: personas, cache: cache) ?? []
    }

    private func parts(personas: Bool = true, coach: Bool = true) -> [String: Data] {
        Dictionary(make(tools(coach: coach), personas: personas).map { ($0.key, $0.data) }, uniquingKeysWith: { a, _ in a })
    }

    private func json(_ data: Data?) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any]) }
    private func text(_ data: Data?) -> String { data.map { String(decoding: $0, as: UTF8.self) } ?? "" }

    func testTheDigestHasOnePartForEachKindAndOneForEachMonthOfMeetings() {
        XCTAssertEqual(Set(parts().keys), ["digest:series", "digest:bookmarks", "digest:analytics", "digest:coach", "digest:meetings-2027-01",
                                           "digest:meetings-2026-12", "digest:meetings-2026-09"])
        XCTAssertEqual(ServerDigest.month(of: "20270113-100000"), "2027-01")
        XCTAssertEqual(ServerDigest.month(of: "20270113-100000-notes"), "2027-01")
        XCTAssertEqual(ServerDigest.month(of: "imported"), "other")
    }

    func testEveryPartHasOnlyItsAllowedKeysAVersionAndWhenItWasMade() throws {
        var levels = Set<String>()
        func check(_ value: Any, level: String, path: String) {
            if let object = value as? [String: Any] {
                levels.insert(level)
                let allowed = try? XCTUnwrap(ServerDigest.allowedKeys[level], "\(path): no list for \(level)")
                XCTAssertTrue(Set(object.keys).isSubset(of: allowed ?? []), "\(path): \(Set(object.keys).subtracting(allowed ?? []))")
                for (k, v) in object { check(v, level: ServerDigest.childLevel[level + "." + k] ?? level, path: path + "." + k) }
            } else if let list = value as? [Any] {
                for v in list { check(v, level: level, path: path) }
            }
        }
        let all = parts()
        XCTAssertEqual(all.count, 7)
        for (key, data) in all {
            let root = try json(data)
            XCTAssertEqual(root["version"] as? Int, ServerDigest.version, key)
            XCTAssertNotNil(root["made"], key)
            check(root, level: ServerDigest.rootLevel(of: key), path: key)
        }
        // Every list of keys was used at least once, so none of them passes only because it had nothing to check.
        XCTAssertEqual(levels, Set(ServerDigest.allowedKeys.keys).subtracting(["result", "cost"]))
    }

    /// The owner's decision: no calendar and no invite data on the server. A person is a name with an id, from the
    /// voices of a meeting; never someone who was only invited, never an address, never an invite's times or counts.
    func testNoPartHoldsAnAddressAnInvitedOnlyPersonOrTheInvitesTimes() throws {
        let address = try NSRegularExpression(pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: .caseInsensitive)
        for (key, data) in parts() {
            let s = text(data)
            XCTAssertNil(address.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), "\(key) holds an address")
            XCTAssertFalse(s.contains("@"), key)
            for word in ["Riley Stone", "secret.guest", "meet.google.com", "\"next\"", "upcoming", "plannedMinutes", "lateMinutes", "overMinutes",
                         "participation", "\"scheduled\"", "\"unscheduled\"", "invited"] {
                XCTAssertFalse(s.contains(word), "\(key): \(word)")
            }
        }
        let series = try XCTUnwrap(try json(parts()["digest:series"])["series"] as? [[String: Any]])
        let weekly = try XCTUnwrap(series.first)
        let attendees = (weekly["attendees"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(attendees), ["Sam Carter", "Dana Lee"], "the named voices that are saved people")
        let stats = try XCTUnwrap(weekly["stats"] as? [String: Any])
        XCTAssertNil(stats["planned"])
        XCTAssertFalse((weekly["line"] as? String ?? "").contains("over"), "no overrun from the invite's end")
        // The calendar's ids are kept only as hashes; the server compares hashes.
        for k in weekly["keys"] as? [String] ?? [] { XCTAssertTrue(k.hasPrefix("h:"), k) }
        XCTAssertEqual(weekly["id"] as? String, "cal:g-weekly")
        XCTAssertEqual(ServerDigest.publicKey("cal:ek:ABC@google.com"), ServerDigest.publicKey("cal:ek:abc@google.com"))
        XCTAssertTrue(ServerDigest.publicID("cal:ek:abc@google.com").hasPrefix("h:"))
        XCTAssertEqual(ServerDigest.publicID("cal:g-weekly"), "cal:g-weekly")
        // A voice named by an address is a speaker with no name.
        let jan = try XCTUnwrap(try json(parts()["digest:meetings-2027-01"])["meetings"] as? [[String: Any]])
        let last = try XCTUnwrap(jan.first { $0["callID"] as? String == "20270113-100000" })
        let speakers = (last["speakers"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        XCTAssertTrue(speakers.contains("Speaker C"), "\(speakers)")
    }

    func testAnEndedSeriesIsNotSentAndTheCalendarNeverGoes() throws {
        let series = try XCTUnwrap(try json(parts()["digest:series"])["series"] as? [[String: Any]])
        XCTAssertEqual(series.map { $0["title"] as? String }, ["Weekly sync"], "Old standup has two meetings and ended")
        XCTAssertEqual((series.first?["rows"] as? [Any])?.count, 2)
    }

    /// With the switch for other AI apps off, nothing the coach wrote about a person goes; with it on, the person's
    /// own switch decides, and a card carries the person's id so the server can check it again.
    func testCardsAboutAPersonFollowTheSwitchAndThePersonsOwnRead() throws {
        let on = text(parts(personas: true)["digest:coach"])
        XCTAssertTrue(on.contains("When you take an item, say the day."), on)
        XCTAssertTrue(on.contains("Sam reports to you."), "about Sam, who keeps a read")
        XCTAssertTrue(on.contains("\"personID\":\"id-sam\""), on)
        XCTAssertTrue(on.contains("Let Sam Carter finish"))
        XCTAssertFalse(on.contains("Dana prefers email"), "a card about a person who keeps no read")
        // Dana's card used no place of the call: the call's other conclusion is there.
        XCTAssertTrue(on.contains("This call sets the plan for March."), on)
        XCTAssertTrue(on.contains("Name a date when you take an item"), "the goal")

        let off = text(parts(personas: false)["digest:coach"])
        XCTAssertFalse(off.contains("Sam reports to you."), "a conclusion about a person")
        XCTAssertFalse(off.contains("Let Sam Carter finish"), "a card that names a person")
        XCTAssertFalse(off.contains("personID"))
        XCTAssertFalse(off.contains("Dana prefers email"))
        XCTAssertTrue(off.contains("When you take an item, say the day."), "the owner's own behavior")
        XCTAssertTrue(off.contains("This call sets the plan for March."), "about the call, not a person")
        // Per-person numbers of a series are plain facts and stay.
        XCTAssertTrue(text(parts(personas: false)["digest:series"]).contains("Dana Lee"))
    }

    func testTheCoachOffSaysSo() throws {
        let coach = try json(parts(coach: false)["digest:coach"])
        XCTAssertEqual(coach["coachOn"] as? Bool, false)
        XCTAssertEqual((coach["findings"] as? [Any])?.count, 0)
    }

    func testBookmarksAndMeetingNumbersAreThere() throws {
        let marks = try XCTUnwrap(try json(parts()["digest:bookmarks"])["bookmarks"] as? [[String: Any]])
        XCTAssertEqual(Set(marks.compactMap { $0["note"] as? String }), ["Slip 1", "Slip 2"])
        let jan = try XCTUnwrap(try json(parts()["digest:meetings-2027-01"])["meetings"] as? [[String: Any]])
        XCTAssertEqual(Set(jan.compactMap { $0["callID"] as? String }), ["20270108-100000", "20270113-100000", "20270115-010000"])
        let speakers = try XCTUnwrap(jan.first { $0["callID"] as? String == "20270113-100000" }?["speakers"] as? [[String: Any]])
        XCTAssertTrue(speakers.contains { $0["name"] as? String == "Sam Carter" })
        let dec = try XCTUnwrap(try json(parts()["digest:meetings-2026-12"])["meetings"] as? [[String: Any]])
        XCTAssertTrue((dec.first?["sentences"] as? [String] ?? []).contains { $0.hasPrefix("You were the only voice") }, "\(dec)")
    }

    func testABookmarksLineIsCut() {
        var r = meeting("20270110-100000", "Long", start: now.addingTimeInterval(-86_400 * 5), minutes: 30)
        r.utterances = [Utterance(track: .them, speakerLabel: "A", start: 0, end: 600, text: String(repeating: "word ", count: 400))]
        r.markers = [TranscriptMarker(offset: 10, text: "★", isBookmark: true, note: "Long one")]
        let said = ServerDigest.bookmarks(tools(records: [r])).first?.said ?? ""
        XCTAssertLessThanOrEqual(said.count, ServerDigest.saidLimit + 1)
        XCTAssertTrue(said.hasSuffix("…"))
    }

    /// The periods are the app's: "Last 30 days" starts 29 days before today and ends now, so today's call counts.
    func testThePeriodsAreTheAppsPeriods() throws {
        let periods = try XCTUnwrap(try json(parts()["digest:analytics"])["periods"] as? [[String: Any]])
        XCTAssertEqual(periods.compactMap { $0["days"] as? Int }, [7, 30, 90, 365])
        let month = try XCTUnwrap(periods.first { $0["days"] as? Int == 30 })
        let interval = AnalyticsRange.last30Days.interval(now: now)
        let app = AnalyticsReport(records: records(), usage: [], owner: "Avery Webb", interval: interval)
        XCTAssertEqual(month["calls"] as? Int, app.calls)
        XCTAssertEqual(app.calls, 4, "with today's call")
        let from = try XCTUnwrap(JSONDecoder.callRecord.decode(Date.self, from: JSONSerialization.data(withJSONObject: month["from"]!, options: .fragmentsAllowed)))
        XCTAssertEqual(from, interval.start)
        let year = try XCTUnwrap(periods.first { $0["days"] as? Int == 365 })
        let yearFrom = try XCTUnwrap(JSONDecoder.callRecord.decode(Date.self, from: JSONSerialization.data(withJSONObject: year["from"]!, options: .fragmentsAllowed)))
        XCTAssertEqual(yearFrom, Calendar.current.date(byAdding: .day, value: -364, to: Calendar.current.startOfDay(for: now)))
    }

    func testAMonthWithNoMeetingLeftLeavesTheServerAndADeletedMeetingLeavesItsMonth() async throws {
        let store = MemoryStore(view: true)
        let sync = CloudSync(paths: paths, store: store)
        try await sync.pushShared(people: true, digest: make(tools()))
        let before = await store.entries["digest-meetings-2026-12"]?.deleted
        XCTAssertEqual(before, false)
        // The December meeting is deleted: its month goes; a later sync with no digest (a call) deletes nothing.
        try FileManager.default.removeItem(at: paths.callDirectory("20261220-090000"))
        let rest = records().filter { $0.id != "20261220-090000" }
        try await sync.pushShared(people: true)
        let kept = await store.entries["digest-meetings-2026-12"]?.deleted
        XCTAssertEqual(kept, false, "no digest made, nothing deleted")
        try await sync.pushShared(people: true, digest: make(tools(records: rest)))
        let gone = await store.entries["digest-meetings-2026-12"]?.deleted
        XCTAssertEqual(gone, true)
    }

    /// A digest from no meeting (the list not read yet) deletes no month on the server.
    func testADigestFromNoMeetingDeletesNoMonth() async throws {
        let store = MemoryStore(view: true)
        let sync = CloudSync(paths: paths, store: store)
        try await sync.pushShared(people: true, digest: make(tools()))
        try await sync.pushShared(people: true, digest: make(tools(records: [])))
        let deletes = await store.deletes
        XCTAssertEqual(deletes.filter { $0.hasPrefix("digest") }, [])
    }

    /// The digest goes to the owner's server, the same parts each time, and never to iCloud.
    func testTheDigestGoesToTheServerAndNeverToICloud() async throws {
        let digest = make(tools())
        let cloud = MemoryStore(view: false)
        try await CloudSync(paths: paths, store: cloud).pushShared(people: true, digest: digest)
        let names = await cloud.entries.keys.filter { $0.hasPrefix("digest") }
        XCTAssertTrue(names.isEmpty)
        let server = MemoryStore(view: true)
        try await CloudSync(paths: paths, store: server).pushShared(people: true, digest: digest)
        let sent = await server.entries.filter { $0.key.hasPrefix("digest") }
        XCTAssertEqual(Set(sent.keys), Set(digest.map { CloudSync.recordName($0.key) }))
        for p in digest { XCTAssertEqual(sent[CloudSync.recordName(p.key)]?.data["data"], p.data, p.key) }
    }

    /// The Mac knows whether every part arrived: a part the server refused is sent again at the next sync.
    func testTheSyncSaysWhetherEveryPartArrived() async throws {
        let digest = make(tools())
        let store = MemoryStore(view: true)
        await store.refuse("digest-coach")
        let sync = CloudSync(paths: paths, store: store)
        try await sync.pushShared(people: true, digest: digest)
        let first = try await sync.holds(digest)
        XCTAssertFalse(first)
        await store.refuse(nil)
        try await sync.pushShared(people: true, digest: digest)
        let second = try await sync.holds(digest)
        XCTAssertTrue(second)
    }

    /// A call that starts stops the copy before the next part of the digest.
    func testACallStopsTheCopyBeforeTheNextPart() async throws {
        let digest = make(tools())
        let store = MemoryStore(view: true)
        let checks = StopCount()
        try await CloudSync(paths: paths, store: store).pushShared(people: true, stop: { checks.next() > 2 }, digest: digest)
        let sent = await store.entries.keys.filter { $0.hasPrefix("digest") }
        XCTAssertEqual(sent.count, 1)
    }

    /// A stop while the months are made sends nothing, and keeps the months already made for the next time.
    func testAStopWhileTheMonthsAreMadeSendsNothingAndKeepsWhatWasMade() {
        let checks = StopCount()
        let stopped = ServerDigest.parts(tools(), personasInMCP: true, cache: DigestCache(directory: paths.sync), stop: { checks.next() > 1 })
        XCTAssertNil(stopped)
        let next = DigestCache(directory: paths.sync)
        XCTAssertNotNil(ServerDigest.parts(tools(), personasInMCP: true, cache: next))
        XCTAssertEqual(next.made, 2, "one of three months came from the first run")
    }

    /// The app's one cache of the meetings' facts: a digest reads no meeting again for its history or the goal.
    func testTheDigestUsesTheAppsFactsOfTheMeetings() {
        let facts = MeetingFactsCache()
        _ = ServerDigest.parts(tools(), personasInMCP: true, facts: facts)
        let read = facts.readCount
        XCTAssertEqual(read, records().count, "the digest read each meeting into the app's cache")
        _ = ServerDigest.parts(tools(), personasInMCP: true, cache: DigestCache(directory: nil), facts: facts)
        XCTAssertEqual(facts.readCount, read, "and the next digest read none again")
    }

    func testAMonthIsMadeAgainOnlyWhenItsMeetingsChanged() throws {
        let cache = DigestCache(directory: paths.sync)
        let first = make(tools(), cache: cache)
        XCTAssertEqual(cache.made, 3, "three months made")
        let second = make(tools(), cache: DigestCache(directory: paths.sync))
        XCTAssertEqual(first.map(\.hash).sorted(), second.map(\.hash).sorted())
        let reread = DigestCache(directory: paths.sync)
        _ = make(tools(), cache: reread)
        XCTAssertEqual(reread.made, 0, "every month from the cache")
        // A new action item changes the month's outcomes.
        var changed = records()
        changed[0].actionItems.append(ActionItem(owner: "Sam Carter", task: "Book the room"))
        let again = DigestCache(directory: paths.sync)
        _ = make(tools(records: changed), cache: again)
        XCTAssertEqual(again.made, 1)
    }

    func testWhenTheDigestIsMadeAgain() {
        let key = DigestPlan.key(meetings: 3, coach: 1, commitments: 2, personas: true, day: now)
        XCTAssertTrue(DigestPlan.makes(server: true, calling: false, meetingsLoaded: true, key: key, sent: nil))
        XCTAssertFalse(DigestPlan.makes(server: true, calling: false, meetingsLoaded: true, key: key, sent: key), "nothing changed")
        XCTAssertTrue(DigestPlan.makes(server: true, calling: false, meetingsLoaded: true,
                                       key: DigestPlan.key(meetings: 4, coach: 1, commitments: 2, personas: true, day: now), sent: key))
        XCTAssertTrue(DigestPlan.makes(server: true, calling: false, meetingsLoaded: true,
                                       key: DigestPlan.key(meetings: 3, coach: 1, commitments: 2, personas: true, day: now.addingTimeInterval(86_400)), sent: key),
                      "a new day moves the periods")
        XCTAssertFalse(DigestPlan.makes(server: true, calling: true, meetingsLoaded: true, key: key, sent: nil), "never during a call")
        XCTAssertFalse(DigestPlan.makes(server: true, calling: false, meetingsLoaded: false, key: key, sent: nil), "not before the meetings are read")
        XCTAssertFalse(DigestPlan.makes(server: false, calling: false, meetingsLoaded: true, key: key, sent: nil), "only with a server")
    }

    /// The fixtures the server's tests read, written by this encoder (`MOSSAD_WRITE_FIXTURES=1`).
    func testThePartsAreTheFilesTheServersTestsRead() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("server/test/fixtures")
        let write = ProcessInfo.processInfo.environment["MOSSAD_WRITE_FIXTURES"] == "1"
        let all = parts()
        XCTAssertEqual(all.count, 7)
        for (key, data) in all {
            let url = folder.appendingPathComponent(key.replacingOccurrences(of: ":", with: "-") + ".json")
            if write {
                try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.prettyPrinted, .sortedKeys]).write(to: url)
                continue
            }
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary, try JSONSerialization.jsonObject(with: data) as? NSDictionary, key)
        }
    }

    /// The sizes for 1,500 meetings over two years and 60 series.
    func testTheSizesStayBounded() throws {
        var many: [CallRecord] = []
        let start0 = now.addingTimeInterval(-730 * 86_400)
        for i in 0..<1_500 {
            let start = start0.addingTimeInterval(Double(i) * 42_000)
            let id = CallRecorder.callID(for: start)
            var r = CallRecord(id: id, platform: .meet, bundleID: "b", start: start, end: start.addingTimeInterval(1800), status: .written)
            r.calendarTitle = "Series \(i % 60)"
            r.calendarSeriesID = "s\(i % 60)"
            r.speakerNames = ["me:A": "Avery Webb", "them:A": "Person \(i % 60)", "them:B": "Other \(i % 7)", "them:C": "Third \(i % 11)"]
            r.utterances = (0..<20).map { k in Utterance(track: k % 4 == 0 ? .me : .them, speakerLabel: k % 4 == 0 ? "A" : ["A", "B", "C"][k % 3],
                                                       start: Double(k) * 60, end: Double(k) * 60 + 50, text: "Words of line \(k)?") }
            r.summary = "S"
            r.actionItems = [ActionItem(owner: "Person \(i % 60)", task: "Task \(i)")]
            r.decisions = [Decision(text: "Decision \(i)")]
            r.markers = i % 10 == 0 ? [TranscriptMarker(offset: 60, text: "★", isBookmark: true, note: "Note \(i)")] : []
            many.append(r)
        }
        let big = ChatTools(records: many, owner: "Avery Webb", paths: paths, people: people, settings: ToolSettings(), now: now)
        let out = make(big)
        let sizes = Dictionary(out.map { ($0.key, $0.data.count) }, uniquingKeysWith: { a, _ in a })
        let months = sizes.filter { $0.key.hasPrefix("digest:meetings-") }
        print("DIGEST SIZES series \(sizes["digest:series"] ?? 0) bookmarks \(sizes["digest:bookmarks"] ?? 0) analytics \(sizes["digest:analytics"] ?? 0) coach \(sizes["digest:coach"] ?? 0) months \(months.count) largest month \(months.values.max() ?? 0) all months \(months.values.reduce(0, +))")
        XCTAssertLessThan(sizes["digest:series"] ?? .max, ServerDigest.maxPartBytes)
        XCTAssertLessThan(months.values.max() ?? .max, ServerDigest.maxPartBytes)
        XCTAssertLessThan(sizes["digest:bookmarks"] ?? .max, ServerDigest.maxPartBytes)
    }
}

/// A count that a `@Sendable` closure can move.
final class StopCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}
