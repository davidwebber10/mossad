import XCTest
@testable import MossadCore

/// Review N2: a step of a move that fails each time waits longer after each try, logs only a change, and keeps where
/// and why it waits for the views; "Try again" runs it at once.
final class MoveRetryTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveRetryTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    /// The back-off table: after 1, 2, 3, and 4 or more failed tries.
    func testTheBackOff() {
        let table: [(tries: Int, after: TimeInterval, due: Bool)] = [
            (0, 0, true),
            (1, 0, true),
            (2, 59, false), (2, 60, true),
            (3, 299, false), (3, 300, true),
            (4, 1799, false), (4, 1800, true),
            (40, 1799, false), (40, 1800, true),
        ]
        for row in table {
            let last: Date? = row.tries == 0 ? nil : t0
            XCTAssertEqual(MoveRetry.due(tries: row.tries, last: last, now: t0 + row.after), row.due, "\(row)")
        }
        XCTAssertTrue(MoveRetry.due(tries: 3, last: nil, now: t0), "Try again clears the time of the last try")
    }

    final class Clock: @unchecked Sendable {
        var now: Date
        init(_ d: Date) { now = d }
    }

    final class Flag: @unchecked Sendable {
        var works = false
        var calls = 0
    }

    /// A removal step that fails waits by the table, keeps its step and kind in the ledger, and goes on once it works.
    func testARemovalThatFailsWaitsAndSaysWhere() async throws {
        let a = temp(), b = temp()
        try writtenCall(in: a)
        try b.ensureDirectories()
        let clock = Clock(t0)
        let flag = Flag()
        let lib = VoiceLibrary(directory: a.voices)
        lib.identity = VoiceIdentity(people: PeopleStore(directory: a.people), samples: VoiceSampleStore(directory: b.voices))
        let pipeline = Pipeline(paths: a, transcriber: FakeTranscriber(), library: lib, embeddings: ToneEmbeddingProvider(), calendar: FakeCalendar(),
                                summarizer: FakeSummarizer(), notify: { _ in }, now: { [t0] in t0 }, ownerName: "Avery Webb")
        let actions = MoveRemoval.Actions(forgetPersona: { _ in }, coach: { _ in }, stopShares: { _ in },
                                          backup: { _ in flag.calls += 1; return flag.works },
                                          removeFolder: { i, to in await pipeline.removeMoved(callID: i, target: to) })
        let s = MoveSource(MoveSource.Setup(paths: a, profileID: "default", pipeline: pipeline, library: lib, ownerName: { "Avery Webb" },
                                            target: { _ in .paths(b) }, fetch: { _, _ in nil }, usage: { _ in [] }, actions: actions,
                                            now: { clock.now }))
        _ = await s.start(id, to: work)
        _ = await s.run(id)
        while !(MoveIntake(paths: b, me: work, library: VoiceLibrary(directory: b.voices), ownerName: { "Avery Webb" },
                           voiceFingerprints: { false }).run().contains(id)) {}
        _ = await s.run(id)
        var out = try XCTUnwrap(MoveOut.load(id, paths: a))
        XCTAssertEqual(out.state, .removing)
        XCTAssertEqual(out.nextStep, .backup)
        XCTAssertEqual(out.tries, 1)
        XCTAssertEqual(out.waitsAt, MoveOut.Step.backup.rawValue)
        XCTAssertEqual(out.because, .backupNotDone)
        XCTAssertEqual(out.waitsSince, t0)
        // The next look tries again; after two tries the step waits a minute.
        clock.now = t0 + 15
        _ = await s.run(id)
        XCTAssertEqual(flag.calls, 2)
        clock.now = t0 + 30
        _ = await s.run(id)
        XCTAssertEqual(flag.calls, 2, "within the wait no look runs the step")
        out = try XCTUnwrap(MoveOut.load(id, paths: a))
        XCTAssertEqual(out.tries, 2)
        XCTAssertEqual(out.waitsSince, t0, "since the first failed try")
        // "Try again" runs it at once.
        flag.works = true
        let again = await s.tryAgain(id)
        XCTAssertEqual(again, .moved(to: work))
        XCTAssertNil(MoveOut.load(id, paths: a)?.tries)
    }

    func testTheWordsOfARemovalThatWaits() {
        XCTAssertEqual(MoveWords.removalWaits(to: "Work", because: .peopleNotReady),
                       "Moved to Work. Mossad still removes it here, and waits for the people list of this profile.")
        XCTAssertEqual(MoveWords.removalWaits(to: "Work", because: .backupNotDone),
                       "Moved to Work. Mossad still removes it here, and waits to delete its backup copy.")
        for kind in MoveOut.Wait.allCases {
            let text = MoveWords.removalWaits(to: "Work", because: kind)
            XCTAssertTrue(text.hasPrefix("Moved to Work. Mossad still removes it here"), text)
        }
    }
}
