import Foundation

/// The next step of each side of a move, from what each side can see. Pure: the folders are read by the caller.
public enum MovePlan {
    /// `gone`: the registry was read whole, and the profile is not in it or is marked `removing`. `unknown`: the registry
    /// could not be read whole, or the profile's folder is not there now: nothing is decided from it.
    public enum Target: Equatable, Sendable { case live, gone, unknown }

    public enum Cancel: String, Codable, Equatable, Sendable {
        case byOwner, targetGone, lost, refusedIDTaken, refusedUnreadable, refusedNotWhole, noRoom, copyFailed, backupFailed
    }

    public enum SourceStep: Equatable, Sendable {
        case copy, publish, markWaiting, wait, remove
        /// The removal ended: remove `Incoming/<id>` when it is this move's and the target holds the meeting, then save `done`.
        case cleanUp(removeIncoming: Bool)
        case cancel(Cancel)
        /// Take this move's marker back (`move.json` to `cancelled.json`) before anything of it is removed.
        case takeBack
        /// The end of a cancel: `Incoming/<id>` (only when the flag says so), this move's part, the mark, the ledger last.
        case finishCancel(removeIncoming: Bool)
        case nothing
    }

    private enum Seen { case missing, unknown, foreign, cancelledMine, incoming(MoveMarker), claimed(MoveMarker) }

    private static func seen(_ look: MoveMarker.Look, _ out: MoveOut) -> Seen {
        switch look {
        case .missing: return .missing
        case .unknown: return .unknown
        case .cancelled(let m): return m.map { $0.isMine(of: out) } == true ? .cancelledMine : (m == nil ? .unknown : .foreign)
        case .incoming(let m): return m.isMine(of: out) ? .incoming(m) : .foreign
        case .claimed(let m): return m.isMine(of: out) ? .claimed(m) : .foreign
        }
    }

    /// The first profile's next step. It removes its meeting only while the target is live and the marker of this very
    /// move says the target took it in and checked every file. A removal that started goes on whatever the target is
    /// now. A marker of another move is never acted on. `part`: this move's own part is there, whole, with its marker.
    public static func source(_ out: MoveOut, marker: MoveMarker.Look, part: Bool, target: Target) -> SourceStep {
        let s = seen(marker, out)
        switch out.state {
        case .copying:
            switch target {
            case .live: return .copy
            case .gone: return .cancel(.targetGone)
            case .unknown: return .wait
            }
        case .copied:
            if target == .gone { return .cancel(.targetGone) }
            if target == .unknown { return .wait }
            switch s {
            case .missing: return part ? .publish : .copy
            case .incoming, .claimed: return .markWaiting
            case .cancelledMine: return .cancel(.byOwner)
            case .foreign, .unknown: return .wait
            }
        case .waiting:
            if case .claimed(let m) = s, m.intake == .refused { return .cancel(cancel(for: m.refusal)) }
            if case .cancelledMine = s { return .cancel(.byOwner) }
            // A profile that is gone or `removing` holds nothing, whatever its marker says.
            if target == .gone { return .cancel(.targetGone) }
            if target == .unknown { return .wait }
            switch s {
            case .claimed(let m) where m.heldWhole: return .remove
            case .missing: return .cancel(.lost)
            default: return .wait
            }
        case .removing:
            guard out.nextStep == nil else { return .remove }
            if case .claimed(let m) = s, m.intake == .taken { return .cleanUp(removeIncoming: true) }
            return .cleanUp(removeIncoming: false)
        case .cancelling:
            // A target out of reach may still hold this move's `move.json`: nothing ends before it is seen again. A
            // marker that does not read may be B's claim of that moment: nothing ends on it either.
            if target == .unknown || marker == .unknown { return .wait }
            switch s {
            case .incoming: return .takeBack
            case .claimed(let m):
                switch m.intake {
                case .refused?: return .finishCancel(removeIncoming: true)
                case .taken?: return .finishCancel(removeIncoming: false)
                default: return .wait
                }
            case .cancelledMine: return .finishCancel(removeIncoming: true)
            case .missing, .foreign, .unknown: return .finishCancel(removeIncoming: false)
            }
        case .done:
            if case .claimed(let m) = s, m.intake == .taken { return .cleanUp(removeIncoming: true) }
            return .nothing
        }
    }

