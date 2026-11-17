import XCTest
@testable import MossadCore

/// Review I2 and I1: a meeting that the target took in leaves the first profile's store at the next push, while its
/// removal still runs; and the chats of a call marked for another profile never go to the first profile's store.
final class MoveSyncHoldTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveSyncHoldTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func ledger(_ a: Paths, _ state: MoveOut.State) throws {
        var out = MoveOut(callID: id, to: work, started: t0)
        out.state = state
        try out.save(a)
    }

    private func sync(_ a: Paths, _ store: MemoryStore) -> CloudSync {
        CloudSync(paths: a, store: store, leaving: { MoveOut.syncHeld(a) })
    }

    private func meetings(_ store: MemoryStore) async -> Set<String> {
        Set(await store.entries.values.filter { $0.record.type == "Meeting" && !$0.deleted }.map(\.record.name))
    }

    func testARemovingLedgerTakesTheMeetingOffTheStore() async throws {
        let a = temp(), store = MemoryStore()
        try writtenCall(in: a)
        _ = try await sync(a, store).push()
        let before = await meetings(store)
        XCTAssertEqual(before, [id])
        try ledger(a, .removing)
        _ = try await sync(a, store).push()
        let after = await meetings(store)
        XCTAssertEqual(after, [])
        // Later states before the folder is gone hold it off too.
        XCTAssertEqual(MoveOut.syncHeld(a), [id])
        try ledger(a, .done)
        XCTAssertEqual(MoveOut.syncHeld(a), [id])
    }

    func testAMeetingThatIsStillTheFirstProfilesStays() async throws {
        for state in [MoveOut.State.copying, .copied, .waiting, .cancelling] {
            let a = temp(), store = MemoryStore()
            try writtenCall(in: a)
            try ledger(a, state)
            XCTAssertEqual(MoveOut.syncHeld(a), [], "\(state)")
            _ = try await sync(a, store).push()
            let held = await meetings(store)
            XCTAssertEqual(held, [id], "\(state)")
        }
    }

    /// With no ledger the push is the push of before, byte for byte.
    func testWithNoLedgerNothingChanges() async throws {
        let a = temp()
        try writtenCall(in: a)
        let plain = MemoryStore(view: true), seamed = MemoryStore(view: true)
        _ = try await CloudSync(paths: a, store: plain).push()
        try FileManager.default.removeItem(at: a.sync)
        _ = try await sync(a, seamed).push()
        let p = await plain.entries.mapValues(\.data), s = await seamed.entries.mapValues(\.data)
        XCTAssertEqual(p, s)
        XCTAssertFalse(p.isEmpty)
        let ps = MemoryStore(), ss = MemoryStore()
        try FileManager.default.removeItem(at: a.sync)
        _ = try await CloudSync(paths: a, store: ps).pushShared()
        try FileManager.default.removeItem(at: a.sync)
        _ = try await sync(a, ss).pushShared()
        let pd = await ps.entries.mapValues(\.data), sd = await ss.entries.mapValues(\.data)
        XCTAssertEqual(pd, sd)
        XCTAssertFalse(pd.isEmpty)
        XCTAssertEqual(MoveOut.syncHeld(a), [])
    }

    private func chats(_ store: MemoryStore) async -> Int {
        await store.entries.values.filter { $0.record.type == "Chat" && !$0.deleted }.count
    }

    func testTheChatsOfAMarkedCallDoNotSync() async throws {
        let a = temp(), store = MemoryStore()
        var r = try writtenCall(in: a)
        r.moveTo = work
        r.status = .recorded
        try r.save(to: a.callDirectory(id))
        _ = try await sync(a, store).pushShared()
        let sent = await chats(store)
        XCTAssertEqual(sent, 0)
    }

    func testTheChatsOfACallThatLeavesDoNotSync() async throws {
        let a = temp(), store = MemoryStore()
        try writtenCall(in: a)
        try ledger(a, .removing)
        _ = try await sync(a, store).pushShared()
        let sent = await chats(store)
        XCTAssertEqual(sent, 0)
        // A chat of a meeting that stays goes as before.
        let b = temp(), other = MemoryStore()
        try writtenCall(in: b)
        _ = try await sync(b, other).pushShared()
        let kept = await chats(other)
        XCTAssertEqual(kept, 1)
    }
}
