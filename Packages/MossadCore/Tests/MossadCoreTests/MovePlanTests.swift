import XCTest
@testable import MossadCore

final class MovePlanTests: XCTestCase {
    private let id = "20261101-100000"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MovePlanTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func marker(intake: MoveMarker.Intake? = nil, finalID: String? = nil, refusal: MoveMarker.Refusal? = nil) -> MoveMarker {
        var m = MoveMarker(callID: id, from: "default", to: "1a2b3c4d", made: t0,
                           files: [.init(path: "call/call.json", size: 120, sha256: String(repeating: "a", count: 64))], ownerKeys: ["me:A"])
        m.intake = intake
        m.finalID = finalID
        m.refusal = refusal
        return m
    }

    /// Every look of the marker that a side can see.
    private var looks: [MoveMarker.Look] {
        [.missing, .incoming(marker()), .claimed(marker()), .claimed(marker(intake: .takingIn, finalID: id)),
         .claimed(marker(intake: .taken, finalID: id)), .claimed(marker(intake: .refused, refusal: .idTaken)),
         .claimed(marker(intake: .refused, refusal: .unreadable)), .claimed(marker(intake: .refused, refusal: .notWhole)), .unknown]
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
        var m = MoveMarker(callID: id, from: "default", to: "1a2b3c4d", made: t0,
                           files: [.init(path: "call/call.json", size: 120, sha256: String(repeating: "a", count: 64)),
                                   .init(path: "chats/\(UUID().uuidString).json", size: 300, sha256: String(repeating: "b", count: 64))],
                           ownerKeys: ["me:A"])
        m.intake = .taken
        m.finalID = id + "-moved"
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

    func testANewerFileIsReadAndNeverActedOn() throws {
        let paths = temp()
        let folder = MoveMarker.folder(id, in: paths)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":2,"callID":"20261101-100000","new":true}"#.utf8).write(to: folder.appendingPathComponent(MoveMarker.fileName))
        XCTAssertEqual(MoveMarker.look(folder), .unknown)
        XCTAssertEqual(MovePlan.target(.unknown, callFolder: true, audio: [], ownRemoval: false), .nothing)
        XCTAssertEqual(MovePlan.source(.waiting, marker: .unknown, part: false, target: .live), .wait)

        try FileManager.default.createDirectory(at: paths.moves, withIntermediateDirectories: true)
        try Data(#"{"version":2,"callID":"20261101-100000"}"#.utf8).write(to: MoveOut.url(id, paths: paths))
        XCTAssertNil(MoveOut.load(id, paths: paths))
        XCTAssertEqual(MoveOut.all(paths).unknown, [id])
        XCTAssertTrue(MoveOut.all(paths).moves.isEmpty)
        XCTAssertEqual(MoveOut.leftIDs(paths), [id])

        // A file that does not decode is not known either: not "missing", so nothing is decided from it.
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
        XCTAssertEqual(MoveMarker.look(second), .missing)
    }

    func testTheLedgerKeepsItsStepsAndTheIDsThatLeft() throws {
        let paths = temp()
        var out = MoveOut(callID: id, to: "1a2b3c4d", started: t0)
        XCTAssertEqual(out.state, .copying)
        out.state = .removing
        out.removed = ["voices", "people"]
        try out.save(paths)
        XCTAssertEqual(MoveOut.load(id, paths: paths), out)
        XCTAssertEqual(out.nextStep, .coach)
        out.removed = MoveOut.Step.allCases.map(\.rawValue)
        XCTAssertNil(out.nextStep)

        var done = MoveOut(callID: "20261102-090000", to: "1a2b3c4d", started: t0)
        done.state = .done
        try done.save(paths)
        var waiting = MoveOut(callID: id, to: "1a2b3c4d", started: t0)
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
        XCTAssertEqual(paths.incoming.lastPathComponent, "Incoming")
        XCTAssertEqual(paths.moves.lastPathComponent, "Moves")
    }

    // MARK: The tables

    func testTheSourcesNextStepForEachStateMarkerAndTarget() {
        typealias S = MovePlan.SourceStep
        for look in looks {
            for part in [false, true] {
                XCTAssertEqual(MovePlan.source(.copying, marker: look, part: part, target: .live), .copy)
                XCTAssertEqual(MovePlan.source(.copying, marker: look, part: part, target: .gone), .cancel(.targetGone))
                XCTAssertEqual(MovePlan.source(.copied, marker: look, part: part, target: .gone), .cancel(.targetGone))
                XCTAssertEqual(MovePlan.source(.removing, marker: look, part: part, target: .live), .remove)
                XCTAssertEqual(MovePlan.source(.removing, marker: look, part: part, target: .gone), .remove)
                XCTAssertEqual(MovePlan.source(.cancelling, marker: look, part: part, target: .live), .finishCancel)
                XCTAssertEqual(MovePlan.source(.cancelling, marker: look, part: part, target: .gone), .finishCancel)
                let done: S = look == .missing ? .nothing : .cleanUp
                XCTAssertEqual(MovePlan.source(.done, marker: look, part: part, target: .live), done)
                XCTAssertEqual(MovePlan.source(.done, marker: look, part: part, target: .gone), done)
            }
        }
        XCTAssertEqual(MovePlan.source(.copied, marker: .missing, part: true, target: .live), .publish)
        XCTAssertEqual(MovePlan.source(.copied, marker: .missing, part: false, target: .live), .copy)
        for look in looks where look != .missing {
            XCTAssertEqual(MovePlan.source(.copied, marker: look, part: false, target: .live), .wait)
            XCTAssertEqual(MovePlan.source(.copied, marker: look, part: true, target: .live), .wait)
        }
        for target in [MovePlan.Target.live, .gone] {
            XCTAssertEqual(MovePlan.source(.waiting, marker: .claimed(marker(intake: .taken, finalID: id)), part: false, target: target), .remove)
            XCTAssertEqual(MovePlan.source(.waiting, marker: .claimed(marker(intake: .refused, refusal: .idTaken)), part: false, target: target),
                           .cancel(.refusedIDTaken))
            XCTAssertEqual(MovePlan.source(.waiting, marker: .claimed(marker(intake: .refused, refusal: .unreadable)), part: false, target: target),
                           .cancel(.refusedUnreadable))
            XCTAssertEqual(MovePlan.source(.waiting, marker: .claimed(marker(intake: .refused, refusal: .notWhole)), part: false, target: target),
                           .cancel(.refusedNotWhole))
        }
        for look in [MoveMarker.Look.incoming(marker()), .claimed(marker()), .claimed(marker(intake: .takingIn, finalID: id)), .unknown] {
            XCTAssertEqual(MovePlan.source(.waiting, marker: look, part: false, target: .live), .wait)
            XCTAssertEqual(MovePlan.source(.waiting, marker: look, part: false, target: .gone), .cancel(.targetGone))
        }
        XCTAssertEqual(MovePlan.source(.waiting, marker: .missing, part: false, target: .live), .cancel(.lost))
        XCTAssertEqual(MovePlan.source(.waiting, marker: .missing, part: false, target: .gone), .cancel(.targetGone))
    }

    func testOnlyATakenMarkerLetsTheSourceRemove() {
        for state in [MoveOut.State.copying, .copied, .waiting] {
            for look in looks {
                for part in [false, true] {
                    for target in [MovePlan.Target.live, .gone] {
                        let step = MovePlan.source(state, marker: look, part: part, target: target)
                        let taken: Bool = if case .claimed(let m) = look { m.intake == .taken } else { false }
                        if state == .waiting, taken {
                            XCTAssertEqual(step, .remove)
                        } else {
                            XCTAssertNotEqual(step, .remove, "\(state) \(look) \(part) \(target)")
                        }
                        XCTAssertNotEqual(step, .cleanUp, "\(state) \(look) \(part) \(target)")
                    }
                }
            }
        }
    }

    func testARemovalGoesOnWithoutTheTarget() {
        for look in looks {
            for part in [false, true] {
                for target in [MovePlan.Target.live, .gone] {
                    XCTAssertEqual(MovePlan.source(.removing, marker: look, part: part, target: target), .remove)
                }
            }
        }
    }

    func testTheTargetsNextStep() {
        let f = id
        for callFolder in [false, true] {
            for audio in [Set<String>(), [f]] {
                XCTAssertEqual(MovePlan.target(.missing, callFolder: callFolder, audio: audio, ownRemoval: false), .nothing)
                XCTAssertEqual(MovePlan.target(.unknown, callFolder: callFolder, audio: audio, ownRemoval: false), .nothing)
                XCTAssertEqual(MovePlan.target(.incoming(marker()), callFolder: callFolder, audio: audio, ownRemoval: true), .wait)
                XCTAssertEqual(MovePlan.target(.incoming(marker()), callFolder: callFolder, audio: audio, ownRemoval: false), .claim)
                XCTAssertEqual(MovePlan.target(.claimed(marker()), callFolder: callFolder, audio: audio, ownRemoval: false), .decide)
                XCTAssertEqual(MovePlan.target(.claimed(marker(intake: .taken, finalID: f)), callFolder: callFolder, audio: audio, ownRemoval: false), .nothing)
                XCTAssertEqual(MovePlan.target(.claimed(marker(intake: .refused, refusal: .idTaken)), callFolder: callFolder, audio: audio, ownRemoval: false), .nothing)
            }
        }
        let takingIn = MoveMarker.Look.claimed(marker(intake: .takingIn, finalID: f))
        XCTAssertEqual(MovePlan.target(takingIn, callFolder: true, audio: [], ownRemoval: false), .takeIn(as: f))
        XCTAssertEqual(MovePlan.target(takingIn, callFolder: false, audio: [f], ownRemoval: false), .markTaken)
        XCTAssertEqual(MovePlan.target(takingIn, callFolder: true, audio: [f], ownRemoval: false), .decide)
        XCTAssertEqual(MovePlan.target(takingIn, callFolder: false, audio: [], ownRemoval: false), .refuse(.notWhole))
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

    // MARK: Never in neither

    /// A model of both sides that acts only by `MovePlan.source` and `MovePlan.target`. Every reachable state is a place
    /// where the Mac can stop; the next launch then takes the step the table gives. A stop inside a copy, the owner's
    /// Cancel, a target that goes, and each refusal are steps too.
    private struct World: Hashable {
        enum Incoming: Hashable { case none, halfPart, wholePart, published(Marker) }
        enum Marker: Hashable { case move, cancelled, claimed(MoveMarker.Intake?, String?, MoveMarker.Refusal?) }
        /// nil: no move (never started, or a cancel that ended).
        var state: MoveOut.State?
        var removed = 0
        var incoming = Incoming.none
        /// The prepared call folder in `Incoming/<id>`.
        var callFolder = false
        var targetHas = false
        var targetLive = true
        /// What the target holds in `Audio` besides this meeting, and whether the copy reads.
        var taken: Set<String>
        var readable: Bool
        var whole: Bool

        var sourceHas: Bool { removed < MoveOut.Step.allCases.count }
    }

    private func look(_ w: World) -> MoveMarker.Look {
        guard case .published(let m) = w.incoming else { return .missing }
        switch m {
        case .move: return .incoming(marker())
        case .cancelled: return .missing
        case .claimed(let intake, let f, let refusal): return .claimed(marker(intake: intake, finalID: f, refusal: refusal))
        }
    }

    private func next(_ w: World) -> [World] {
        var out: [World] = []
        let r = CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0 + 60, status: .written)
        // The first profile.
        if let state = w.state {
            let part: Bool = if case .wholePart = w.incoming { true } else if case .halfPart = w.incoming { true } else { false }
            let step = MovePlan.source(state, marker: look(w), part: part, target: w.targetLive ? .live : .gone)
            var n = w
            switch step {
            case .copy:
                // A stop inside the copy leaves a half part; a failed copy cancels; a whole one is saved as copied.
                n.incoming = .halfPart
                out.append(n)
                n = w
                n.state = .cancelling
                out.append(n)
                n = w
                n.incoming = .wholePart
                n.callFolder = true
                n.state = .copied
                out.append(n)
            case .publish:
                n.incoming = .published(.move)
                out.append(n)
            case .wait:
                if state == .copied {
                    n.state = .waiting
                    out.append(n)
                }
            case .remove:
                if state != .removing {
                    n.state = .removing
                } else if w.removed < MoveOut.Step.allCases.count {
                    n.removed += 1
                } else {
                    n.incoming = .none
                    n.callFolder = false
                    n.state = .done
                }
                out.append(n)
            case .cleanUp:
                n.incoming = .none
                n.callFolder = false
                out.append(n)
            case .cancel:
                n.state = .cancelling
                out.append(n)
            case .finishCancel:
                n.incoming = .none
                n.callFolder = false
                n.state = nil
                out.append(n)
            case .nothing:
                break
            }
            // The owner's Cancel, while the move is not past its point of no return.
            if [.copying, .copied, .waiting].contains(state) {
                var c = w
                switch w.incoming {
                case .published(.move):
                    c.incoming = .published(.cancelled)
                    c.state = .cancelling
                    out.append(c)
                case .published(.claimed):
                    break
                default:
                    c.state = .cancelling
                    out.append(c)
                }
            }
        }
        // The target, while it is a profile.
        if w.targetLive {
            var n = w
            switch MovePlan.target(look(w), callFolder: w.callFolder, audio: w.taken.union(w.targetHas ? [id] : []), ownRemoval: false) {
            case .claim:
                n.incoming = .published(.claimed(nil, nil, nil))
                out.append(n)
            case .decide:
                let d = MovePlan.decide(record: w.readable ? r : nil, sizesMatch: w.whole, id: id,
                                        taken: w.taken.union(w.targetHas ? [id] : []))
                n.incoming = .published(.claimed(d.intake, d.finalID, d.refusal))
                out.append(n)
            case .takeIn(let f):
                n.callFolder = false
                n.targetHas = true
                n.taken.insert(f)
                out.append(n)
            case .markTaken:
                if case .published(.claimed(_, let f, _)) = w.incoming { n.incoming = .published(.claimed(.taken, f, nil)) }
                out.append(n)
            case .refuse(let why):
                n.incoming = .published(.claimed(.refused, nil, why))
                out.append(n)
            case .wait, .nothing:
                break
            }
            // The owner removes the target profile at any time.
            var gone = w
            gone.targetLive = false
            out.append(gone)
        }
        return out
    }

    func testAStopAtAnyPointLeavesTheMeetingWholeInTheFirstProfileOrInBoth() {
        var seen = Set<World>()
        var ends: [World] = []
        for taken in [Set<String>(), [id], [id, id + "-moved"]] {
            for readable in [true, false] {
                for whole in [true, false] {
                    var queue = [World(state: .copying, taken: taken, readable: readable, whole: whole)]
                    while let w = queue.popLast() {
                        guard seen.insert(w).inserted else { continue }
                        XCTAssertTrue(w.sourceHas || w.targetHas, "in neither profile: \(w)")
                        // The first profile removes only what the target holds whole.
                        if w.removed > 0 { XCTAssertTrue(w.targetHas, "a removal without the meeting in the target: \(w)") }
                        let more = next(w)
                        if more.isEmpty { ends.append(w) }
                        queue.append(contentsOf: more)
                    }
                }
            }
        }
        XCTAssertGreaterThan(seen.count, 100, "the model reached the states")
        // Every end is the meeting in exactly one profile, or a cancel after the target went or took it in (both).
        for e in ends {
            XCTAssertTrue(e.sourceHas || e.targetHas, "\(e)")
            if e.sourceHas, e.targetHas { XCTAssertFalse(e.targetLive, "both, with the target live: \(e)") }
        }
        // Each state of the ledger and each look of the marker was a stop somewhere.
        let states = Set(seen.compactMap(\.state))
        XCTAssertEqual(states, Set(MoveOut.State.allCases))
        let marks = Set(seen.map { w -> String in
            switch w.incoming {
            case .none: "none"
            case .halfPart: "half"
            case .wholePart: "part"
            case .published(.move): "move"
            case .published(.cancelled): "cancelled"
            case .published(.claimed(let i, _, let r)): "claimed \(i.map(\.rawValue) ?? "nil") \(r.map(\.rawValue) ?? "")"
            }
        })
        for wanted in ["none", "half", "part", "move", "cancelled", "claimed nil ", "claimed takingIn ", "claimed taken ",
                       "claimed refused idTaken", "claimed refused unreadable", "claimed refused notWhole"] {
            XCTAssertTrue(marks.contains(wanted), "no stop with the marker \(wanted)")
        }
    }
}

private func == (a: (MoveMarker.Intake, String?, MoveMarker.Refusal?), b: (MoveMarker.Intake, String?, MoveMarker.Refusal?)) -> Bool {
    a.0 == b.0 && a.1 == b.1 && a.2 == b.2
}
