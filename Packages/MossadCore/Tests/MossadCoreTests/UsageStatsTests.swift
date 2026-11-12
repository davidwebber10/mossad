import XCTest
@testable import MossadCore

final class UsageStatsTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    private let now = ISO8601DateFormatter().date(from: "2026-11-12T15:00:00Z")!
    private let id = UUID(uuidString: "6F1C2A4E-8B3D-4C5A-9E7F-0A1B2C3D4E5F")!

    private func record(_ id: String, daysAgo: Double, minutes: Double, platform: Platform = .zoom, status: CallStatus = .written,
                        notesOnly: Bool = false) -> CallRecord {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        var r = CallRecord(id: id, platform: platform, bundleID: "us.zoom.xos", start: start, end: start.addingTimeInterval(minutes * 60), status: status)
        r.calendarTitle = "Budget review with Sam Carter"
        r.attendees = ["sam.carter@example.com"]
        if notesOnly { r.source = CallRecord.geminiNotesSource }
        return r
    }

    private func input(records: [CallRecord] = [], counters: UsageCounters = UsageCounters()) -> UsageStats.Input {
        UsageStats.Input(installID: id, appVersion: "2.20.0", build: "607", os: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 2),
                         cpuBrand: "Apple M3 Pro", language: "en", region: "US", records: records, counters: counters,
                         transcription: .assemblyai, summary: .anthropic,
                         features: .init(coach: true, screens: false, google: true, server: false, iphone: false, backup: true, mcp: false, shares: false),
                         people: 12, recurring: 0, commitmentsOpen: 3)
    }

    private func json(_ stats: UsageStats) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: stats.json()) as? [String: Any])
    }

    func testThePayloadHasTheShapeOfVersionOne() throws {
        let stats = UsageStats.make(input(records: [record("a", daysAgo: 1, minutes: 30)]), now: now, calendar: calendar)
        let j = try json(stats)
        XCTAssertEqual(Set(j.keys), ["v", "installID", "appVersion", "build", "os", "chip", "locale", "daysActive7", "meetings7",
                                     "meetingMinutes7", "platforms7", "providers", "features", "counts", "errors7"])
        XCTAssertEqual(j["v"] as? Int, 1)
        XCTAssertEqual(j["installID"] as? String, "6f1c2a4e-8b3d-4c5a-9e7f-0a1b2c3d4e5f")
        XCTAssertEqual(j["appVersion"] as? String, "2.20.0")
        XCTAssertEqual(j["build"] as? Int, 607)
        XCTAssertEqual(j["os"] as? String, "26.1")
        XCTAssertEqual(j["chip"] as? String, "M3")
        XCTAssertEqual(j["locale"] as? String, "en-US")
        XCTAssertEqual(Set((j["platforms7"] as? [String: Int])?.keys ?? [:].keys), ["zoom", "meet", "teams", "inPerson", "geminiNotes"])
        XCTAssertEqual(j["providers"] as? [String: String], ["transcription": "assemblyai", "summary": "anthropic"])
        XCTAssertEqual(j["features"] as? [String: Bool], ["coach": true, "screens": false, "google": true, "server": false,
                                                          "iphone": false, "backup": true, "mcp": false, "shares": false])
        XCTAssertEqual(j["counts"] as? [String: String], ["people": "6-20", "recurring": "0", "commitmentsOpen": "1-5"])
        XCTAssertEqual(j["errors7"] as? [String: Int], ["transcribe": 0, "identify": 0, "summarize": 0, "write": 0, "detect": 0])
    }

    func testMeetingsOfTheLastSevenDaysAreCountedByPlatform() {
        let records = [
            record("a", daysAgo: 0.5, minutes: 30),
            record("b", daysAgo: 2, minutes: 45, platform: .meet),
            record("c", daysAgo: 6.9, minutes: 60, platform: .teams),
            record("d", daysAgo: 3, minutes: 20, platform: .inPerson),
            record("e", daysAgo: 1, minutes: 50, platform: .meet, notesOnly: true),
            record("old", daysAgo: 7.5, minutes: 90),
            record("live", daysAgo: 0.01, minutes: 5, status: .recording),
        ]
        let s = UsageStats.make(input(records: records), now: now, calendar: calendar)
        XCTAssertEqual(s.meetings7, 5)
        // Minutes are what Mossad recorded: a notes-only meeting has none.
        XCTAssertEqual(s.meetingMinutes7, 30 + 45 + 60 + 20)
        XCTAssertEqual(s.platforms7, .init(zoom: 1, meet: 1, teams: 1, inPerson: 1, geminiNotes: 1))
    }

    func testNumbersAreClamped() {
        let many = (0..<600).map { record("r\($0)", daysAgo: 1, minutes: 60) }
        let s = UsageStats.make(input(records: many), now: now, calendar: calendar)
        XCTAssertEqual(s.meetings7, 500)
        XCTAssertEqual(s.meetingMinutes7, 20_000)
        XCTAssertEqual(s.platforms7.zoom, 500)
    }

    func testBuckets() {
        XCTAssertEqual(UsageStats.bucket(-3), "0")
        XCTAssertEqual(UsageStats.bucket(0), "0")
        XCTAssertEqual(UsageStats.bucket(1), "1-5")
        XCTAssertEqual(UsageStats.bucket(5), "1-5")
        XCTAssertEqual(UsageStats.bucket(6), "6-20")
        XCTAssertEqual(UsageStats.bucket(20), "6-20")
        XCTAssertEqual(UsageStats.bucket(21), "21-100")
        XCTAssertEqual(UsageStats.bucket(100), "21-100")
        XCTAssertEqual(UsageStats.bucket(101), "100+")
    }

    func testChipIsTheFamilyOnly() {
        XCTAssertEqual(UsageStats.chipFamily("Apple M1"), "M1")
        XCTAssertEqual(UsageStats.chipFamily("Apple M2 Max"), "M2")
        XCTAssertEqual(UsageStats.chipFamily("Apple M4 Pro"), "M4")
        XCTAssertEqual(UsageStats.chipFamily("Apple M5"), "M5")
        XCTAssertEqual(UsageStats.chipFamily("Apple M9 Ultra"), "Other")
        XCTAssertEqual(UsageStats.chipFamily("Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz"), "Other")
        XCTAssertEqual(UsageStats.chipFamily(nil), "Other")
    }

    /// The receiver's rules (`website/worker/src/telemetry.ts`), copied here so the two sides cannot move apart unseen.
    private enum Worker {
        static let appVersion = try! NSRegularExpression(pattern: "^\\d{1,3}\\.\\d{1,3}(\\.\\d{1,3})?$")
        static let os = try! NSRegularExpression(pattern: "^(2[6-9]|[3-9]\\d)(\\.\\d{1,2}){0,2}$")
        static let chip = try! NSRegularExpression(pattern: "^(M\\d{1,2}( Pro| Max| Ultra)?|Other)$")
        static let locale = try! NSRegularExpression(pattern: "^[a-z]{2,3}(-[A-Z][a-z]{3})?(-([A-Z]{2}|\\d{3}))?$")
        static func fits(_ r: NSRegularExpression, _ s: String) -> Bool { r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
    }

    func testEveryChipWordFitsTheReceiversRule() {
        for brand in ["Apple M1", "Apple M2 Max", "Apple M3 Pro", "Apple M4", "Apple M5 Ultra", "Apple M6", "Intel(R) Core(TM) i7", "", nil] {
            let chip = UsageStats.chipFamily(brand)
            XCTAssertTrue(Worker.fits(Worker.chip, chip), "\(chip) from \(brand ?? "nil")")
        }
    }

    func testANormalReportFitsTheReceiversRules() {
        let s = UsageStats.make(input(), now: now, calendar: calendar)
        XCTAssertTrue(s.isSendable)
        XCTAssertTrue(Worker.fits(Worker.appVersion, s.appVersion))
        XCTAssertTrue(Worker.fits(Worker.os, s.os))
        XCTAssertTrue(Worker.fits(Worker.chip, s.chip))
        XCTAssertTrue(Worker.fits(Worker.locale, s.locale))
        XCTAssertGreaterThanOrEqual(s.build, 1)
    }

    /// A version or a build that the receiver would refuse is not sent at all, so no report fails each day.
    func testAReportTheReceiverWouldRefuseIsNotSendable() {
        for (version, build) in [("abc", "607"), ("2.20.0.1", "607"), ("2.20.0", "x"), ("2.20.0", "0"), ("1234.0", "607")] {
            var i = input()
            i.appVersion = version
            i.build = build
            XCTAssertFalse(UsageStats.make(i, now: now, calendar: calendar).isSendable, "\(version) \(build)")
        }
    }

    func testProvidersSayNoneWhenNothingIsSet() {
        var i = input()
        i.transcription = nil
        i.summary = nil
        let s = UsageStats.make(i, now: now, calendar: calendar)
        XCTAssertEqual(s.providers, .init(transcription: "none", summary: "none"))
        i.transcription = .local
        i.summary = .localServer
        XCTAssertEqual(UsageStats.make(i, now: now, calendar: calendar).providers, .init(transcription: "local", summary: "localServer"))
    }

    func testCountersGiveDaysActiveAndErrors() {
        var c = UsageCounters()
        for days in [0.0, 0.1, 1, 3, 6, 8, 20] { c.markActive(at: now.addingTimeInterval(-days * 86_400), calendar: calendar) }
        c.record(.transcribe, at: now, calendar: calendar)
        c.record(.transcribe, at: now.addingTimeInterval(-86_400), calendar: calendar)
        c.record(.detect, at: now.addingTimeInterval(-2 * 86_400), calendar: calendar)
        c.record(.summarize, at: now.addingTimeInterval(-9 * 86_400), calendar: calendar)
        let s = UsageStats.make(input(counters: c), now: now, calendar: calendar)
        XCTAssertEqual(s.daysActive7, 4)
        XCTAssertEqual(s.errors7, .init(transcribe: 2, identify: 0, summarize: 0, write: 0, detect: 1))
    }

    func testCountersForgetOldDays() {
        var c = UsageCounters()
        c.markActive(at: now.addingTimeInterval(-30 * 86_400), calendar: calendar)
        c.record(.write, at: now.addingTimeInterval(-30 * 86_400), calendar: calendar)
        c.markActive(at: now, calendar: calendar)
        XCTAssertEqual(c.activeDays.count, 1)
        XCTAssertEqual(c.errors.count, 0)
    }

    func testAFailedStepNamesItsKind() {
        XCTAssertEqual(UsageStats.Step(failedAt: .recorded), .transcribe)
        XCTAssertEqual(UsageStats.Step(failedAt: .transcribed), .identify)
        XCTAssertEqual(UsageStats.Step(failedAt: .identified), .summarize)
        XCTAssertEqual(UsageStats.Step(failedAt: .summarized), .write)
        XCTAssertNil(UsageStats.Step(failedAt: .written))
    }

    /// Each string the payload carries is one of a fixed set, the UUID, a version, the locale, or the chip family,
    /// whatever the records and the system say. No title, name, address, path, or call id gets through.
    func testNoStringCanCarryPersonalData() throws {
        var i = input(records: [record("2026-11-12-0900-zoom", daysAgo: 1, minutes: 30)])
        i.appVersion = "2.20.0 (Sam's build /Users/sam)"
        i.build = "607 sam@example.com"
        i.cpuBrand = "Sam Carter's Mac"
        i.language = "Sam Carter"
        i.region = "/Users/sam"
        let data = try UsageStats.make(i, now: now, calendar: calendar).json()
        let text = String(decoding: data, as: UTF8.self)
        for bad in ["Sam", "sam", "@", "/Users", "Budget", "2026-11-12-0900", "us.zoom"] { XCTAssertFalse(text.contains(bad), bad) }

        let allowed: [NSRegularExpression] = [
            "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
            "^[0-9]{1,3}(\\.[0-9]{1,3}){0,2}$",
            "^[a-z]{2,3}(-[A-Z]{2})?$|^und$",
            "^(M[1-5]|Other)$",
            "^(assemblyai|deepgram|elevenlabs|openai|local|none|anthropic|openrouter|localServer|apple)$",
            "^(0|1-5|6-20|21-100|100\\+)$",
        ].map { try! NSRegularExpression(pattern: $0) }
        var strings: [String] = []
        func walk(_ value: Any) {
            if let s = value as? String { strings.append(s) }
            if let d = value as? [String: Any] { d.values.forEach(walk) }
            if let a = value as? [Any] { a.forEach(walk) }
        }
        walk(try JSONSerialization.jsonObject(with: data))
        XCTAssertFalse(strings.isEmpty)
        for s in strings {
            XCTAssertTrue(allowed.contains { $0.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }, "Not allowed: \(s)")
        }
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(j["appVersion"] as? String, "0")
        XCTAssertEqual(j["build"] as? Int, 0)
        XCTAssertEqual(j["locale"] as? String, "und")
    }

    func testTheInstallIDIsARandomVersionFourUUID() {
        let defaults = UserDefaults(suiteName: "usage-stats-test-\(UUID().uuidString)")!
        let first = UsageReportPlan.installID(defaults)
        XCTAssertEqual(first.uuidString.lowercased().dropFirst(14).first, "4")
        XCTAssertEqual(UsageReportPlan.installID(defaults), first)
        let reset = UsageReportPlan.resetInstallID(defaults)
        XCTAssertNotEqual(reset, first)
        XCTAssertEqual(UsageReportPlan.installID(defaults), reset)
    }
}

