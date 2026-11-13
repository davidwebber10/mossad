import CoreGraphics
import Foundation

/// Why a call that records has no live transcript, and where in Settings the owner can change it.
public enum LiveOffReason: String, Equatable, Sendable {
    case setting, noKey, lowData

    /// The line the live chat's prompt and the Chat tab use.
    public var text: String {
        switch self {
        case .setting: "Live transcript is off in Settings."
        case .noKey: "Live transcript needs an AssemblyAI key."
        case .lowData: "Live transcript is off on a network in Low Data Mode."
        }
    }

    /// The quick panel's words in place of the chat.
    public var panelText: String {
        let rest = "so Mossad cannot answer during the call. The recording is safe, and the full notes come after the call."
        return switch self {
        case .setting: "The live transcript is off, \(rest)"
        case .noKey: "The live transcript needs an AssemblyAI key, \(rest)"
        case .lowData: "The live transcript is off on a network in Low Data Mode, \(rest)"
        }
    }

    /// The Settings page that turns it on; nil when no setting does (a network in Low Data Mode).
    public var fix: LiveOffFix? {
        switch self {
        case .setting: .recordingSettings
        case .noKey: .aiSettings
        case .lowData: nil
        }
    }
}

public enum LiveOffFix: Equatable, Sendable {
    case recordingSettings, aiSettings

    public var label: String {
        switch self {
        case .recordingSettings: "Turn on…"
        case .aiSettings: "Add a key…"
        }
    }
}

/// What the quick panel shows.
public enum AskPanelMode: Equatable, Sendable {
    /// The chat of the call that records now.
    case call(String)
    /// The call records with no live transcript: the reason in place of the chat.
    case noTranscript(String, LiveOffReason)
    /// The call the panel showed ended while it was open.
    case ended(String)
    /// No call: a chat about all meetings.
    case quick

    public var callID: String? {
        switch self {
        case .call(let id), .noTranscript(let id, _), .ended(let id): id
        case .quick: nil
        }
    }
}

public enum AskPanelRules {
    /// `shownCall`: the call the panel showed since it last opened. It says the call ended only while it stays open;
    /// the next open is the quick chat.
    public static func mode(recording: String?, liveOff: LiveOffReason?, shownCall: String?) -> AskPanelMode {
        if let recording { return liveOff.map { .noTranscript(recording, $0) } ?? .call(recording) }
        if let shownCall { return .ended(shownCall) }
        return .quick
    }
}

/// A quick question in the panel: the Chat tab's chip, and whether it is drawn in the accent.
public struct AskPanelChip: Equatable, Sendable, Identifiable {
    public var label: String
    public var question: String
    public var accent = false
    public var id: String { question }
}

/// The panel's quick questions: the live Chat tab's rules, with the number of open questions for the owner in
/// the accent, and without the question just asked.
public enum AskPanelChips {
    static let forMe = "Questions for me"

    public static func chips(_ entries: [LiveEntry], owner: String, openQuestions: Int, openPoints: Int = 0, lastAsked: String?) -> [AskPanelChip] {
        LiveChips.chips(entries, owner: owner, openQuestions: openQuestions, openPoints: openPoints)
            .filter { $0.question != lastAsked && $0.label != lastAsked }
            .map { chip in
                chip.label == forMe
                    ? AskPanelChip(label: "\(forMe) (\(openQuestions))", question: chip.question, accent: true)
                    : AskPanelChip(label: chip.label, question: chip.question)
            }
    }
}

extension AskPanelChips {
    /// How long the chip of the question just asked stays hidden.
    static let hideFor: TimeInterval = 120

    /// The newest question, while it was asked just now; nil for an older one or one with no time.
    public static func recentQuestion(_ messages: [ChatMessage], now: Date) -> String? {
        guard let last = messages.last(where: { $0.role == .user }), let asked = last.asked,
              now.timeIntervalSince(asked) < hideFor else { return nil }
        return last.text
    }
}

/// The quick panel's frame: its content's height, never less than the header, the field, and the keys, grown up
/// from the bottom edge where the field is, and moved down only to stay on the screen.
/// The owner's points take their height from the thread, so the panel's tallest size stays `limit` and the field
/// stays where it is.
public enum AskPanelSizing {
    public static let width: CGFloat = 640
    static let header: CGFloat = 44, field: CGFloat = 56, footer: CGFloat = 32, chips: CGFloat = 46
    /// The thread's tallest, with no points row; then it scrolls.
    public static let threadLimit: CGFloat = 452
    /// The collapsed "Your points" row, and the open checklist's tallest; past it the checklist scrolls.
    public static let pointsRow: CGFloat = 36, pointsMax: CGFloat = 220
    /// The panel's tallest.
    public static var limit: CGFloat { header + threadLimit + chips + field + footer }

    public static func minimum(chips withChips: Bool) -> CGFloat {
        header + field + footer + (withChips ? chips : 0)
    }

    /// The points row's height as shown: its content up to `pointsMax`.
    public static func points(content: CGFloat) -> CGFloat { min(max(0, content), pointsMax) }

    /// The thread's tallest beside a points row of this height: the thread gives way first.
    public static func threadMax(points content: CGFloat) -> CGFloat {
        max(0, threadLimit - points(content: content))
    }

