import XCTest
@testable import MossadCore

final class RunModeTests: XCTestCase {
    func testTheModeTableIsTheSpecsTable() {
        // duty: (full, worker, inert). A second copy is inert.
        let table: [Duty: (Bool, Bool, Bool)] = [
            .recover: (true, true, false), .people: (true, true, false), .queue: (true, true, false),
            .inviteMatch: (true, true, false), .sync: (true, true, false), .digest: (true, true, false),
            .serverConfig: (true, true, false), .backup: (true, true, false), .coach: (true, true, false),
            .commitments: (true, true, false), .nextTime: (true, true, false), .personas: (true, true, false),
            .takeInMoved: (true, true, false), .statusFile: (false, true, false),
            .detect: (true, false, false), .record: (true, false, false), .geminiNotes: (true, false, false),
            .calendarSnapshot: (true, false, false), .upcoming: (true, false, true), .hotKeys: (true, false, false),
            .loginItem: (true, false, false), .updater: (true, false, false), .notifications: (true, false, true),
            .weeklyMail: (true, false, false), .usageStats: (true, false, false), .retention: (true, false, false),
            .askPermission: (true, false, false),
            .window: (true, false, true), .sharedItems: (true, false, false), .upkeep: (true, false, false),
            .registry: (true, false, false), .startWorkers: (true, false, false),
        ]
        XCTAssertEqual(Set(table.keys), Set(Duty.allCases))
        let second = RunMode.decide(preview: false, rehearsal: false, secondCopy: true, madeUpRegistry: false)
        for (duty, row) in table {
            XCTAssertEqual(RunMode.full.does(duty), row.0, "full \(duty)")
            XCTAssertEqual(RunMode.worker.does(duty), row.1, "worker \(duty)")
            XCTAssertEqual(RunMode.inert.does(duty), row.2, "inert \(duty)")
            XCTAssertEqual(second.does(duty), row.2, "second copy \(duty)")
        }
    }

    func testAWorkerIsItsOwnMode() {
        for madeUp in [false, true] {
            XCTAssertEqual(RunMode.decide(preview: false, rehearsal: false, secondCopy: false, madeUpRegistry: madeUp, worker: true), .worker)
            XCTAssertEqual(RunMode.decide(preview: true, rehearsal: true, secondCopy: true, madeUpRegistry: madeUp, worker: true), .worker)
        }
        XCTAssertEqual(RunMode.decide(preview: false, rehearsal: false, secondCopy: false, madeUpRegistry: false), .full)
    }

    func testAWorkerOnAMadeUpRegistryStaysInItsFolder() {
        let stays: Set<Duty> = [.recover, .people, .queue, .takeInMoved, .statusFile]
        for duty in Duty.allCases { XCTAssertEqual(RunMode.worker.runs(duty, madeUpRegistry: true), stays.contains(duty), "\(duty)") }
        for duty in Duty.allCases { XCTAssertEqual(RunMode.worker.runs(duty, madeUpRegistry: false), RunMode.worker.does(duty)) }
        let leaves: Set<Duty> = [.inviteMatch, .sync, .digest, .serverConfig, .backup, .coach, .commitments, .nextTime, .personas]
        XCTAssertEqual(Set(Duty.allCases.filter(\.leavesTheFolder)), leaves)
    }
}