final class UsageReportPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAtMostOnceADay() {
        XCTAssertTrue(UsageReportPlan.isDue(lastAttempt: nil, now: now))
        XCTAssertFalse(UsageReportPlan.isDue(lastAttempt: now.addingTimeInterval(-3_600), now: now))
        XCTAssertFalse(UsageReportPlan.isDue(lastAttempt: now.addingTimeInterval(-86_399), now: now))
        XCTAssertTrue(UsageReportPlan.isDue(lastAttempt: now.addingTimeInterval(-86_400), now: now))
        // A clock that went back does not stop the reports for good.
        XCTAssertTrue(UsageReportPlan.isDue(lastAttempt: now.addingTimeInterval(2 * 86_400), now: now))
    }

    func testTheFirstReportWaitsOneToThirtyMinutes() {
        XCTAssertEqual(UsageReportPlan.launchDelay(0), 60)
        XCTAssertEqual(UsageReportPlan.launchDelay(1), 1_800)
        XCTAssertEqual(UsageReportPlan.launchDelay(-4), 60)
        XCTAssertEqual(UsageReportPlan.launchDelay(0.5), 930)
    }

    func testWhoMaySend() {
        let ok = UsageReportPlan.Gate(enabled: true, inert: false, rehearsal: false, rootOverride: false, debugBuild: false, debugFlag: false)
        XCTAssertTrue(ok.allows)
        var g = ok; g.enabled = false; XCTAssertFalse(g.allows)
        g = ok; g.inert = true; XCTAssertFalse(g.allows)
        g = ok; g.rehearsal = true; XCTAssertFalse(g.allows)
        g = ok; g.rootOverride = true; XCTAssertFalse(g.allows)
        g = ok; g.debugBuild = true; XCTAssertFalse(g.allows)
        g.debugFlag = true; XCTAssertTrue(g.allows)
    }

    func testTheEndpointAndItsHiddenOverride() {
        XCTAssertEqual(UsageReportPlan.endpoint(override: nil).absoluteString, "https://getmossad.com/api/telemetry")
        XCTAssertEqual(UsageReportPlan.endpoint(override: "").absoluteString, "https://getmossad.com/api/telemetry")
        XCTAssertEqual(UsageReportPlan.endpoint(override: "not a url").absoluteString, "https://getmossad.com/api/telemetry")
        XCTAssertEqual(UsageReportPlan.endpoint(override: "http://127.0.0.1:8787/api/telemetry").absoluteString, "http://127.0.0.1:8787/api/telemetry")
    }

    func testTheRequestCarriesOnlyTheBodyAndTwoHeaders() {
        let body = Data("{\"v\":1}".utf8)
        let r = UsageReportPlan.request(body: body, endpoint: UsageReportPlan.endpoint(override: nil), appVersion: "2.20.0")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.timeoutInterval, 10)
        XCTAssertEqual(r.httpBody, body)
        XCTAssertEqual(r.allHTTPHeaderFields, ["Content-Type": "application/json", "User-Agent": "Mossad/2.20.0"])
        XCTAssertFalse(r.httpShouldHandleCookies)
        XCTAssertEqual(r.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    /// URLSession adds its own Accept and Accept-Language headers; fixed values keep the owner's language list out.
    func testTheSessionSendsFixedLanguageAndAcceptHeaders() {
        let config = UsageReportPlan.sessionConfiguration()
        XCTAssertEqual(config.httpAdditionalHeaders as? [String: String], ["Accept-Language": "en", "Accept": "*/*"])
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertNil(config.urlCache)
        XCTAssertEqual(config.timeoutIntervalForRequest, 10)
    }

    func testTheUserAgentNeverCarriesMoreThanAVersion() {
        let r = UsageReportPlan.request(body: Data(), endpoint: UsageReportPlan.endpoint(override: nil), appVersion: "2.20 Sam")
        XCTAssertEqual(r.value(forHTTPHeaderField: "User-Agent"), "Mossad/0")
    }
}

final class UsageCounterStoreTests: XCTestCase {
    func testTheStoreKeepsTheCountsAndDeletesThem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-counters-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UsageCounterStore(directory: dir)
        let now = Date()
        store.markActive(at: now)
        store.record(.identify, at: now)
        store.record(.identify, at: now)
        let again = UsageCounterStore(directory: dir).read()
        XCTAssertEqual(again.activeDays.count, 1)
        XCTAssertEqual(again.errors.values.first?["identify"], 2)
        store.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(UsageCounterStore.fileName).path))
        XCTAssertEqual(store.read(), UsageCounters())
    }

    /// A count that was on its way when the owner turned the statistics off does not make the file again.
    func testAfterDeleteNothingIsCountedUntilReopened() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-counters-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UsageCounterStore(directory: dir)
        store.delete()
        store.record(.write)
        store.markActive()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(UsageCounterStore.fileName).path))
        store.reopen()
        store.record(.write)
        XCTAssertEqual(store.read().errors.values.first?["write"], 1)
    }
}