    public static func frame(content: CGFloat?, minimum: CGFloat, bottomLeft: CGPoint, visible: CGRect) -> CGRect {
        let height = min(max(content ?? 0, minimum), visible.height)
        var y = bottomLeft.y
        if y + height > visible.maxY { y = visible.maxY - height }
        y = max(y, visible.minY)
        return CGRect(x: bottomLeft.x, y: y, width: width, height: height)
    }
}

/// What a chat does after an answer: the question that waited goes next only after a good answer while its call
/// still records; else it goes back to the field, so a failed answer keeps its error and its Retry.
public enum ChatRunRules {
    public enum Next: Equatable, Sendable {
        case nothing, send(String), toField(String)
    }

    public static func next(queued: String?, failed: Bool, stopped: Bool, callRecords: Bool) -> Next {
        guard let queued else { return .nothing }
        if failed && !stopped || !callRecords { return .toField(queued) }
        return .send(queued)
    }

    /// A stopped first question leaves a chat with nothing in it: it goes.
    public static func removesChat(messagesLeft: Int) -> Bool { messagesLeft == 0 }
}

/// One line of the live transcript under a time in an answer.
public struct LivePeekLine: Equatable, Sendable, Identifiable {
    public var id: String
    public var time: TimeInterval
    public var name: String
    public var text: String
    /// The line the time points at.
    public var marked: Bool

    /// "38:41", or "1:02:03" from an hour.
    public var clock: String { Self.clock(time) }

    public static func clock(_ time: TimeInterval) -> String {
        let t = Int(max(0, time))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }
}

/// The live transcript at a moment of an answer: the line there and one line each side, with the names the live
/// transcript shows.
public enum LivePeek {
    public static func lines(_ transcript: LiveTranscript, lines: [LiveTranscript.Line], at time: TimeInterval,
                             owner: String, room: Bool) -> [LivePeekLine] {
        guard let i = ChatMoment.index(at: time, in: lines.map(\.time)) else { return [] }
        return (max(0, i - 1)...min(lines.count - 1, i + 1)).map { j in
            let line = lines[j]
            return LivePeekLine(id: line.id, time: line.time, name: name(of: line, in: transcript, owner: owner, room: room),
                                text: line.text, marked: j == i)
        }
    }

    /// You, a voice's first name once the voice library knows it, else its letter ("Speaker A2" in a later stream
    /// session), else the call or the room.
    public static func name(of line: LiveTranscript.Line, in transcript: LiveTranscript, owner: String, room: Bool) -> String {
        guard line.source == .them else { return "You" }
        if let name = line.speakerKey.flatMap({ transcript.names[$0] }) {
            return name == owner ? "You" : String(name.split(separator: " ").first ?? "")
        }
        if let letter = line.speaker { return LiveTranscript.label(letter, session: line.session) }
        return room ? "Room" : "Call"
    }
}

/// The panel's chat when no call records continues until the owner starts a new one or a call starts.
public enum QuickChatRule {
    public static func continues(_ chat: Chat?, lastCallStart: Date?) -> Bool {
        guard let chat, chat.callID == nil else { return false }
        guard let lastCallStart else { return true }
        return chat.updated > lastCallStart
    }
}

/// A quiet line before a question that came well after the one before it, with that earlier question's age, so
/// the owner who comes back sees which part is older.
public enum ChatDividers {
    static let gap: TimeInterval = 300

    /// The line to show before each question, by its id.
    public static func lines(_ messages: [ChatMessage], now: Date) -> [UUID: String] {
        var out: [UUID: String] = [:]
        var previous: Date?
        for m in messages where m.role == .user {
            if let asked = m.asked, let previous, asked.timeIntervalSince(previous) >= gap {
                out[m.id] = age(now.timeIntervalSince(previous))
            }
            previous = m.asked
        }
        return out
    }

    static func age(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        if minutes < 60 { return "Asked \(minutes) \(minutes == 1 ? "minute" : "minutes") ago" }
        let hours = minutes / 60
        return "Asked \(hours) \(hours == 1 ? "hour" : "hours") ago"
    }
}

/// When the quick panel may take the keyboard: only when the owner opened it (the shortcut or the menu). A panel
/// shown without the keyboard (a preview) never becomes key, on any open, re-open, or click, and never focuses its
/// field. A change that Mossad makes (a call that starts or ends, the share cover, a new height) keeps how the panel
/// was opened and never gives it the keyboard.
public enum AskPanelKeys {
    public enum Show: Sendable { case shortcut, menu, preview }
    public enum Opened: Equatable, Sendable { case byOwner, withoutKeyboard }
    public enum Change: Sendable { case callStarted, callEnded, shareCover, resized }

    public static func opened(by action: Show) -> Opened {
        switch action {
        case .shortcut, .menu: .byOwner
        case .preview: .withoutKeyboard
        }
    }

    public static func canBecomeKey(_ opened: Opened?) -> Bool { opened == .byOwner }

    public static func after(_ change: Change, opened: Opened?) -> Opened? { opened }

    public static func focusesField(_ opened: Opened?, visible: Bool) -> Bool { visible && opened == .byOwner }
}
