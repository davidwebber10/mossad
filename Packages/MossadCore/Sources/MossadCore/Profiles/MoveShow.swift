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
        /// A removal step that waits: "Try again".
        public let retries: Bool
        public init(text: String, cancels: Bool, held: Bool, retries: Bool = false) {
            self.text = text
            self.cancels = cancels
            self.held = held
            self.retries = retries
        }
    }

    /// The row's line of a meeting. `move`: this profile's ledger of it; `name`: the target's name, nil when it is not a
    /// live profile; `held`: why a move of a call marked during its recording ended, in this run of the app.
    public static func row(_ r: CallRecord, move: MoveOut?, name: String?, copied: Double?, reach: Reach, held: String?, now: Date,
                           me: String? = nil) -> Row? {
        if arriving(r, me: me) { return Row(text: MoveWords.arriving, cancels: false, held: false) }
        if let move, move.state != .done {
            let target = name ?? MoveWords.otherProfile
            switch move.state {
            case .waiting where move.targetWaits != nil:
                return Row(text: MoveWords.notFinished(target, move.targetWaits!), cancels: false, held: false)
            case .copying, .copied, .waiting:
                let waited = now.timeIntervalSince(move.started)
                if copied == nil, waited >= MoveRules.slowAfter, reach != .open {
                    return Row(text: MoveWords.slow(to: target, reach: reach), cancels: true, held: false)
                }
                return Row(text: MoveWords.row(to: target, waited: waited, copied: copied), cancels: true, held: false)
            case .cancelling:
                return Row(text: MoveWords.cancelling, cancels: false, held: false)
            case .removing where move.because != nil:
                return Row(text: MoveWords.removalWaits(to: target, because: move.because!), cancels: false, held: false, retries: true)
            case .removing, .done:
                return Row(text: MoveWords.row(to: target, waited: 0, copied: nil), cancels: false, held: false)
            }
        }
        guard r.moveTo != nil else { return nil }
        guard let name else { return Row(text: MoveWords.heldForGone, cancels: false, held: true) }
        if let held { return Row(text: MoveWords.held(held), cancels: false, held: true) }
        // A call marked during its recording with no move and no reason (a start that was refused, a crash that left it
        // failed): it waits for the owner, with "Process here", "Move to", and Delete.
        if r.status == .recorded || r.status == .failed { return Row(text: MoveWords.held(MoveWords.notStarted(name)), cancels: false, held: true) }
        return Row(text: MoveWords.row(to: name, waited: 0, copied: nil), cancels: false, held: false)
    }

    /// The sentence for a command that would change a meeting while its move waits; nil for a meeting with no mark.
    public static func refusesCommand(_ r: CallRecord, name: String?, me: String? = nil) -> String? {
        guard r.moveTo != nil else { return nil }
        if arriving(r, me: me) { return MoveWords.arriving }
        return name.map(MoveWords.moving(to:)) ?? MoveWords.heldForGone
    }

    /// In the target, until it is taken in, the meeting is marked with this profile's own id: it shows as arriving,
    /// takes no command, and does not open.
    public static func arriving(_ r: CallRecord, me: String?) -> Bool { me != nil && r.moveTo == me }

    /// The chat field of a meeting whose move waits is off, with this sentence, before any request is sent.
    public static func chatOff(_ r: CallRecord?, name: String?, me: String? = nil) -> String? {
        guard let r else { return nil }
        return refusesCommand(r, name: name, me: me)
    }

    /// The iPhone's chat field of a meeting that moves (its record carries the mark from the Mac): off before any
    /// request, with one sentence that names no profile.
    public static func phoneChatOff(_ r: CallRecord?) -> String? {
        r?.moveTo == nil ? nil : MoveWords.movingOnMac
    }

    /// The same rule for the store's own guard: a question about a meeting that moves gets this sentence, and no request.
    public static func phoneChatOff(about callID: String?, in records: [CallRecord]) -> String? {
        guard let callID else { return nil }
        return phoneChatOff(records.first { $0.id == callID })
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
        /// The meeting the line is about: a meeting's own page shows only its own lines.
        public private(set) var callID: String?

        /// The same line, about one meeting.
        public func about(_ id: String?) -> Line {
            var l = self
            l.callID = id
            return l
        }

        /// Shown on a page: the list and Calendar (no meeting) show every line; a meeting's page only its own.
        public func shows(on meeting: String?) -> Bool { meeting == nil || callID == meeting }

        public init(text: String, since: Date, lasts: TimeInterval) {
            self.text = text
            self.since = since
            self.lasts = lasts
        }

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
    public static func notStarted(_ target: String) -> String { "The move to “\(target)” has not started." }
    /// The panel's line under a choice kept from the call before as a guess.
    public static let keptGuess = "Kept from the call before. Change it if this is another call."
    public static let movingOnMac = "This meeting is moving to another profile on your Mac."
    public static let arriving = "Arriving from another profile…"
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
        // A reason that says it already (a guess kept from the call before) is the whole sentence.
        if reason.hasSuffix("until you choose.") { return reason }
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
    /// The tries reached the last wait step: from there it is said, not only logged.
    public static func gaveUp(tries: Int) -> Bool { tries >= waits.count }

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

    /// The other profile took the meeting in and a part after its file check fails again and again.
    public static func notFinished(_ target: String, _ waits: MoveMarker.TakeInWait) -> String {
        let why = switch waits {
        case .voices: "it cannot save the voices it learned from it yet."
        case .record: "it cannot save the meeting there yet."
        case .chats: "it cannot save the meeting's chats yet."
        case .points: "it cannot save the meeting's points yet."
        case .failed: "one step does not work yet."
        }
        return "“\(target)” took the meeting but has not finished: \(why) It tries again."
    }
}
