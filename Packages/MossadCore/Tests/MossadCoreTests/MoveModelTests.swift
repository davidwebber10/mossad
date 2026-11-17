import XCTest
@testable import MossadCore

/// A model of a move that acts only by the pure rules: `MovePlan.source`, `MovePlan.target`, `MovePlan.ownRemoval`, and
/// the look of the marker. Each state it reaches is a place where the Mac can stop; the next launch takes the step the
/// rules give. Every step that a file system does in more than one write is more than one step here:
/// - the copy (files, then `move.json` last, then the ledger `copied`), and a copy that fails;
/// - the owner's Cancel (the rename, then the ledger);
/// - the take-in (its first half, then the folder into `Audio`), and `taken` only after the files are checked;
/// - each removal step, the folder of the call last;
/// - the end of a cancel (the folder, then the ledger last).
/// Also: a third profile that moves its own meeting with the same id to B; a move back; a target that goes and comes
/// back; a registry that cannot be read; a marker with no ledger; a ledger with no marker.
///
/// The rules that must hold at every state:
/// 1. Each meeting is whole in its first profile or held by B (in `Audio`, from its own move), never in neither. A profile
///    that is gone holds nothing, unless it went after the first profile's removal had started (the owner deleted it).
/// 2. A profile starts its removal only while B is live and holds the meeting of that profile's own move, whole.
/// 3. A profile never removes an `Incoming/<id>` that B may still be taking in.
/// 4. A profile never takes in an id while its own move of that id is not done.
final class MoveModelTests: XCTestCase {
    fileprivate static let x = "20261101-100000"
    fileprivate static let b = "1a2b3c4d"

    func testEveryStopKeepsTheRules() {
        let found = MoveModel(rules: .now).run(MoveModel.scenarios)
        XCTAssertTrue(found.violations.isEmpty, "\(found.violations.sorted().prefix(5))")
        XCTAssertGreaterThan(found.states, 1000, "the model reached the states")
        XCTAssertEqual(found.ledgerStates, Set(MoveOut.State.allCases))
        for look in ["none", "move", "claimed nil", "claimed takingIn", "claimed taken", "claimed refused", "cancelled"] {
            XCTAssertTrue(found.markers.contains(look), "no stop with the marker \(look)")
        }
        XCTAssertTrue(found.markers.contains("half part"))
        XCTAssertTrue(found.markers.contains("part without marker"))
        XCTAssertTrue(found.markers.contains("part with marker"))
    }

    /// The same model, with the rules as they were at 765e278: it finds each fault of the review.
    func testTheModelFindsTheFaultsOfTheRulesBefore() {
        let c1 = MoveModel(rules: .before).run([MoveModel.scenarios[0]])
        XCTAssertTrue(c1.violations.contains { $0.hasPrefix("rule 2 (target gone)") }, "C1: \(c1.violations.sorted().prefix(3))")
        let c2 = MoveModel(rules: .before, statusEvents: false).run(MoveModel.threeProfiles)
        XCTAssertTrue(c2.violations.contains { $0.hasPrefix("rule 2 (not this move's)") || $0.hasPrefix("rule 3") || $0.hasPrefix("rule 1") },
                      "C2: \(c2.violations.sorted().prefix(3))")
        let i1 = MoveModel(rules: .before, statusEvents: false, ownerCancel: false).run([MoveModel.scenarios[0]])
        XCTAssertTrue(i1.violations.contains { $0.hasPrefix("rule 3") }, "I1: \(i1.violations.sorted().prefix(3))")
        let i3 = MoveModel(rules: .before, statusEvents: false).run(MoveModel.moveBack)
        XCTAssertTrue(i3.violations.contains { $0.hasPrefix("rule 4") }, "I3: \(i3.violations.sorted().prefix(3))")
        // And the rules of now pass each of these.
        for (scenarios, status, cancel) in [(MoveModel.threeProfiles, false, true), ([MoveModel.scenarios[0]], false, false), (MoveModel.moveBack, false, true)] {
            XCTAssertTrue(MoveModel(rules: .now, statusEvents: status, ownerCancel: cancel).run(scenarios).violations.isEmpty)
        }
    }
}

