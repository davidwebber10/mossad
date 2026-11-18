import XCTest
@testable import MossadCore

final class CutCommandTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_520_000)
    private let utc = TimeZone(identifier: "UTC")!

    func testTheArguments() {
        XCTAssertEqual(CutCommand.parse(["Mossad", "--cut", "20261117-143000", "--at", "5292"]),
                       .success(.init(callID: "20261117-143000", times: [5292], dryRun: false)))
        XCTAssertEqual(CutCommand.parse(["Mossad", "--cut", "20261117-143000", "--at", "5292.5,6000", "--dry-run"]),
                       .success(.init(callID: "20261117-143000", times: [5292.5, 6000], dryRun: true)))
        XCTAssertEqual(CutCommand.parse(["Mossad", "--profile", "1a2b3c4d", "--cut", "20261117-143000", "--at", "5292"]),
                       .success(.init(callID: "20261117-143000", times: [5292], dryRun: false)))
        for bad in [["Mossad", "--cut"], ["Mossad", "--cut", "20261117-143000"], ["Mossad", "--cut", "20261117-143000", "--at"],
                    ["Mossad", "--cut", "20261117-143000", "--at", "abc"], ["Mossad", "--cut", "20261117-143000", "--at", "-5"],
                    ["Mossad", "--cut", "20261117-143000", "--at", "5292,"], ["Mossad", "--cut", "../x", "--at", "5292"],
                    ["Mossad", "--cut", "--at", "5292"], ["Mossad", "--cut", "20261117-143000", "--at", "5292", "--force"],
                    ["Mossad", "--cut", "20261117-143000", "--at", "5292", "--at", "6000"]] {
            guard case .failure = CutCommand.parse(bad) else { return XCTFail("refused: \(bad)") }
        }
    }

    func testTheUsageLine() {
        XCTAssertEqual(CutCommand.usage, "Usage: Mossad --cut <call id> --at <seconds>[,<seconds>…] [--dry-run] [--profile <id>]")
        guard case let .failure(error) = CutCommand.parse(["Mossad", "--cut"]) else { return XCTFail() }
        let text = error.text
        XCTAssertTrue(text.contains(CutCommand.usage))
    }

    func testThePrintedPlan() {
        var r = CallRecord(id: "20261117-143000", platform: .meet, bundleID: "com.google.Chrome", start: t0, end: t0 + 8760, status: .written)
        r.pauses = [PauseSpan(at: 600, from: t0 + 600, to: t0 + 660)]
        r.parts = [CallPart(start: t0, end: t0 + 3000, offset: 0), CallPart(start: t0 + 3600, end: t0 + 8760, offset: 3000)]
        var a = CallRecord(id: "20261117-143000-2", platform: .meet, bundleID: "", start: t0, end: t0 + 5352, status: .recorded)
        a.cutFrom = r.id
        var b = CallRecord(id: "20261117-160218", platform: .meet, bundleID: "", start: t0 + 5352, end: t0 + 8760, status: .recorded)
        b.cutFrom = r.id
        let text = CutCommand.planText(record: r, length: 8700, parts: [a, b], cuts: [Cut(at: 5292, link: nil)], timeZone: utc)
        XCTAssertEqual(text, """
            Meeting 20261117-143000 (written): 145 min 0 s of audio.
            Pauses (1): 1. At 600 s (10:00), from 2026-11-01 08:10:00 to 2026-11-01 08:11:00.
            Merged parts (2): 1. From 0 s, 2026-11-01 08:00:00 to 2026-11-01 08:50:00. 2. From 3000 s, 2026-11-01 09:00:00 to 2026-11-01 10:26:00.
            Parts to make: 2.
              1. 20261117-143000-2: 0 s to 5292 s (88 min 12 s), 2026-11-01 08:00:00 to 2026-11-01 09:29:12.
              2. 20261117-160218: 5292 s to 8700 s (56 min 48 s), 2026-11-01 09:29:12 to 2026-11-01 10:26:00.
            Cut 1 at 5292 s of the audio, 2026-11-01 09:29:12 on the clock.
            """)
        let plain = CutCommand.planText(record: CallRecord(id: "x", platform: .meet, bundleID: "", start: t0, end: t0 + 100, status: .recorded),
                                        length: 100, parts: [], cuts: [], timeZone: utc)
        XCTAssertTrue(plain.contains("Pauses: not known (recorded by an older version)."), plain)
        var known = CallRecord(id: "x", platform: .meet, bundleID: "", start: t0, end: t0 + 100, status: .recorded)
        known.pauses = []
        XCTAssertTrue(CutCommand.planText(record: known, length: 100, parts: [], cuts: [], timeZone: utc).contains("Pauses: none."))
        XCTAssertTrue(plain.contains("Merged parts: none."))
    }

    /// The command on a made-up folder: a dry run changes nothing, and a run makes the parts.
    func testADryRunChangesNothingAndARunCuts() async throws {
        let paths = Paths(root: tempDirectory())
        addTeardownBlock { try? FileManager.default.removeItem(at: paths.root) }
        try paths.ensureDirectories()
        let id = CallRecorder.callID(for: t0)
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AudioCutTests.writeTrack(dir.appendingPathComponent("me.caf"), frames: 150 * 16_000)
        try AudioCutTests.writeTrack(dir.appendingPathComponent("them.caf"), frames: 150 * 16_000)
        try CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: t0, end: t0 + 150, status: .recorded).save(to: dir)

        let dry = await CutCommand.run(["Mossad", "--cut", id, "--at", "90", "--dry-run"], paths: paths, ownerName: "Avery Webb")
        XCTAssertEqual(dry.status, 0, dry.text)
        XCTAssertTrue(dry.text.contains("Parts to make: 2."), dry.text)
        XCTAssertTrue(dry.text.contains("Nothing was changed"), dry.text)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.audio.path), [id])

        let refused = await CutCommand.run(["Mossad", "--cut", id, "--at", "30"], paths: paths, ownerName: "Avery Webb")
        XCTAssertEqual(refused.status, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.audio.path), [id])

        let run = await CutCommand.run(["Mossad", "--cut", id, "--at", "90"], paths: paths, ownerName: "Avery Webb")
        XCTAssertEqual(run.status, 0, run.text)
        let second = CallRecorder.callID(for: t0 + 90)
        XCTAssertTrue(run.text.contains("\(id)-2, \(second)"), run.text)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.audio.path).sorted(), ["\(id)-2", second])
    }

    func testARunIsRefusedWhileMossadIsOpen() async throws {
        let paths = Paths(root: tempDirectory())
        addTeardownBlock { try? FileManager.default.removeItem(at: paths.root) }
        try paths.ensureDirectories()
        guard case let .held(lock) = InstanceLock.acquire(root: paths.root) else { return XCTFail("the test holds the lock") }
        defer { withExtendedLifetime(lock) {} }
        let result = await CutCommand.run(["Mossad", "--cut", "20261117-143000", "--at", "90"], paths: paths, ownerName: "Avery Webb")
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.text, "Mossad is open. Quit Mossad first: it holds these files.")
    }

    func testTheCommandIsACommand() {
        XCTAssertTrue(AppIdentity.commands.contains("--cut"))
    }
}
