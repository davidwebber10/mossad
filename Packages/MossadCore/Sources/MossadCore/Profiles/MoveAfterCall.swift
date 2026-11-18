import Foundation

/// "This call is for ▸ <profile>" while a call records. From the choice of another profile, nothing of the call goes
/// to a provider of this one: each send of a live call asks `allows` first, and the end of the call reads `atEnd`.
/// The choice is kept on the live call's record (`CallRecord.moveTo`), so a crash, a pause, and a resume keep it.
/// With one profile there is no row (`menu` is nil) and the choice is always `.here`.
public enum MoveAfterCall {
    public enum Choice: Equatable, Sendable {
        /// The active profile, as the call began.
        case here
        /// Another profile: its id.
        case other(String)
        /// Taken back during the call: processed here, and the live transcript stays off for the rest of the call.
        case backHere
        /// Kept from the call before as a guess (`Carry.guessed`): nothing is sent, and at its end the recording is held
        /// until the owner chooses.
        case guessed(String)

        /// The mark on the record for this choice.
        public var moveTo: String? {
            switch self {
            case .other(let id), .guessed(let id): id
            case .here, .backHere: nil
            }
        }
    }

    /// Every kind of request that a recording can cause between the choice and its end.
    public enum Send: String, CaseIterable, Sendable {
        /// The two live streams to the transcription service, also after a pause and a lost connection.
        case liveTranscript
        /// The small model's provisional title after about 5 minutes.
        case liveTitle
        /// The check of a point for next time that may have come up.
        case livePoints
        /// An answer of the live chat (the Chat tab and the quick panel), with its summary of the older lines.
        case liveChat
        /// `live.json` given by `current_call` to the app's chat and to other AI apps.
        case currentCall
        /// The short summary of the call's live chats a minute after it ends.
        case chatSummary
        /// The upload, the summary, and all that follows a written meeting.
        case pipeline
    }

    public static func allows(_ send: Send, _ choice: Choice) -> Bool {
        switch choice {
        case .here: true
        case .other, .guessed: false
        case .backHere: send == .chatSummary || send == .pipeline
        }
    }

    /// The choice that a record's mark says, after the call (or after a launch): `.backHere` is not kept.
    public static func choice(of moveTo: String?) -> Choice { moveTo.map(Choice.other) ?? .here }

    public static func liveOff(_ choice: Choice) -> LiveOffReason? {
        switch choice {
        case .here: nil
        case .other: .forOtherProfile
        case .backHere: .afterOtherProfile
        case .guessed: .maybeOtherProfile
        }
    }

    /// A guess set to this profile was never the owner's marked call: it is a call like any other (`.here`), and its live
    /// transcript starts. A guess set to any other profile is the owner's choice.
    public static func next(_ choice: Choice, picked profile: String, active: String) -> Choice {
        guard profile == active else { return .other(profile) }
        if case .guessed = choice { return .here }
        return choice == .here ? .here : .backHere
    }

    public struct Menu: Equatable, Sendable {
        public struct Row: Equatable, Sendable, Identifiable {
            public let id: String
            public let name: String
            public let color: ProfileColor
            public let chosen: Bool
        }

        public static let title = "This call is for"
        public let rows: [Row]
        public let note: String?
    }

    /// The panel's row: nil with fewer than two live profiles; else the live profiles in the registry's order.
    public static func menu(_ registry: ProfileRegistry, active: String, choice: Choice) -> Menu? {
        let live = registry.live
        guard live.count >= 2 else { return nil }
        let chosen: String? = switch choice {
        case .here, .backHere: active
        case .other(let id), .guessed(let id): id
        }
        let rows = live.map { Menu.Row(id: $0.id, name: $0.name, color: $0.color, chosen: $0.id == chosen) }
        let activeName = live.first { $0.id == active }?.name ?? registry.activeProfile.name
        let note: String? = switch choice {
        case .here: nil
        case .other(let id): live.first { $0.id == id }.map { "“\($0.name)” writes the notes. Nothing more of this call is sent from “\(activeName)”." }
            ?? LiveOffReason.forOtherProfile.text
        case .backHere: LiveOffReason.afterOtherProfile.text
        case .guessed: MoveWords.keptGuess
        }
        return Menu(rows: rows, note: note)
    }

    // MARK: A call that goes on as a new recording

    /// The recording that a choice belongs to, with what the detector knows at `.started`.
    public struct Call: Equatable, Sendable {
        public let callID: String
        public let platform: Platform
        /// The call app's bundle id; nil when it is not known (a room).
        public let bundleID: String?
        public let meetingID: String?
        public let start: Date

        public init(callID: String, platform: Platform, bundleID: String?, meetingID: String?, start: Date) {
            self.callID = callID
            self.platform = platform
            self.bundleID = bundleID
            self.meetingID = meetingID
            self.start = start
        }
    }