private struct MoveModel {
    enum Rules { case now, before }
    let rules: Rules
    var statusEvents = true
    var ownerCancel = true

    enum Status: Hashable { case live, gone, unknown }

    struct Folder: Hashable {
        enum File: Hashable { case move, claimed, cancelled }
        var token: String
        var from: String
        var file: File
        var intake: MoveMarker.Intake?
        var finalID: String?
        var refusal: MoveMarker.Refusal?
        var count: Int?
        /// The prepared call folder is still in `Incoming/<id>`.
        var call = true
    }

    struct Source: Hashable {
        var name: String
        var token: String
        /// The meeting is whole in this profile.
        var has = true
        var tracked = true
        var state: MoveOut.State?
        var removed = 0
        /// 0 none, 1 half the files, 2 every file and no marker, 3 every file and the marker.
        var part = 0
        var cancel: MovePlan.Cancel?
    }

    struct World: Hashable {
        var sources: [Source]
        var incoming: Folder?
        /// B's `Audio`: the final id to the token of the move it came from ("" for B's own meeting).
        var audio: [String: String]
        /// The token whose first half of a take-in is done in B.
        var half: String?
        var status = Status.live
        var cameBack = false
        var goneAfterRemoval = false
        /// The move back: B's marker in A's `Incoming/<id>`, and whether A took it in.
        var moveBack = false
        var back: Folder?
        var aTookBack = false
        var readable = true
        var whole = true
    }

    struct Found {
        var violations = Set<String>()
        var states = 0
        var ledgerStates = Set<MoveOut.State>()
        var markers = Set<String>()
    }

    // MARK: Scenarios

    static func start(_ sources: [Source], audio: [String: String] = [:], readable: Bool = true, whole: Bool = true) -> World {
        World(sources: sources, incoming: nil, audio: audio, readable: readable, whole: whole)
    }

    static var a: Source { Source(name: "default", token: "token-a", state: .copying) }
    static var c: Source { Source(name: "5e6f7a8b", token: "token-c", state: .copying) }

    static var scenarios: [World] {
        var out = [start([a]), start([a], audio: [MoveModelTests.x: ""]), start([a], audio: [MoveModelTests.x: "", MoveModelTests.x + "-moved": ""]),
                   start([a], readable: false), start([a], whole: false)]
        // A marker with no ledger: A lost its file.
        var noLedger = start([Source(name: "default", token: "token-a", state: nil)])
        noLedger.incoming = Folder(token: "token-a", from: "default", file: .move)
        out.append(noLedger)
        // A ledger with no marker.
        out.append(start([Source(name: "default", token: "token-a", state: .waiting)]))
        return out + threeProfiles + moveBack
    }

    /// C and A each have a meeting with the id X and move it to B. And X that went from A to B to C: A's ledger is done.
    static var threeProfiles: [World] {
        [start([a, c]), start([Source(name: "default", token: "token-a", has: false, tracked: false, state: .done), c])]
    }

    static var moveBack: [World] {
        var w = start([a])
        w.moveBack = true
        return [w]
    }

    // MARK: Looks

    func marker(_ f: Folder) -> MoveMarker {
        var m = MoveMarker(callID: MoveModelTests.x, from: f.from, to: MoveModelTests.b, made: Date(timeIntervalSince1970: 0), token: f.token,
                           files: [.init(path: "call/call.json", size: 1, sha256: "a"), .init(path: "call/me.caf", size: 1, sha256: "b")],
                           ownerKeys: [])
        m.intake = f.intake
        m.finalID = f.finalID
        m.refusal = f.refusal
        m.count = f.count
        return m
    }

    func look(_ f: Folder?) -> MoveMarker.Look {
        guard let f else { return .missing }
        switch f.file {
        case .move: return .incoming(marker(f))
        case .claimed: return .claimed(marker(f))
        case .cancelled: return rules == .now ? .cancelled(marker(f)) : .missing
        }
    }

