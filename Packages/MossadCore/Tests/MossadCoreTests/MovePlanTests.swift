import XCTest
@testable import MossadCore

final class MovePlanTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let mine = "aaaa0001", theirs = "cccc0003"

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MovePlanTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func ledger(_ state: MoveOut.State, token: String? = nil) -> MoveOut {
        var out = MoveOut(callID: id, to: work, started: t0, token: token ?? mine)
        out.state = state
        return out
    }

    private func marker(token: String? = nil, intake: MoveMarker.Intake? = nil, finalID: String? = nil, refusal: MoveMarker.Refusal? = nil,
                        count: Int? = nil) -> MoveMarker {
        var m = MoveMarker(callID: id, from: "default", to: work, made: t0, token: token ?? mine,
                           files: [.init(path: "call/call.json", size: 120, sha256: String(repeating: "a", count: 64))], ownerKeys: ["me:A"])
        m.intake = intake
        m.finalID = finalID
        m.refusal = refusal
        m.count = count
        return m
    }

    private var held: MoveMarker { marker(intake: .taken, finalID: id, count: 1) }

    /// Every look of the marker that a side can see, mine and another move's.
    private var looks: [MoveMarker.Look] {
        var out: [MoveMarker.Look] = [.missing, .unknown, .cancelled(marker()), .cancelled(marker(token: theirs)), .cancelled(nil)]
        for t in [mine, theirs] {
            out += [.incoming(marker(token: t)), .claimed(marker(token: t)), .claimed(marker(token: t, intake: .takingIn, finalID: id)),
                    .claimed(marker(token: t, intake: .taken, finalID: id, count: 1)), .claimed(marker(token: t, intake: .taken, finalID: id)),
                    .claimed(marker(token: t, intake: .refused, refusal: .idTaken)), .claimed(marker(token: t, intake: .refused, refusal: .unreadable)),
                    .claimed(marker(token: t, intake: .refused, refusal: .notWhole))]
        }
        return out
    }

    private func isMine(_ look: MoveMarker.Look) -> Bool {
        switch look {
        case .incoming(let m), .claimed(let m): m.token == mine
        case .cancelled(let m): m?.token == mine
        default: false
        }
    }

    private func keys(of json: Any) -> Set<String> {
        // The keys of `chatIDs` are chat ids (data), checked apart.
        if let d = json as? [String: Any] {
            return Set(d.keys).union(d.filter { $0.key != "chatIDs" }.values.flatMap { keys(of: $0) })
        }
        if let a = json as? [Any] { return a.reduce(into: Set<String>()) { $0.formUnion(keys(of: $1)) } }
        return []
    }

    // MARK: The files

    func testTheMarkerHoldsIDsSizesAndHashesOnly() throws {
        var m = marker(intake: .taken, finalID: id + "-moved", count: 1)
        m.files.append(.init(path: "chats/\(UUID().uuidString).json", size: 300, sha256: String(repeating: "b", count: 64)))
        m.chatIDs = [UUID().uuidString: UUID().uuidString]
        let folder = temp().root
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try m.save(in: folder, claimed: true)
        let data = try Data(contentsOf: folder.appendingPathComponent(MoveMarker.claimedName))
        let json = try JSONSerialization.jsonObject(with: data)
        let found = keys(of: json)
        XCTAssertTrue(found.isSubset(of: MoveMarker.allowedKeys), "keys not allowed: \(found.subtracting(MoveMarker.allowedKeys))")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("@"))
        let chats = try XCTUnwrap((json as? [String: Any])?["chatIDs"] as? [String: String])
        XCTAssertTrue(chats.allSatisfy { UUID(uuidString: $0.key) != nil && UUID(uuidString: $0.value) != nil }, "chat ids only")
        XCTAssertEqual(MoveMarker.look(folder), .claimed(m))
    }

    func testEachMoveHasItsOwnToken() {
        let a = MoveOut(callID: id, to: work, started: t0), b = MoveOut(callID: id, to: work, started: t0)
        XCTAssertNotEqual(a.token, b.token)
        XCTAssertGreaterThanOrEqual(a.token.count, 32)
        XCTAssertTrue(marker().isMine(of: ledger(.waiting)))
        XCTAssertFalse(marker(token: theirs).isMine(of: ledger(.waiting)))
        var other = marker()
        other.to = "5e6f7a8b"
        XCTAssertFalse(other.isMine(of: ledger(.waiting)), "another target")
        other = marker()
        other.callID = id + "-moved"
        XCTAssertFalse(other.isMine(of: ledger(.waiting)), "another call")
    }

    func testANewerFileIsReadAndNeverActedOn() throws {
        let paths = temp()
        let folder = MoveMarker.folder(id, in: paths)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":2,"callID":"20261101-100000","new":true}"#.utf8).write(to: folder.appendingPathComponent(MoveMarker.fileName))
        XCTAssertEqual(MoveMarker.look(folder), .unknown)
        XCTAssertEqual(MovePlan.target(.unknown, folder: id, me: work, callFolder: true, audio: [], ownRemoval: false, held: nil), .nothing)
        XCTAssertEqual(MovePlan.source(ledger(.waiting), marker: .unknown, part: false, target: .live), .wait)
        XCTAssertEqual(MovePlan.source(ledger(.done), marker: .unknown, part: false, target: .live), .nothing, "never cleans up a newer marker")

        try FileManager.default.createDirectory(at: paths.moves, withIntermediateDirectories: true)
        try Data(#"{"version":2,"callID":"20261101-100000"}"#.utf8).write(to: MoveOut.url(id, paths: paths))
        XCTAssertNil(MoveOut.load(id, paths: paths))
        XCTAssertEqual(MoveOut.all(paths).unknown, [id])
        XCTAssertTrue(MoveOut.all(paths).moves.isEmpty)
        XCTAssertEqual(MoveOut.leftIDs(paths), [id])

        try Data("not json".utf8).write(to: folder.appendingPathComponent(MoveMarker.fileName))
        XCTAssertEqual(MoveMarker.look(folder), .unknown)
    }

    func testOneRenameDecidesBetweenAClaimAndACancel() throws {
        let paths = temp()
        let first = MoveMarker.folder(id, in: paths), second = MoveMarker.folder(id + "-moved", in: paths)
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try marker().save(in: folder, claimed: false)
        }
        XCTAssertTrue(MoveMarker.claim(first))
        XCTAssertFalse(MoveMarker.takeBack(first))
        XCTAssertEqual(MoveMarker.look(first), .claimed(marker()))

        XCTAssertTrue(MoveMarker.takeBack(second))
        XCTAssertFalse(MoveMarker.claim(second))
        XCTAssertEqual(MoveMarker.look(second), .cancelled(marker()), "taken back is its own look")
    }

    /// I1: B's claim can come between the two tests of `look`. The look tests `claimed.json` again.
    func testAClaimBetweenTheTwoTestsOfTheLookIsSeen() throws {
        let folder = MoveMarker.folder(id, in: temp())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try marker().save(in: folder, claimed: false)
        let seen = MoveMarker.look(folder, afterFirstTest: { XCTAssertTrue(MoveMarker.claim(folder)) })
        XCTAssertEqual(seen, .claimed(marker()))
    }

    func testTheLedgerKeepsItsStepsAndTheIDsThatLeft() throws {
        let paths = temp()
        var out = MoveOut(callID: id, to: work, started: t0)
        XCTAssertEqual(out.state, .copying)
        out.state = .removing
        out.removed = ["voices", "people"]
        try out.save(paths)
        XCTAssertEqual(MoveOut.load(id, paths: paths), out)
        XCTAssertEqual(out.nextStep, .coach)
        out.removed = MoveOut.Step.allCases.map(\.rawValue)
        XCTAssertNil(out.nextStep)

        var done = MoveOut(callID: "20261102-090000", to: work, started: t0)
        done.state = .done
        try done.save(paths)
        var waiting = MoveOut(callID: id, to: work, started: t0)
        waiting.state = .waiting
        try waiting.save(paths)
        XCTAssertEqual(MoveOut.leftIDs(paths), [id, "20261102-090000"])
        XCTAssertTrue(MoveOut.hasWork(paths))
        MoveOut.delete(id, paths: paths)
        XCTAssertFalse(MoveOut.hasWork(paths))
        XCTAssertEqual(MoveOut.all(paths).moves, [done])
    }

    func testWithOneProfileNoFolderIsMade() throws {
        let paths = temp()
        try paths.ensureDirectories()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.incoming.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.moves.path))
        XCTAssertTrue(MoveOut.all(paths).moves.isEmpty)
        XCTAssertTrue(MoveOut.all(paths).unknown.isEmpty)
        XCTAssertTrue(MoveOut.leftIDs(paths).isEmpty)
        XCTAssertFalse(MoveOut.hasWork(paths))
        XCTAssertEqual(MoveMarker.look(MoveMarker.folder(id, in: paths)), .missing)
    }

    // MARK: The first profile

    /// C1: a profile that is gone or `removing` holds nothing, whatever its marker says.
    func testAGoneTargetIsNotHeldEvenWhenItsMarkerSaysTaken() {
        XCTAssertEqual(MovePlan.source(ledger(.waiting), marker: .claimed(held), part: false, target: .gone), .cancel(.targetGone))
        XCTAssertEqual(MovePlan.source(ledger(.waiting), marker: .claimed(held), part: false, target: .unknown), .wait)
        XCTAssertEqual(MovePlan.source(ledger(.waiting), marker: .claimed(held), part: false, target: .live), .remove)
    }

    /// C2: only a marker of this move (its token, call, and target) lets the first profile remove or clean up.
    func testAMarkerOfAnotherMoveIsNeverActedOn() {
        let other = marker(token: theirs, intake: .taken, finalID: id, count: 1)
        for state in MoveOut.State.allCases {
            for target in [MovePlan.Target.live, .gone, .unknown] {
                let step = MovePlan.source(ledger(state), marker: .claimed(other), part: false, target: target)
                if state == .removing { XCTAssertEqual(step, .remove); continue }
                XCTAssertNotEqual(step, .cleanUp(removeIncoming: true), "\(state) \(target)")
                XCTAssertNotEqual(step, .finishCancel(removeIncoming: true), "\(state) \(target)")
                XCTAssertNotEqual(step, .takeBack, "\(state) \(target)")
                if state != .removing { XCTAssertNotEqual(step, .remove, "\(state) \(target)") }
            }
        }
        XCTAssertEqual(MovePlan.source(ledger(.done), marker: .claimed(other), part: false, target: .live), .nothing)
        XCTAssertEqual(MovePlan.source(ledger(.waiting), marker: .claimed(other), part: false, target: .live), .wait)
        XCTAssertEqual(MovePlan.source(ledger(.copied), marker: .incoming(marker(token: theirs)), part: true, target: .live), .wait)
    }

    func testATakenMarkerWithoutTheCountOfTheFilesIsNotHeld() {
        XCTAssertEqual(MovePlan.source(ledger(.waiting), marker: .claimed(marker(intake: .taken, finalID: id)), part: false, target: .live), .wait)
        XCTAssertEqual(MovePlan.source(ledger(.waiting), marker: .claimed(marker(intake: .taken, finalID: id, count: 0)), part: false, target: .live),
                       .wait)
    }

    func testTheSourcesNextStepForEachStateMarkerAndTarget() {
        let l = ledger(.copying)
        for look in looks {
            for part in [false, true] {
                XCTAssertEqual(MovePlan.source(l, marker: look, part: part, target: .live), .copy)
                XCTAssertEqual(MovePlan.source(l, marker: look, part: part, target: .gone), .cancel(.targetGone))
                XCTAssertEqual(MovePlan.source(l, marker: look, part: part, target: .unknown), .wait)
                XCTAssertEqual(MovePlan.source(ledger(.copied), marker: look, part: part, target: .gone), .cancel(.targetGone))
                XCTAssertEqual(MovePlan.source(ledger(.copied), marker: look, part: part, target: .unknown), .wait)
            }
        }
        // copied, live
        XCTAssertEqual(MovePlan.source(ledger(.copied), marker: .missing, part: true, target: .live), .publish)
        XCTAssertEqual(MovePlan.source(ledger(.copied), marker: .missing, part: false, target: .live), .copy)
        XCTAssertEqual(MovePlan.source(ledger(.copied), marker: .incoming(marker()), part: false, target: .live), .markWaiting)
        XCTAssertEqual(MovePlan.source(ledger(.copied), marker: .claimed(marker()), part: false, target: .live), .markWaiting)
        XCTAssertEqual(MovePlan.source(ledger(.copied), marker: .cancelled(marker()), part: false, target: .live), .cancel(.byOwner))
        for look in [MoveMarker.Look.unknown, .cancelled(nil), .incoming(marker(token: theirs)), .claimed(marker(token: theirs))] {
            XCTAssertEqual(MovePlan.source(ledger(.copied), marker: look, part: true, target: .live), .wait)
        }
        // waiting
        for target in [MovePlan.Target.live, .gone, .unknown] {
            XCTAssertEqual(MovePlan.source(ledger(.waiting), marker: .claimed(marker(intake: .refused, refusal: .idTaken)), part: false, target: target),
                           .cancel(.refusedIDTaken))
            XCTAssertEqual(MovePlan.source(ledger(.waiting), marker: .claimed(marker(intake: .refused, refusal: .unreadable)), part: false, target: target),
                           .cancel(.refusedUnreadable))
            XCTAssertEqual(MovePlan.source(ledger(.waiting), marker: .claimed(marker(intake: .refused, refusal: .notWhole)), part: false, target: target),
                           .cancel(.refusedNotWhole))
            XCTAssertEqual(MovePlan.source(ledger(.waiting), marker: .cancelled(marker()), part: false, target: target), .cancel(.byOwner))
        }
        for look in [MoveMarker.Look.incoming(marker()), .claimed(marker()), .claimed(marker(intake: .takingIn, finalID: id)), .unknown,
                     .claimed(marker(token: theirs)), .missing] {
            XCTAssertEqual(MovePlan.source(ledger(.waiting), marker: look, part: false, target: .gone), .cancel(.targetGone))
            XCTAssertEqual(MovePlan.source(ledger(.waiting), marker: look, part: false, target: .unknown), .wait)
        }
        for look in [MoveMarker.Look.incoming(marker()), .claimed(marker()), .claimed(marker(intake: .takingIn, finalID: id)), .unknown,
                     .claimed(marker(token: theirs)), .cancelled(nil)] {
            XCTAssertEqual(MovePlan.source(ledger(.waiting), marker: look, part: false, target: .live), .wait)
        }
        XCTAssertEqual(MovePlan.source(ledger(.waiting), marker: .missing, part: false, target: .live), .cancel(.lost))
        // removing: each step, then the clean-up of its own marker only
        for look in looks {
            for target in [MovePlan.Target.live, .gone, .unknown] {
                XCTAssertEqual(MovePlan.source(ledger(.removing), marker: look, part: false, target: target), .remove)
                var last = ledger(.removing)
                last.removed = MoveOut.Step.allCases.map(\.rawValue)
                let takenMine: Bool = if case .claimed(let m) = look { m.token == mine && m.intake == .taken } else { false }
                XCTAssertEqual(MovePlan.source(last, marker: look, part: false, target: target), .cleanUp(removeIncoming: takenMine))
            }
        }
        // cancelling
        XCTAssertEqual(MovePlan.source(ledger(.cancelling), marker: .incoming(marker()), part: false, target: .live), .takeBack)
        XCTAssertEqual(MovePlan.source(ledger(.cancelling), marker: .claimed(marker()), part: false, target: .live), .wait)
        XCTAssertEqual(MovePlan.source(ledger(.cancelling), marker: .claimed(marker(intake: .takingIn, finalID: id)), part: false, target: .gone), .wait)
        XCTAssertEqual(MovePlan.source(ledger(.cancelling), marker: .claimed(held), part: false, target: .live), .finishCancel(removeIncoming: false))
        XCTAssertEqual(MovePlan.source(ledger(.cancelling), marker: .claimed(marker(intake: .refused, refusal: .idTaken)), part: false, target: .live),
                       .finishCancel(removeIncoming: true))
        XCTAssertEqual(MovePlan.source(ledger(.cancelling), marker: .cancelled(marker()), part: false, target: .live), .finishCancel(removeIncoming: true))
        // A marker that does not read waits (review N1, `MoveCannotTellTests`).
        for look in [MoveMarker.Look.missing, .cancelled(nil), .incoming(marker(token: theirs)), .claimed(marker(token: theirs))] {
            XCTAssertEqual(MovePlan.source(ledger(.cancelling), marker: look, part: true, target: .live), .finishCancel(removeIncoming: false))
        }
        // done
        for look in looks {
            let takenMine: Bool = if case .claimed(let m) = look { m.token == mine && m.intake == .taken } else { false }
            XCTAssertEqual(MovePlan.source(ledger(.done), marker: look, part: false, target: .live), takenMine ? .cleanUp(removeIncoming: true) : .nothing)
        }
    }

    func testOnlyAWholeTakenMarkerOfThisMoveLetsTheSourceRemove() {
        for state in [MoveOut.State.copying, .copied, .waiting, .cancelling, .done] {
            for look in looks {
                for part in [false, true] {
                    for target in [MovePlan.Target.live, .gone, .unknown] {
                        let step = MovePlan.source(ledger(state), marker: look, part: part, target: target)
                        let held: Bool = if case .claimed(let m) = look { m.token == mine && m.intake == .taken && m.count == 1 } else { false }
                        if state == .waiting, held, target == .live {
                            XCTAssertEqual(step, .remove)
                        } else {
                            XCTAssertNotEqual(step, .remove, "\(state) \(look) \(part) \(target)")
                        }
                    }
                }
            }
        }
    }

    /// A finished cancel never removes an `Incoming/<id>` that B may still be taking in.
    func testACancelNeverRemovesAFolderTheTargetIsTakingIn() {
        for look in looks {
            for target in [MovePlan.Target.live, .gone, .unknown] {
                let step = MovePlan.source(ledger(.cancelling), marker: look, part: false, target: target)
                guard case .finishCancel(true) = step else { continue }
                switch look {
                case .cancelled(let m?): XCTAssertEqual(m.token, mine)
                case .claimed(let m): XCTAssertTrue(m.token == mine && m.intake == .refused, "\(look)")
                default: XCTFail("removes \(look)")
                }
            }
        }
    }

    func testARemovalGoesOnWithoutTheTarget() {
        for look in looks {
            for target in [MovePlan.Target.live, .gone, .unknown] {
                XCTAssertEqual(MovePlan.source(ledger(.removing), marker: look, part: false, target: target), .remove)
            }
        }
    }

    // MARK: The target

    func testTheTargetsNextStep() {
        let f = id
        func target(_ look: MoveMarker.Look, callFolder: Bool = true, audio: Set<String> = [], own: Bool = false, held: Bool? = nil) -> MovePlan.TargetStep {
            MovePlan.target(look, folder: id, me: work, callFolder: callFolder, audio: audio, ownRemoval: own, held: held)
        }
        for callFolder in [false, true] {
            for audio in [Set<String>(), [f]] {
                XCTAssertEqual(target(.missing, callFolder: callFolder, audio: audio), .nothing)
                XCTAssertEqual(target(.unknown, callFolder: callFolder, audio: audio), .nothing)
                XCTAssertEqual(target(.cancelled(marker()), callFolder: callFolder, audio: audio), .nothing)
                XCTAssertEqual(target(.incoming(marker()), callFolder: callFolder, audio: audio, own: true), .wait)
                XCTAssertEqual(target(.incoming(marker()), callFolder: callFolder, audio: audio), .claim)
                XCTAssertEqual(target(.claimed(marker()), callFolder: callFolder, audio: audio), .decide)
                XCTAssertEqual(target(.claimed(held), callFolder: callFolder, audio: audio), .nothing)
                XCTAssertEqual(target(.claimed(marker(intake: .refused, refusal: .idTaken)), callFolder: callFolder, audio: audio), .nothing)
            }
        }
        let takingIn = MoveMarker.Look.claimed(marker(intake: .takingIn, finalID: f))
        XCTAssertEqual(target(takingIn, callFolder: true, audio: []), .takeIn(as: f))
        XCTAssertEqual(target(takingIn, callFolder: false, audio: [f], held: true), .markTaken)
        XCTAssertEqual(target(takingIn, callFolder: false, audio: [f], held: false), .refuse(.notWhole))
        XCTAssertEqual(target(takingIn, callFolder: false, audio: [f], held: nil), .wait, "the files are checked before taken")
        XCTAssertEqual(target(takingIn, callFolder: true, audio: [f]), .decide)
        XCTAssertEqual(target(takingIn, callFolder: false, audio: []), .refuse(.notWhole))
        XCTAssertEqual(target(.claimed(marker(intake: .takingIn))), .decide)
    }

    func testTheTargetTakesOnlyAMarkerAddressedToIt() {
        var other = marker()
        other.to = "5e6f7a8b"
        XCTAssertEqual(MovePlan.target(.incoming(other), folder: id, me: work, callFolder: true, audio: [], ownRemoval: false, held: nil), .nothing)
        var named = marker()
        named.callID = "20261102-090000"
        XCTAssertEqual(MovePlan.target(.incoming(named), folder: id, me: work, callFolder: true, audio: [], ownRemoval: false, held: nil), .nothing)
        XCTAssertEqual(MovePlan.target(.claimed(other), folder: id, me: work, callFolder: true, audio: [], ownRemoval: false, held: nil), .nothing)
    }

    /// I3: a take-in of an id waits while this profile still has a move of that id that is not done.
    func testATakeInWaitsForTheProfilesOwnMoveOfThatID() {
        XCTAssertFalse(MovePlan.ownRemoval(nil))
        for state in MoveOut.State.allCases {
            XCTAssertEqual(MovePlan.ownRemoval(ledger(state)), state != .done, "\(state)")
        }
        XCTAssertEqual(MovePlan.target(.incoming(marker(token: theirs)), folder: id, me: work, callFolder: true, audio: [],
                                       ownRemoval: MovePlan.ownRemoval(ledger(.waiting)), held: nil), .wait)
    }

    func testTheIDThatIsTaken() {
        XCTAssertEqual(MovePlan.finalID("20261101-100000", taken: []), "20261101-100000")
        XCTAssertEqual(MovePlan.finalID("20261101-100000", taken: ["20261101-100000"]), "20261101-100000-moved")
        XCTAssertEqual(MovePlan.finalID("20261101-100000-moved", taken: ["20261101-100000", "20261101-100000-moved"]), "20261101-100000-moved-moved")
        XCTAssertNil(MovePlan.finalID("20261101-100000", taken: ["20261101-100000", "20261101-100000-moved"]))
    }

    func testTheTargetsDecision() {
        let r = CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0 + 60, status: .written)
        var unknown = r
        unknown.platform = .unknown
        XCTAssertTrue(MovePlan.decide(record: nil, sizesMatch: true, id: id, taken: []) == (.refused, nil, .unreadable))
        XCTAssertTrue(MovePlan.decide(record: unknown, sizesMatch: true, id: id, taken: []) == (.refused, nil, .unreadable))
        XCTAssertTrue(MovePlan.decide(record: r, sizesMatch: false, id: id, taken: []) == (.refused, nil, .notWhole))
        XCTAssertTrue(MovePlan.decide(record: r, sizesMatch: true, id: id, taken: [id, id + "-moved"]) == (.refused, nil, .idTaken))
        XCTAssertTrue(MovePlan.decide(record: r, sizesMatch: true, id: id, taken: [id]) == (.takingIn, id + "-moved", nil))
        XCTAssertTrue(MovePlan.decide(record: r, sizesMatch: true, id: id, taken: []) == (.takingIn, id, nil))
    }

    func testTheFilesBTookAreCheckedAgainstTheMarker() {
        let files = [MoveMarker.File(path: "call/call.json", size: 10, sha256: "aa"), .init(path: "call/me.caf", size: 20, sha256: "bb")]
        XCTAssertTrue(MovePlan.held(files, found: ["call/call.json": (10, "aa"), "call/me.caf": (20, "bb")]))
        XCTAssertFalse(MovePlan.held(files, found: ["call/call.json": (10, "aa")]), "one is missing")
        XCTAssertFalse(MovePlan.held(files, found: ["call/call.json": (10, "aa"), "call/me.caf": (19, "bb")]), "another size")
        XCTAssertFalse(MovePlan.held(files, found: ["call/call.json": (10, "aa"), "call/me.caf": (20, "cc")]), "another hash")
        XCTAssertFalse(MovePlan.held([], found: [:]), "nothing is not a meeting")
    }
}

private func == (a: (MoveMarker.Intake, String?, MoveMarker.Refusal?), b: (MoveMarker.Intake, String?, MoveMarker.Refusal?)) -> Bool {
    a.0 == b.0 && a.1 == b.1 && a.2 == b.2
}
