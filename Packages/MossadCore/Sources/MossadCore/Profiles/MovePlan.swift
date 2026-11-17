import Foundation

/// The next step of each side of a move, from what each side can see. Pure: the folders are read by the caller.
public enum MovePlan {
    /// `gone`: a profile that is not in the registry, is marked `removing`, or has no folder.
    public enum Target: Equatable, Sendable { case live, gone }

    public enum Cancel: String, Codable, Equatable, Sendable {
        case byOwner, targetGone, lost, refusedIDTaken, refusedUnreadable, refusedNotWhole, noRoom, copyFailed, backupFailed
    }

    public enum SourceStep: Equatable, Sendable { case copy, publish, wait, remove, cleanUp, cancel(Cancel), finishCancel, nothing }

    /// The first profile's next step. It removes its meeting only after the marker says `taken`, and a removal that
    /// started goes on whatever the target is now. `part`: `Incoming/<id>.part` is there.
    public static func source(_ state: MoveOut.State, marker: MoveMarker.Look, part: Bool, target: Target) -> SourceStep {
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
                case .refused?: return .cancel(cancel(for: m.refusal))
                default: break
                }
            }
            if target == .gone { return .cancel(.targetGone) }
            if case .missing = marker { return .cancel(.lost) }
            return .wait
        case .removing:
            return .remove
        case .cancelling:
            return .finishCancel
        case .done:
            if case .missing = marker { return .nothing }
            return .cleanUp
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

    /// The target's next step. `callFolder`: the prepared `call` folder is still in `Incoming/<id>`. `audio`: the folder
    /// names of this profile's `Audio`. `ownRemoval`: this profile still removes this id itself (a move back that came
    /// before its own removal ended): it waits.
    public static func target(_ look: MoveMarker.Look, callFolder: Bool, audio: Set<String>, ownRemoval: Bool) -> TargetStep {
        switch look {
        case .missing, .unknown:
            return .nothing
        case .incoming:
            return ownRemoval ? .wait : .claim
        case .claimed(let m):
            switch m.intake {
            case nil:
                return .decide
            case .takingIn?:
                guard let f = m.finalID else { return .decide }
                switch (callFolder, audio.contains(f)) {
                case (true, false): return .takeIn(as: f)
                case (false, true): return .markTaken
                case (true, true): return .decide
                case (false, false): return .refuse(.notWhole)
                }
            case .taken?, .refused?:
                return .nothing
            }
        }
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