    func ledger(_ s: Source) -> MoveOut {
        var out = MoveOut(callID: MoveModelTests.x, to: MoveModelTests.b, started: Date(timeIntervalSince1970: 0), token: s.token)
        out.state = s.state ?? .done
        out.removed = Array(MoveOut.Step.allCases.prefix(s.removed).map(\.rawValue))
        out.cancel = s.cancel
        return out
    }

    func target(_ w: World) -> MovePlan.Target {
        switch w.status {
        case .live: .live
        case .gone: .gone
        case .unknown: rules == .now ? .unknown : .gone
        }
    }

    // MARK: Steps

    func next(_ w: World) -> [(World, [String])] {
        var out: [(World, [String])] = []
        for i in w.sources.indices where w.sources[i].state != nil {
            out += sourceSteps(w, i)
        }
        if w.status != .gone { out += targetSteps(w) }
        out += moveBackSteps(w)
        if statusEvents {
            var n = w
            switch w.status {
            case .live:
                n.status = .gone
                if w.sources.contains(where: { [.removing, .done].contains($0.state) }) { n.goneAfterRemoval = true }
                out.append((n, []))
                var u = w
                u.status = .unknown
                out.append((u, []))
            case .gone where !w.cameBack:
                n.status = .live
                n.cameBack = true
                out.append((n, []))
            case .unknown:
                n.status = .live
                out.append((n, []))
            default: break
            }
        }
        return out
    }

    func sourceSteps(_ w: World, _ i: Int) -> [(World, [String])] {
        let s = w.sources[i]
        guard let state = s.state else { return [] }
        var out: [(World, [String])] = []
        // The marker this side reads. With the rules before, B's claim can come between the two tests of the look.
        var views: [(MoveMarker.Look, World)] = [(look(w.incoming), w)]
        if rules == .before, w.status != .gone, let f = w.incoming, f.file == .move {
            var raced = w
            raced.incoming?.file = .claimed
            views.append((.missing, raced))
        }
        for (seen, base) in views {
            let step: MovePlan.SourceStep = rules == .now
                ? MovePlan.source(ledger(s), marker: seen, part: s.part == 3, target: target(base))
                : Self.before(state, seen, part: s.part == 3, target: target(base))
            out += apply(step, base, i, seen: seen)
        }
        // The owner's Cancel: the rename, then the ledger.
        if ownerCancel, [.copying, .copied, .waiting].contains(state) {
            var n = w
            if let f = w.incoming, f.token == s.token || rules == .before {
                if f.file == .move {
                    n.incoming?.file = .cancelled
                    out.append((n, []))
                    if rules == .before {
                        n.sources[i].state = .cancelling
                        n.sources[i].cancel = .byOwner
                        out.append((n, []))
                    }
                }
            } else {
                n.sources[i].state = .cancelling
                n.sources[i].cancel = .byOwner
                out.append((n, []))
            }
        }
        return out
    }