    /// How a new recording takes over the choice of the call before it. `sure`: the same link. `guessed`: no link to
    /// compare, the same call app, or the first part after a launch: nothing is sent, and at its end it is held.
    public enum Carry: Equatable, Sendable { case sure, guessed }

    /// The time in which a new recording may be the call before it going on. Not `MeetingMerge.continuationGap`: joining
    /// two recordings into one meeting must be strict; keeping a privacy choice must be generous.
    public static let carryWindow: TimeInterval = 900

    /// The owner's choice of a call that ended, kept for a new recording of the same call.
    public struct Kept: Equatable, Sendable {
        /// The part that ended last.
        public let call: Call
        /// The last link of the parts that carried the choice: a part with no link keeps the one before it.
        public let link: String?
        /// The owner's choice: another profile, or a take-back.
        public let choice: Choice
        public let end: Date
        /// Read back at a launch, or carried as a guess since one: the owner did not see the panel since.
        public let afterLaunch: Bool
        /// Every part that carried this choice, in order.
        public let parts: [String]

        public init(call: Call, link: String?, choice: Choice, end: Date, afterLaunch: Bool, parts: [String]) {
            self.call = call
            self.link = link
            self.choice = choice
            self.end = end
            self.afterLaunch = afterLaunch
            self.parts = parts
        }
    }

    /// What a part keeps when it ends: nothing for `.here`; a guess the owner left alone keeps the owner's choice of the
    /// part before, still a guess for the next part unless a link proves it.
    public static func keep(_ call: Call?, choice: Choice?, end: Date, from carried: Kept? = nil) -> Kept? {
        guard let call, let choice else { return nil }
        let link = call.meetingID ?? carried?.link
        let parts = (carried?.parts ?? []) + [call.callID]
        switch choice {
        case .here: return nil
        case .other, .backHere:
            return Kept(call: call, link: link, choice: choice, end: end, afterLaunch: false, parts: parts)
        case .guessed(let id):
            return Kept(call: call, link: link, choice: .other(id), end: end, afterLaunch: carried?.afterLaunch ?? false, parts: parts)
        }
    }

    /// The choice that a new recording takes over, and how. Never: two different links, two different call apps with no
    /// link to compare, or a start more than `carryWindow` after the end. A take-back carries only for sure; a guess of a
    /// take-back is a call like any other.
    public static func carry(_ kept: Kept?, to call: Call) -> (choice: Choice, kind: Carry)? {
        guard let kept, call.start.timeIntervalSince(kept.end) <= carryWindow else { return nil }
        let kind: Carry
        if let a = kept.link, let b = call.meetingID {
            guard a == b else { return nil }
            kind = kept.afterLaunch ? .guessed : .sure
        } else {
            guard let a = kept.call.bundleID, a == call.bundleID else { return nil }
            kind = .guessed
        }
        switch (kept.choice, kind) {
        case (.other(let id), .sure): return (.other(id), .sure)
        case (.other(let id), .guessed): return (.guessed(id), .guessed)
        case (.backHere, .sure): return (.backHere, .sure)
        default: return nil
        }
    }

    /// After a launch: the call marked for another profile that was recording when the app stopped (`recovered`: its
    /// audio length says nothing of a pause, so it counts from the launch), or that ended within `carryWindow` before
    /// it. A carry after a launch is always a guess: the owner did not see the panel since.
    public static func kept(from records: [CallRecord], recovered: Set<String>, now: Date) -> Kept? {
        let marked = records.compactMap { r -> (CallRecord, Date)? in
            guard r.moveTo != nil, r.status == .recorded || (r.status == .failed && r.failedStep == .recorded) else { return nil }
            if recovered.contains(r.id) { return (r, now) }
            return now.timeIntervalSince(r.end) <= carryWindow ? (r, r.end) : nil
        }
        guard let last = marked.max(by: { $0.1 < $1.1 }), let to = last.0.moveTo else { return nil }
        let (r, end) = last
        let call = Call(callID: r.id, platform: r.platform, bundleID: r.bundleID, meetingID: r.meetingID, start: r.start)
        return Kept(call: call, link: r.meetingID, choice: .other(to), end: end, afterLaunch: true, parts: [r.id])
    }

    /// The earlier parts that a take-back in a part carried for sure cancels, so that the whole call is processed here:
    /// each part of the same carried call whose move the target has not claimed (copying, copied, or waiting; or marked
    /// with no move yet). A part whose move went further stays with the target.
    public static func takeBackCancels(_ parts: [String], moves: [String: MoveOut.State], marked: Set<String>) -> [String] {
        parts.filter { id in
            if let state = moves[id] { return [.copying, .copied, .waiting].contains(state) }
            return marked.contains(id)
        }
    }

