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

        /// The mark on the record for this choice.
        public var moveTo: String? {
            if case .other(let id) = self { return id }
            return nil
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
        case .other: false
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
        }
    }

    public static func next(_ choice: Choice, picked profile: String, active: String) -> Choice {
        guard profile == active else { return .other(profile) }
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
        case .other(let id): id
        }
        let rows = live.map { Menu.Row(id: $0.id, name: $0.name, color: $0.color, chosen: $0.id == chosen) }
        let activeName = live.first { $0.id == active }?.name ?? registry.activeProfile.name
        let note: String? = switch choice {
        case .here: nil
        case .other(let id): live.first { $0.id == id }.map { "“\($0.name)” writes the notes. Nothing more of this call is sent from “\(activeName)”." }
            ?? LiveOffReason.forOtherProfile.text
        case .backHere: LiveOffReason.afterOtherProfile.text
        }
        return Menu(rows: rows, note: note)
    }

    // MARK: A call that goes on as a new recording

    /// The recording that a choice belongs to.
    public struct Call: Equatable, Sendable {
        public let callID: String
        public let platform: Platform
        public let meetingID: String?
        public let start: Date

        public init(callID: String, platform: Platform, meetingID: String?, start: Date) {
            self.callID = callID
            self.platform = platform
            self.meetingID = meetingID
            self.start = start
        }
    }

    /// The owner's choice of a call that ended, kept for the new recording of the same call (the microphone stopped for
    /// a moment, a quit, a crash). Only a choice is kept: `.here` keeps nothing.
    public struct Kept: Equatable, Sendable {
        public let call: Call
        public let choice: Choice
        public let end: Date
    }

    public static func keep(_ call: Call?, choice: Choice?, end: Date) -> Kept? {
        guard let call, let choice, choice != .here else { return nil }
        return Kept(call: call, choice: choice, end: end)
    }

    /// The choice that a new recording takes over: the kept one when the new recording is the same meeting by the rule
    /// that joins two recordings (`MeetingMerge.continues`: the same link, within the gap) on the same platform.
    public static func carried(_ kept: Kept?, to call: Call) -> Choice? {
        guard let kept, kept.call.platform == call.platform,
              MeetingMerge.continues(.init(meetingID: kept.call.meetingID, start: kept.call.start, end: kept.end),
                                     .init(meetingID: call.meetingID, start: call.start, end: call.start)) else { return nil }
        return kept.choice
    }

    /// After a launch: the choice of the call marked during its recording that ended last, while its gap lasts. A
    /// take-back is not on the record, so only another profile is read back.
    public static func kept(from records: [CallRecord], now: Date) -> Kept? {
        let marked = records.filter { r in
            r.moveTo != nil && (r.status == .recorded || (r.status == .failed && r.failedStep == .recorded))
                && now.timeIntervalSince(r.end) < MeetingMerge.continuationGap
        }
        guard let r = marked.max(by: { $0.end < $1.end }), let to = r.moveTo else { return nil }
        return Kept(call: Call(callID: r.id, platform: r.platform, meetingID: r.meetingID, start: r.start), choice: .other(to), end: r.end)
    }

    /// What the choice of another profile stops at once, in the same turn as the choice: the streams that are open, the
    /// live file that `current_call` reads, and the live chat's answer in flight. Every other send asks `allows` before
    /// it starts. A take-back starts nothing again.
    public enum Stop: Equatable, Hashable, Sendable { case liveStreams, liveFile, liveChatAnswer }

    public static func stops(_ choice: Choice) -> Set<Stop> {
        if case .other = choice { return [.liveStreams, .liveFile, .liveChatAnswer] }
        return []
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
    /// move, and not one held for the owner (its reason kept), also at the first look after a launch.
    public static func startsAtLook(_ records: [CallRecord], moving: Set<String>, held: Set<String>, recording: String?,
                                    targets: [String]) -> [(callID: String, to: String)] {
        records.compactMap { r in
            guard r.status == .recorded, r.moveTo != nil, r.id != recording, !moving.contains(r.id), !held.contains(r.id),
                  case .move(let to) = atEnd(r, targets: targets) else { return nil }
            return (r.id, to)
        }
    }

    public enum AtEnd: Equatable, Sendable { case process, move(to: String), hold, nothing }

    /// At the end of a call. Nil (skipped, discarded, or too short to keep): nothing, and the mark went with the call.
    /// No mark: processed here. A mark for a live target: it moves as "recorded". Else it waits for the owner.
    public static func atEnd(_ record: CallRecord?, targets: [String]) -> AtEnd {
        guard let record else { return .nothing }
        guard let to = record.moveTo else { return .process }
        return targets.contains(to) ? .move(to: to) : .hold
    }
}