    func apply(_ step: MovePlan.SourceStep, _ w: World, _ i: Int, seen: MoveMarker.Look) -> [(World, [String])] {
        var n = w
        var s = w.sources[i]
        func done(_ v: [String] = []) -> [(World, [String])] {
            n.sources[i] = s
            return [(n, v)]
        }
        switch step {
        case .copy:
            // A stop in the copy, a copy that fails, and the three writes of a copy.
            var steps: [(World, [String])] = []
            var stop = w
            stop.sources[i].part = s.part == 2 ? 3 : (s.part == 3 ? 3 : (s.part == 0 ? 1 : 2))
            if s.part == 3 { stop.sources[i].state = .copied }
            steps.append((stop, []))
            var failed = w
            failed.sources[i].state = .cancelling
            failed.sources[i].cancel = .copyFailed
            steps.append((failed, []))
            return steps
        case .publish:
            guard s.part == 3 else { return [] }
            if n.incoming == nil {
                n.incoming = Folder(token: s.token, from: s.name, file: .move)
                s.part = 0
            }
            return done()
        case .markWaiting:
            s.state = .waiting
            return done()
        case .wait, .nothing:
            // Before, `wait` in `copied` with a marker is the same save.
            if rules == .before, s.state == .copied, seen != .missing {
                s.state = .waiting
                return done()
            }
            return []
        case .remove:
            if s.state == .waiting {
                var v: [String] = []
                if w.status != .live { v.append("rule 2 (target gone): \(s.name) removes while B is \(w.status)") }
                let mine = w.audio.contains { $0.value == s.token }
                if !mine { v.append("rule 2 (not this move's): \(s.name) removes, and B holds no meeting of its move") }
                s.state = .removing
                return done(v)
            }
            if s.removed < MoveOut.Step.allCases.count {
                s.removed += 1
                if s.removed == MoveOut.Step.allCases.count { s.has = false }
                return done()
            }
            // Before: the end of the removal removes `Incoming/<id>` and saves done in one step.
            var v: [String] = []
            if let f = w.incoming, f.file == .claimed, f.intake == nil || f.intake == .takingIn { v.append("rule 3: \(s.name) removes a folder B takes in") }
            n.incoming = nil
            s.state = .done
            return done(v)
        case .cleanUp(let removeIncoming):
            var v: [String] = []
            if removeIncoming || rules == .before, let f = w.incoming {
                if f.file == .claimed, f.intake == nil || f.intake == .takingIn { v.append("rule 3: \(s.name) removes a folder B takes in") }
                if f.token != s.token { v.append("rule 3: \(s.name) removes the folder of another move") }
                n.incoming = nil
            } else {
                s.state = .done
            }
            return done(v)
        case .cancel(let why):
            s.state = .cancelling
            s.cancel = why
            return done()
        case .takeBack:
            if let f = w.incoming, f.file == .move, f.token == s.token { n.incoming?.file = .cancelled }
            return done()
        case .finishCancel(let removeIncoming):
            var v: [String] = []
            if (removeIncoming || rules == .before), let f = w.incoming {
                if f.file == .claimed, f.intake == nil || f.intake == .takingIn { v.append("rule 3: \(s.name) removes a folder B takes in") }
                if f.token != s.token { v.append("rule 3: \(s.name) removes the folder of another move") }
                n.incoming = nil
                if rules == .now { return done(v) }
            }
            // Its own part, the mark, and the ledger last.
            s.part = 0
            s.state = nil
            s.cancel = nil
            return done(v)
        }
    }

    func targetSteps(_ w: World) -> [(World, [String])] {
        guard let f = w.incoming, f.file != .cancelled else { return [] }
        let r = CallRecord(id: MoveModelTests.x, platform: .zoom, bundleID: "us.zoom.xos", start: Date(timeIntervalSince1970: 0),
                           end: Date(timeIntervalSince1970: 60), status: .written)
        var n = w
        let held: Bool? = f.finalID.map { w.audio[$0] == f.token }
        let step = rules == .now
            ? MovePlan.target(look(f), folder: MoveModelTests.x, me: MoveModelTests.b, callFolder: f.call, audio: Set(w.audio.keys),
                              ownRemoval: false, held: held)
            : Self.beforeTarget(look(f), callFolder: f.call, audio: Set(w.audio.keys))
        switch step {
        case .claim:
            n.incoming?.file = .claimed
        case .decide:
            let d = MovePlan.decide(record: w.readable ? r : nil, sizesMatch: w.whole, id: MoveModelTests.x, taken: Set(w.audio.keys))
            n.incoming?.intake = d.intake
            n.incoming?.finalID = d.finalID
            n.incoming?.refusal = d.refusal
        case .takeIn(let id):
            if w.half != f.token {
                n.half = f.token
            } else {
                n.half = nil
                n.audio[id] = f.token
                n.incoming?.call = false
            }
        case .markTaken:
            n.incoming?.intake = .taken
            n.incoming?.count = 2
        case .refuse(let why):
            // A refusal undoes B's own half first.
            n.half = nil
            n.incoming?.intake = .refused
            n.incoming?.refusal = why
        case .wait, .nothing:
            return []
        }
        return [(n, [])]
    }

