import XCTest
@testable import MossadCore

final class TransientRetryTests: XCTestCase {
    /// The phone showed "Sync failed" once on waking; a second try a moment later worked.
    func testADroppedConnectionIsTriedAgain() async throws {
        var tries = 0
        let value = try await TransientRetry.run(pause: .zero) {
            tries += 1
            if tries == 1 { throw URLError(.networkConnectionLost) }
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(tries, 2)
    }

    func testAServerErrorIsTriedAgain() async throws {
        var tries = 0
        _ = try await TransientRetry.run(pause: .zero) {
            tries += 1
            if tries == 1 { throw ServerError.http(503, "") }
            return 1
        }
        XCTAssertEqual(tries, 2)
    }

    func testAWrongSecretIsNotTriedAgain() async {
        var tries = 0
        do {
            _ = try await TransientRetry.run(pause: .zero) { () async throws -> Int in
                tries += 1
                throw ServerError.wrongSecret
            }
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(tries, 1)
        }
    }

    func testItGivesUpAfterTheLastTry() async {
        var tries = 0
        do {
            _ = try await TransientRetry.run(tries: 3, pause: .zero) { () async throws -> Int in
                tries += 1
                throw URLError(.timedOut)
            }
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(tries, 3)
        }
    }
}
