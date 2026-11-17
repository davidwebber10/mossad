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

    public enum AtEnd: Equatable, Sendable { case process, move(to: String), hold, nothing }

    /// At the end of a call. Nil (skipped, discarded, or too short to keep): nothing, and the mark went with the call.
    /// No mark: processed here. A mark for a live target: it moves as "recorded". Else it waits for the owner.
    public static func atEnd(_ record: CallRecord?, targets: [String]) -> AtEnd {
        guard let record else { return .nothing }
        guard let to = record.moveTo else { return .process }
        return targets.contains(to) ? .move(to: to) : .hold
    }
}