    /// The carry of the app: the choice kept from the part that ended, read back at a launch, decided at each start
    /// before anything is sent, and kept again at the end. Pure, so its order is tested.
    public struct Book: Equatable, Sendable {
        public private(set) var kept: Kept?
        /// The part that records now, with the choice it carried from.
        public private(set) var call: Call?
        public private(set) var from: Kept?
        public private(set) var kind: Carry?
        /// The id of the last call whose carry was decided: `startLive` asserts it.
        public private(set) var decided: String?
        /// The part that ended last and its own choice then (a guess left alone stays a guess), for `endOfCall`.
        public private(set) var endedID: String?
        public private(set) var endedChoice: Choice?

        public init() {}

        public mutating func launched(_ records: [CallRecord], recovered: Set<String>, now: Date) {
            kept = MoveAfterCall.kept(from: records, recovered: recovered, now: now)
        }

        /// At `.started`, from the detector's own values. Any other call forgets the kept choice.
        public mutating func started(_ call: Call) -> (choice: Choice, kind: Carry)? {
            let carried = MoveAfterCall.carry(kept, to: call)
            from = carried == nil ? nil : kept
            kind = carried?.kind
            kept = nil
            self.call = call
            decided = call.callID
            return carried
        }

        /// At the end of the part, with its choice as it is then. A second end of the same call (the detector's, after
        /// Stop) keeps what the first one kept.
        public mutating func ended(choice: Choice?, at end: Date) {
            guard let call else { return }
            kept = MoveAfterCall.keep(call, choice: choice, end: end, from: from)
            endedID = call.callID
            endedChoice = choice
            self.call = nil
            from = nil
            kind = nil
        }

        /// The kept choice of a call that ended, for the end's own read of the latest choice.
        public func keptChoice(of callID: String) -> Choice? {
            endedID == callID ? endedChoice : nil
        }
    }

    /// What the choice of another profile stops at once, in the same turn as the choice: the streams that are open, the
    /// live file that `current_call` reads, and the live chat's answer in flight. Every other send asks `allows` before
    /// it starts. A take-back starts nothing again.
    public enum Stop: Equatable, Hashable, Sendable { case liveStreams, liveFile, liveChatAnswer }

    public static func stops(_ choice: Choice) -> Set<Stop> {
        switch choice {
        case .other, .guessed: [.liveStreams, .liveFile, .liveChatAnswer]
        case .here, .backHere: []
        }
    }

    /// The record at the end of the call with the owner's latest choice: a choice made in the same instant as the end
    /// can miss the recorder's write, and the choice in memory is the last word. Nil (no choice in memory) keeps the
    /// record as it is.
    public static func settled(_ record: CallRecord, latest: Choice?) -> CallRecord {
        guard let latest else { return record }
        var r = record
        r.moveTo = latest.moveTo
        return r
    }

    /// The calls marked during their recording whose move starts at a look: not the call that records, not one with a
    /// move, not one held for the owner (its reason kept), also at the first look after a launch, and not one whose cut
    /// by its marks is still to be decided (`CutPlan.waits`): its parts would each be held.
    public static func startsAtLook(_ records: [CallRecord], moving: Set<String>, held: Set<String>, recording: String?,
                                    targets: [String]) -> [(callID: String, to: String)] {
        records.compactMap { r in
            guard r.status == .recorded, r.moveTo != nil, r.id != recording, !moving.contains(r.id), !held.contains(r.id), !CutPlan.waits(r),
                  case .move(let to) = atEnd(r, targets: targets) else { return nil }
            return (r.id, to)
        }
    }

    /// After a start of a move after the call: only a start looks again at once; a refusal waits for the owner, so a
    /// cause that lasts never makes a loop.
    public static func looksAgain(after start: MoveSource.Start) -> Bool { start == .started }

    public enum AtEnd: Equatable, Sendable { case process, move(to: String), hold, nothing }

    /// At the end of a call. Nil (skipped, discarded, or too short to keep): nothing, and the mark went with the call.
    /// No mark: processed here. A mark for a live target: it moves as "recorded". Else it waits for the owner.
    /// The end with the owner's latest choice: a guess is held (never moved, never processed) until the owner chooses.
    public static func atEnd(_ record: CallRecord?, latest: Choice?, targets: [String]) -> AtEnd {
        if case .guessed = latest { return record == nil ? .nothing : .hold }
        return atEnd(record.map { settled($0, latest: latest) }, targets: targets)
    }

    public static func atEnd(_ record: CallRecord?, targets: [String]) -> AtEnd {
        guard let record else { return .nothing }
        guard let to = record.moveTo else { return .process }
        return targets.contains(to) ? .move(to: to) : .hold
    }
}
