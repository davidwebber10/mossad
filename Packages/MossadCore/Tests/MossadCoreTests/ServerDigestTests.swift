import XCTest
@testable import MossadCore

/// The digest: what the Mac computes for the server's MCP with the app's own rules, in parts that each change alone,
/// from allowed-field lists, with no calendar data, and nothing the coach learned about a person who keeps no read.
final class ServerDigestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // Jan 15, 2027
    private var paths: Paths!

    private var people: [Person] {
        var dana = Person(id: PersonID(rawValue: "id-dana"), displayName: "Dana Lee", origin: .migration, at: now)
        dana.doNotProfile = true
        return [Person(id: PersonID(rawValue: "id-owner"), displayName: "Avery Webb", isOwner: true, origin: .owner, at: now),
                Person(id: PersonID(rawValue: "id-sam"), displayName: "Sam Carter", origin: .migration, at: now), dana]
    }

    /// Two meetings of a weekly series a week apart, and one meeting of December.
    private func records() -> [CallRecord] {
        var out: [CallRecord] = []
        for (n, id) in [(1, "20270108-100000"), (2, "20270113-100000")] {
            let start = now.addingTimeInterval(-Double(3 - n) * 6 * 86_400)
            var r = CallRecord(id: id, platform: .meet, bundleID: "b", start: start, end: start.addingTimeInterval(1800), status: .written)
            r.calendarTitle = "Weekly sync"
            r.calendarSeriesID = "g-weekly"
            r.attendees = ["Sam Carter", "Dana Lee"]
            r.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter", "them:B": "Dana Lee"]
            r.speakerPeople = ["me:A": "id-owner", "them:A": "id-sam", "them:B": "id-dana"]
            r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 300, text: "Let us look at the roadmap."),
                            Utterance(track: .them, speakerLabel: "A", start: 300, end: 900, text: "The roadmap slips."),
                            Utterance(track: .them, speakerLabel: "B", start: 900, end: 1200, text: "Agreed.")]
            r.summary = "Roadmap."
            r.actionItems = [ActionItem(owner: "Sam Carter", task: "Draft the plan", ownerID: "id-sam")]
            r.decisions = [Decision(text: "Ship in March")]
            r.markers = [TranscriptMarker(offset: 310, text: "★", isBookmark: true, note: "Slip \(n)")]
            out.append(r)
        }
        var dec = CallRecord(id: "20261220-090000", platform: .zoom, bundleID: "b", start: now.addingTimeInterval(-26 * 86_400),
                             end: now.addingTimeInterval(-26 * 86_400 + 900), status: .written)
        dec.calendarTitle = "Year end"
        dec.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter"]
        dec.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 200, text: "Thanks all.")]
        out.append(dec)
        return out
    }

    override func setUpWithError() throws {
        paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        for r in records() {
            try FileManager.default.createDirectory(at: paths.callDirectory(r.id), withIntermediateDirectories: true)
            try r.save(to: paths.callDirectory(r.id))
        }
        // A card about Dana, who keeps no read, and one for the owner.
        var review = CoachReview(headline: "H", overview: "", strengths: [], improvements: [], focusProgress: nil)
        review.tryNext = CoachNote(text: "When you take an item, say the day.", quote: "Let us look at the roadmap.", at: 0,
                                   say: "I will send it by Friday.", skill: CoachSkill.commitmentDates.rawValue)
        try review.save(in: paths.callDirectory("20270113-100000"))
        var profile = CoachProfile()
        var q = CoachQuestion(statement: "Dana prefers email.", kind: .relationship, evidence: "Agreed.", callID: "20270113-100000", at: 900, asked: now)
        q.person = "id-dana"
        profile.questions = [q]
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

    private func tools(coach: Bool = true) -> ChatTools {
        var s = ToolSettings()
        s.coach = coach
        return ChatTools(records: records(), owner: "Avery Webb", paths: paths, people: people, settings: s, now: now)
    }

    private func parts(personas: Bool = true) -> [String: Data] {
        Dictionary(ServerDigest.parts(tools(), personasInMCP: personas).map { ($0.key, $0.data) }, uniquingKeysWith: { a, _ in a })
    }

    private func json(_ data: Data?) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any]) }

    func testTheDigestHasOnePartForEachKindAndOneForEachMonthOfMeetings() {
        XCTAssertEqual(Set(parts().keys), ["digest:series", "digest:bookmarks", "digest:analytics", "digest:coach", "digest:meetings-2027-01", "digest:meetings-2026-12"])
        XCTAssertEqual(ServerDigest.month(of: "20270113-100000"), "2027-01")
        XCTAssertEqual(ServerDigest.month(of: "20270113-100000-notes"), "2027-01")
        XCTAssertEqual(ServerDigest.month(of: "imported"), "other")
    }

    func testEveryPartHasOnlyItsAllowedKeysAVersionAndWhenItWasMade() throws {
        func check(_ value: Any, level: String, path: String) {
            if let object = value as? [String: Any] {
                let allowed = ServerDigest.allowedKeys[level] ?? []
                XCTAssertTrue(Set(object.keys).isSubset(of: allowed), "\(path): \(Set(object.keys).subtracting(allowed))")
                for (k, v) in object { check(v, level: ServerDigest.childLevel[level + "." + k] ?? level, path: path + "." + k) }
            } else if let list = value as? [Any] {
                for v in list { check(v, level: level, path: path) }
            }
        }
        for (key, data) in parts() {
            let root = try json(data)
            XCTAssertEqual(root["version"] as? Int, ServerDigest.version, key)
            XCTAssertNotNil(root["made"], key)
            check(root, level: ServerDigest.rootLevel(of: key), path: key)
        }
    }

    func testNoCalendarDataGoesAndAnEndedSeriesLeaves() throws {
        let all = parts().values.map { String(decoding: $0, as: UTF8.self) }.joined()
        for word in ["secret.guest", "meet.google.com", "\"next\"", "upcoming"] { XCTAssertFalse(all.contains(word), word) }
        let series = try XCTUnwrap(try json(parts()["digest:series"])["series"] as? [[String: Any]])
        XCTAssertEqual(series.map { $0["title"] as? String }, ["Weekly sync"])
        XCTAssertEqual((series.first?["rows"] as? [Any])?.count, 2)
    }

    func testNothingTheCoachLearnedAboutAPersonWhoKeepsNoReadGoesAndTraitsFollowTheSwitch() throws {
        let coach = String(decoding: try XCTUnwrap(parts()["digest:coach"]), as: UTF8.self)
        XCTAssertTrue(coach.contains("When you take an item, say the day."), coach)
        XCTAssertFalse(coach.contains("Dana prefers email"), "a card about a person who keeps no read")
        XCTAssertTrue(coach.contains("Name a date when you take an item"), "the goal")
        // Per-person numbers of a series are plain facts and stay.
        let series = String(decoding: try XCTUnwrap(parts()["digest:series"]), as: UTF8.self)
        XCTAssertTrue(series.contains("Dana Lee"))
    }

    func testBookmarksAndMeetingNumbersAreThere() throws {
        let marks = try XCTUnwrap(try json(parts()["digest:bookmarks"])["bookmarks"] as? [[String: Any]])
        XCTAssertEqual(Set(marks.compactMap { $0["note"] as? String }), ["Slip 1", "Slip 2"])
        let jan = try XCTUnwrap(try json(parts()["digest:meetings-2027-01"])["meetings"] as? [[String: Any]])
        XCTAssertEqual(Set(jan.compactMap { $0["callID"] as? String }), ["20270108-100000", "20270113-100000"])
        let speakers = try XCTUnwrap(jan.first?["speakers"] as? [[String: Any]])
        XCTAssertTrue(speakers.contains { $0["name"] as? String == "Sam Carter" })
        let periods = try XCTUnwrap(try json(parts()["digest:analytics"])["periods"] as? [[String: Any]])
        XCTAssertEqual(periods.compactMap { $0["days"] as? Int }, [7, 30, 90, 365])
    }

    func testAMonthWithNoMeetingLeftLeavesTheServerAndADeletedMeetingLeavesItsMonth() async throws {
        let store = MemoryStore(view: true)
        let sync = CloudSync(paths: paths, store: store)
        try await sync.pushShared(people: true, digest: ServerDigest.parts(tools(), personasInMCP: true))
        let before = await store.entries["digest-meetings-2026-12"]?.deleted
        XCTAssertEqual(before, false)
        // The December meeting is deleted: its month goes; a later sync with no digest (a call) deletes nothing.
        try FileManager.default.removeItem(at: paths.callDirectory("20261220-090000"))
        let rest = records().filter { $0.id != "20261220-090000" }
        let after = ChatTools(records: rest, owner: "Avery Webb", paths: paths, people: people, settings: { var s = ToolSettings(); s.coach = true; return s }(), now: now)
        try await sync.pushShared(people: true)
        let kept = await store.entries["digest-meetings-2026-12"]?.deleted
        XCTAssertEqual(kept, false, "no digest made, nothing deleted")
        try await sync.pushShared(people: true, digest: ServerDigest.parts(after, personasInMCP: true))
        let gone = await store.entries["digest-meetings-2026-12"]?.deleted
        XCTAssertEqual(gone, true)
    }

    func testTheDigestNeverGoesToICloud() async throws {
        let store = MemoryStore(view: false)
        try await CloudSync(paths: paths, store: store).pushShared(people: true, digest: ServerDigest.parts(tools(), personasInMCP: true))
        let names = await store.entries.keys.filter { $0.hasPrefix("digest") }
        XCTAssertTrue(names.isEmpty)
    }

    func testAMonthIsMadeAgainOnlyWhenItsMeetingsChanged() throws {
        let cache = DigestCache(directory: paths.sync)
        let first = ServerDigest.parts(tools(), personasInMCP: true, cache: cache)
        XCTAssertEqual(cache.made, 2, "two months made")
        let second = ServerDigest.parts(tools(), personasInMCP: true, cache: DigestCache(directory: paths.sync))
        XCTAssertEqual(first.map(\.hash).sorted(), second.map(\.hash).sorted())
        let reread = DigestCache(directory: paths.sync)
        _ = ServerDigest.parts(tools(), personasInMCP: true, cache: reread)
        XCTAssertEqual(reread.made, 0, "both months from the cache")
    }

    /// The fixtures the server's tests read, written by this encoder (`MOSSAD_WRITE_FIXTURES=1`).
    func testThePartsAreTheFilesTheServersTestsRead() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("server/test/fixtures")
        let write = ProcessInfo.processInfo.environment["MOSSAD_WRITE_FIXTURES"] == "1"
        for (key, data) in parts() {
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
        let out = ServerDigest.parts(big, personasInMCP: true)
        let sizes = Dictionary(out.map { ($0.key, $0.data.count) }, uniquingKeysWith: { a, _ in a })
        let months = sizes.filter { $0.key.hasPrefix("digest:meetings-") }
        print("DIGEST SIZES series \(sizes["digest:series"] ?? 0) bookmarks \(sizes["digest:bookmarks"] ?? 0) analytics \(sizes["digest:analytics"] ?? 0) coach \(sizes["digest:coach"] ?? 0) months \(months.count) largest month \(months.values.max() ?? 0) all months \(months.values.reduce(0, +))")
        XCTAssertLessThan(sizes["digest:series"] ?? .max, ServerDigest.maxPartBytes)
        XCTAssertLessThan(months.values.max() ?? .max, ServerDigest.maxPartBytes)
        XCTAssertLessThan(sizes["digest:bookmarks"] ?? .max, ServerDigest.maxPartBytes)
    }
}