    /// A refusal with no reason this build knows is read as "could not read".
    private static func cancel(for refusal: MoveMarker.Refusal?) -> Cancel {
        switch refusal {
        case .idTaken?: .refusedIDTaken
        case .notWhole?: .refusedNotWhole
        case .unreadable?, nil: .refusedUnreadable
        }
    }

    public enum TargetStep: Equatable, Sendable { case claim, decide, takeIn(as: String), markTaken, refuse(MoveMarker.Refusal), wait, nothing }

    /// The target's next step for `Incoming/<folder>`. It acts only on a marker addressed to it (`me`) for that folder's
    /// id. `callFolder`: the prepared `call` folder is still in `Incoming/<id>`. `audio`: the folder names of this
    /// profile's `Audio`. `ownRemoval`: this profile has its own move of this id that is not done (`ownRemoval(_:)`): it
    /// waits. `held`: the files in `Audio/<final id>` match the marker's list (`held(_:found:)`); nil when not read yet.
    public static func target(_ look: MoveMarker.Look, folder: String, me: String, callFolder: Bool, audio: Set<String>, ownRemoval: Bool,
                              held: Bool?) -> TargetStep {
        switch look {
        case .missing, .unknown, .cancelled:
            return .nothing
        case .incoming(let m):
            guard m.to == me, m.callID == folder else { return .nothing }
            return ownRemoval ? .wait : .claim
        case .claimed(let m):
            guard m.to == me, m.callID == folder else { return .nothing }
            switch m.intake {
            case nil:
                return .decide
            case .takingIn?:
                guard let f = m.finalID else { return .decide }
                switch (callFolder, audio.contains(f)) {
                case (true, false): return .takeIn(as: f)
                case (false, true):
                    switch held {
                    case true?: return .markTaken
                    case false?: return .refuse(.notWhole)
                    case nil: return .wait
                    }
                case (true, true): return .decide
                case (false, false): return .refuse(.notWhole)
                }
            case .taken?, .refused?:
                return .nothing
            }
        }
    }

    /// This profile still has its own move of this id that is not done: a take-in of the same id waits for it, so the
    /// removal of the old meeting never forgets what the new one taught.
    public static func ownRemoval(_ out: MoveOut?) -> Bool {
        out.map { $0.state != .done } ?? false
    }

    /// The files in `Audio/<final id>` against the marker's list: every one, with its size and hash. `found` is keyed
    /// by the marker's paths.
    public static func held(_ files: [MoveMarker.File], found: [String: (size: Int64, sha256: String)]) -> Bool {
        !files.isEmpty && files.count == found.count && files.allSatisfy { f in found[f.path].map { $0.size == f.size && $0.sha256 == f.sha256 } ?? false }
    }

    /// The id a meeting gets here: its own, else `<id>-moved`; nil when both are taken. `taken` is the folder names of
    /// this profile's `Audio` and every id that left it (`MoveOut.leftIDs`).
    public static func finalID(_ id: String, taken: Set<String>) -> String? {
        if !taken.contains(id) { return id }
        let moved = id + "-moved"
        return taken.contains(moved) ? nil : moved
    }

    /// The target's decision after its claim.
    public static func decide(record: CallRecord?, sizesMatch: Bool, id: String, taken: Set<String>)
        -> (intake: MoveMarker.Intake, finalID: String?, refusal: MoveMarker.Refusal?) {
        guard let record, record.platform != .unknown else { return (.refused, nil, .unreadable) }
        guard sizesMatch else { return (.refused, nil, .notWhole) }
        guard let f = finalID(id, taken: taken) else { return (.refused, nil, .idTaken) }
        return (.takingIn, f, nil)
    }
}