    /// B sends A's meeting back: its marker in A's `Incoming/<id>`, and A takes it in by the same rules.
    func moveBackSteps(_ w: World) -> [(World, [String])] {
        guard w.moveBack, !w.aTookBack, let ai = w.sources.firstIndex(where: { $0.token == "token-a" }) else { return [] }
        var n = w
        guard let f = w.back else {
            // B holds A's meeting whole and taken: it starts the move back.
            guard w.status != .gone, let inc = w.incoming, inc.token == "token-a", inc.intake == .taken, w.audio.values.contains("token-a") else { return [] }
            n.back = Folder(token: "token-b", from: MoveModelTests.b, file: .move)
            return [(n, [])]
        }
        let a = w.sources[ai]
        let own = rules == .now ? MovePlan.ownRemoval(a.state.map { _ in ledger(a) }) : a.state == .removing
        var m = marker(f)
        m.to = "default"
        let step = MovePlan.target(.incoming(m), folder: MoveModelTests.x, me: "default", callFolder: true, audio: [], ownRemoval: own, held: nil)
        guard step == .claim else { return [] }
        var v: [String] = []
        if let state = a.state, state != .done { v.append("rule 4: A takes in the id while its own move of it is \(state)") }
        n.aTookBack = true
        return [(n, v)]
    }

    // MARK: Rules

    func check(_ w: World) -> [String] {
        var v: [String] = []
        for s in w.sources where s.tracked {
            let inB = w.audio.contains { $0.value == s.token } && (w.status != .gone || w.goneAfterRemoval)
            let back = s.token == "token-a" && w.aTookBack
            if !s.has && !inB && !back { v.append("rule 1: \(s.name)'s meeting is in neither profile") }
        }
        return v
    }

    func run(_ starts: [World]) -> Found {
        var found = Found()
        var seen = Set<World>()
        var queue = starts
        while let w = queue.popLast() {
            guard seen.insert(w).inserted else { continue }
            found.violations.formUnion(check(w))
            for s in w.sources { if let st = s.state { found.ledgerStates.insert(st) } }
            for s in w.sources {
                switch s.part {
                case 1: found.markers.insert("half part")
                case 2: found.markers.insert("part without marker")
                case 3: found.markers.insert("part with marker")
                default: break
                }
            }
            if let f = w.incoming {
                switch f.file {
                case .move: found.markers.insert("move")
                case .cancelled: found.markers.insert("cancelled")
                case .claimed: found.markers.insert("claimed \(f.intake.map(\.rawValue) ?? "nil")")
                }
            } else {
                found.markers.insert("none")
            }
            for (n, v) in next(w) {
                found.violations.formUnion(v)
                queue.append(n)
            }
        }
        found.states = seen.count
        return found
    }

    /// The first profile's rule at 765e278, word for word.
    static func before(_ state: MoveOut.State, _ marker: MoveMarker.Look, part: Bool, target: MovePlan.Target) -> MovePlan.SourceStep {
        switch state {
        case .copying:
            return target == .gone ? .cancel(.targetGone) : .copy
        case .copied:
            if target == .gone { return .cancel(.targetGone) }
            if case .missing = marker { return part ? .publish : .copy }
            return .wait
        case .waiting:
            if case .claimed(let m) = marker {
                switch m.intake {
                case .taken?: return .remove
                case .refused?: return .cancel(.refusedUnreadable)
                default: break
                }
            }
            if target == .gone { return .cancel(.targetGone) }
            if case .missing = marker { return .cancel(.lost) }
            return .wait
        case .removing:
            return .remove
        case .cancelling:
            return .finishCancel(removeIncoming: true)
        case .done:
            if case .missing = marker { return .nothing }
            return .cleanUp(removeIncoming: true)
        }
    }

    /// The target's rule at 765e278: no address, and `taken` with no check of the files.
    static func beforeTarget(_ look: MoveMarker.Look, callFolder: Bool, audio: Set<String>) -> MovePlan.TargetStep {
        switch look {
        case .incoming: return .claim
        case .claimed(let m):
            switch m.intake {
            case nil: return .decide
            case .takingIn?:
                guard let f = m.finalID else { return .decide }
                switch (callFolder, audio.contains(f)) {
                case (true, false): return .takeIn(as: f)
                case (false, true): return .markTaken
                case (true, true): return .decide
                case (false, false): return .refuse(.notWhole)
                }
            default: return .nothing
            }
        default: return .nothing
        }
    }
}
