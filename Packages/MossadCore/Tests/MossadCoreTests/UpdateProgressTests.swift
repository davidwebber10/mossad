import XCTest
@testable import MossadCore

final class UpdateProgressTests: XCTestCase {
    func testTheClickOpensAndTheChoiceInstalls() {
        var p = UpdateProgress()
        XCTAssertTrue(p.canStart)
        p.clicked()
        XCTAssertEqual(p.phase, .opening)
        XCTAssertFalse(p.canStart)
        p.found()
        XCTAssertEqual(p.phase, .idle)
        p.chose(install: true)
        XCTAssertEqual(p.phase, .installing)
    }

    func testEveryWayOutReturnsToIdle() {
        let endings: [(inout UpdateProgress) -> Void] = [
            { $0.aborted() }, { $0.notFound() }, { $0.downloadEnded() }, { $0.cycleFinished() }, { $0.chose(install: false) },
        ]
        for end in endings {
            var p = UpdateProgress()
            p.clicked()
            p.chose(install: true)
            end(&p)
            XCTAssertEqual(p.phase, .idle)
            XCTAssertTrue(p.canStart)
        }
    }

    func testANewCheckStartsClean() {
        var p = UpdateProgress()
        p.chose(install: true)
        p.found()
        XCTAssertEqual(p.phase, .idle)
    }

    func testAClickWhileBusyDoesNothing() {
        var p = UpdateProgress()
        p.chose(install: true)
        p.clicked()
        XCTAssertEqual(p.phase, .installing)
    }
}
