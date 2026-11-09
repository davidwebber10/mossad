import XCTest
@testable import MossadCore

final class SerialQueueTests: XCTestCase {
    private actor Trace {
        var events: [String] = []
        func add(_ e: String) { events.append(e) }
    }

    func testWorkRunsOnePieceAtATimeInOrder() async throws {
        let queue = SerialQueue(), trace = Trace()
        async let slow: Void = queue.run {
            await trace.add("pull start")
            try await Task.sleep(nanoseconds: 100_000_000)
            await trace.add("pull end")
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        async let edit: Void = queue.run { await trace.add("edit") }
        _ = try await (slow, edit)
        let events = await trace.events
        XCTAssertEqual(events, ["pull start", "pull end", "edit"], "An edit never lands in the middle of a pull")
    }

    func testAFailureDoesNotStopTheNextPiece() async throws {
        struct Boom: Error {}
        let queue = SerialQueue()
        do { _ = try await queue.run { throw Boom() } as Void; XCTFail() } catch {}
        let value = try await queue.run { 42 }
        XCTAssertEqual(value, 42)
    }

    func testCancellingTheCallerCancelsItsWork() async throws {
        let queue = SerialQueue()
        let task = Task { try await queue.run { try await Task.sleep(nanoseconds: 5_000_000_000) } }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { try await task.value; XCTFail("The work should stop") } catch is CancellationError {}
    }
}
