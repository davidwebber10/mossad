import Foundation

/// What the window app shows of a move: the menu of a meeting, its row, the line above the list, and the answers to
/// the owner's Cancel. Pure. With one profile no menu shows, and a meeting with no mark and no ledger has no line.
public enum MoveShow {
    /// The "Move to" items show only when there is another live profile.
    public static func menuShows(targets: [Profile]) -> Bool { !targets.isEmpty }

    /// Why a move waits, as far as the window app can know: the other profile's worker runs (`open`), stopped because
    /// that profile's setup is not done, cannot be reached (its folder or the registry does not read now), or does not
    /// run (it gave up, or is not started).
    public enum Reach: Equatable, Sendable { case open, notSetUp, unreachable, notRunning }

    public struct Row: Equatable, Sendable {
        public let text: String
        /// Cancel shows: the other profile cannot have claimed the copy yet.
        public let cancels: Bool
        /// The call waits for the owner: "Process here" and "Move to".
        public let held: Bool
        public init(text: String, cancels: Bool, held: Bool) {
            self.text = text
            self.cancels = cancels
            self.held = held
        }
    }

    /// The row's line of a meeting. `move`: this profile's ledger of it; `name`: the target's name, nil when it is not a
    /// live profile; `held`: why a move of a call marked during its recording ended, in this run of the app.
    public static func row(_ r: CallRecord, move: MoveOut?, name: String?, copied: Double?, reach: Reach, held: String?, now: Date) -> Row? {
        if let move, move.state != .done {
            let target = name ?? MoveWords.otherProfile
            switch move.state {
            case .copying, .copied, .waiting:
                let waited = now.timeIntervalSince(move.started)
                if copied == nil, waited >= MoveRules.slowAfter, reach != .open {
                    return Row(text: MoveWords.slow(to: target, reach: reach), cancels: true, held: false)
                }
                return Row(text: MoveWords.row(to: target, waited: waited, copied: copied), cancels: true, held: false)
            case .cancelling:
                return Row(text: MoveWords.cancelling, cancels: false, held: false)
            case .removing, .done:
                return Row(text: MoveWords.row(to: target, waited: 0, copied: nil), cancels: false, held: false)
            }
        }
        guard r.moveTo != nil else { return nil }
        guard let name else { return Row(text: MoveWords.heldForGone, cancels: false, held: true) }
        if let held { return Row(text: MoveWords.held(held), cancels: false, held: true) }
        return Row(text: MoveWords.row(to: name, waited: 0, copied: nil), cancels: false, held: false)
    }

    /// The sentence for a command that would change a meeting while its move waits; nil for a meeting with no mark.
    public static func refusesCommand(_ r: CallRecord, name: String?) -> String? {
        guard r.moveTo != nil else { return nil }
        return name.map(MoveWords.moving(to:)) ?? MoveWords.heldForGone
    }

    /// The chat field of a meeting whose move waits is off, with this sentence, before any request is sent.
    public static func chatOff(_ r: CallRecord?, name: String?) -> String? {
        guard let r else { return nil }
        return refusesCommand(r, name: name)
    }

    public enum Menu: Equatable, Sendable {
        case none
        /// "Move to ▸" with one item for each target id.
        case targets([String])
        case cancel
        case refused(String)
        /// "Process here", and "Move to ▸" each target.
        case held([String])
    }

    public static func menu(_ offer: MoveRules.Offer, record: CallRecord, targets: [Profile], held: Bool) -> Menu {
        if held, record.moveTo != nil { return .held(targets.map(\.id)) }
        guard menuShows(targets: targets) else { return .none }
        switch offer {
        case .hidden: return .none
        case .offer: return .targets(targets.map(\.id))
        case .moving: return .cancel
        case .refused(let words): return .refused(words)
        }
    }

    /// The one quiet line above the list: a result for 8 s, a refusal for 30 s. Text only.
    public struct Line: Equatable, Sendable {
        public let text: String
        public let since: Date
        public let lasts: TimeInterval

        public func shows(at now: Date) -> Bool { now.timeIntervalSince(since) < lasts }

        public static func moved(to target: String, at now: Date) -> Line {
            Line(text: MoveWords.moved(to: target), since: now, lasts: MoveRules.resultShows)
        }

        public static func refusal(_ text: String, at now: Date) -> Line {
            Line(text: text, since: now, lasts: MoveRules.refusalShows)
        }

        public static func cancel(_ answer: MoveSource.CancelAnswer, target: String, at now: Date) -> Line {
            switch answer {
            case .cancelled: Line(text: MoveWords.cancelled, since: now, lasts: MoveRules.resultShows)
            case .tooLate: refusal(MoveWords.tooLate(target), at: now)
            case .unreachable: refusal(MoveWords.unreachable, at: now)
            case .unreadable: refusal(MoveWords.ledgerUnreadable, at: now)
            }
        }
    }
}

extension MoveWords {
    public static let cancelling = "Cancelling the move…"
    public static let cancelled = "The move is cancelled. The meeting stays here."
    /// This profile's own record of the move does not read: the meeting stays marked and is not processed.
    public static let ledgerUnreadable = "Mossad cannot read how far this move got. The meeting stays here, and nothing was cancelled."
    /// The target's name when the registry does not have it now.
    public static let otherProfile = "the other profile"

    /// A move that waits past `MoveRules.slowAfter`, with the reason the app knows.
    public static func slow(to target: String, reach: MoveShow.Reach) -> String {
        switch reach {
        case .open: row(to: target, waited: MoveRules.slowAfter, copied: nil)
        case .notSetUp: "Moving to \(target)… “\(target)” is not set up yet. It arrives when its setup is done."
        case .unreachable: "Moving to \(target)… Mossad cannot reach “\(target)” now. It arrives when Mossad can."
        case .notRunning: "Moving to \(target)… “\(target)” is not running now. It arrives when “\(target)” is next open."
        }
    }

    /// A call marked during its recording whose move ended: the reason, and that it waits for the owner.
    public static func held(_ reason: String) -> String {
        let stays = " The meeting stays here."
        let base = reason.hasSuffix(stays) ? String(reason.dropLast(stays.count)) : reason
        return base + " Mossad does not process it until you choose."
    }
}

/// Review N2: how long a step of a move that failed waits before its next try. Pure: the caller gives the time.
public enum MoveRetry {
    /// After 1, 2, 3, and 4 or more failed tries. After one the next look tries (the look comes every 15 s).
    public static let waits: [TimeInterval] = [0, 60, 300, 1800]

    public static func wait(afterTries n: Int) -> TimeInterval { n <= 0 ? 0 : waits[min(n, waits.count) - 1] }

    /// True when the step may run now. No time of a last try ("Try again") is always due.
    public static func due(tries: Int, last: Date?, now: Date) -> Bool {
        guard tries > 0, let last else { return true }
        return now.timeIntervalSince(last) >= wait(afterTries: tries)
    }
}

extension MoveWords {
    /// A removal in this profile that waits after the other profile took the meeting in.
    public static func removalWaits(to target: String, because: MoveOut.Wait) -> String {
        let why = switch because {
        case .peopleNotReady: "and waits for the people list of this profile."
        case .shareNotSaved: "and waits to stop its share link."
        case .backupNotDone: "and waits to delete its backup copy."
        case .folderNotRemoved: "and waits to remove its recording folder."
        case .failed: "and one step did not work. It tries again."
        }
        return "Moved to \(target). Mossad still removes it here, \(why)"
    }

    public static let tryAgain = "Try again"
}
