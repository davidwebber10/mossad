import Foundation

/// Which meeting may move, to which profile, and who may start a move. Pure.
public enum MoveRules {
    /// What the first profile sent of a meeting, from what the code keeps: the record and the usage log.
    public enum Sent: Equatable, Sendable { case nothing, live, inWork, all }

    /// A written or failed meeting was sent. A recorded one is in work when it has a transcription job, a finished
    /// track, a failed try, or a usage row of a transcription; it had only the live transcript when `live.json` is in
    /// its folder or the usage log has a live row for it. Else nothing is known to be sent.
    public static func sent(_ r: CallRecord, hasLiveFile: Bool, usage: [UsageEvent]) -> Sent {
        switch r.status {
        case .written, .failed: return .all
        case .transcribed, .identified, .summarized: return .inWork
        case .recording, .recorded:
            let mine = usage.filter { $0.callID == r.id }
            if r.transcriptionJobs?.isEmpty == false || r.meUtterances != nil || r.themUtterances != nil || r.attempts > 0
                || mine.contains(where: { $0.purpose == .transcription }) { return .inWork }
            if hasLiveFile || mine.contains(where: { $0.purpose == .live }) { return .live }
            return .nothing
        }
    }

    public enum Offer: Equatable, Sendable { case hidden, offer, moving(to: String), refused(String) }

    /// The "Move to" item of a meeting. `files`: the names in its call folder.
    public static func offer(_ r: CallRecord, busy: Bool, files: [String], usage: [UsageEvent], move: MoveOut?) -> Offer {
        if r.status == .recording { return .hidden }
        if let move, move.state != .done { return .moving(to: move.to) }
        if let to = r.moveTo { return .moving(to: to) }
        if r.isNotesOnly { return .refused(MoveWords.notesOnly) }
        let sent = sent(r, hasLiveFile: files.contains(LiveTranscript.fileName), usage: usage)
        if busy || MovedFiles.inWork(files) || r.platform == .unknown || sent == .inWork { return .refused(MoveWords.inWork) }
        return .offer
    }

    /// The live profiles other than the active one, in the registry's order; none with one profile.
    public static func targets(_ registry: ProfileRegistry, active: String) -> [Profile] {
        registry.live.filter { $0.id != active }
    }

    /// Only the foreground app of the real install starts a move: the full mode, a copy that may change the real
    /// registry, and a registry that was read whole.
    public static func mayMove(mode: RunMode, identity: AppIdentity, registry: ProfileRegistry.Loaded) -> Bool {
        mode == .full && identity.mayChangeRegistry && registry.state == .read
    }

    /// The target's folder: nil unless the registry was read whole, the profile is live, and its folder is a folder.
    public static func targetPaths(_ id: String, in registry: ProfileRegistry.Loaded, home: URL?) -> Paths? {
        guard registry.state == .read, let home, let profile = registry.registry.live.first(where: { $0.id == id }) else { return nil }
        let root = profile.rootURL(home: home)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return Paths(root: root)
    }

    /// The look at `Incoming` and `Moves`; the row's line after that long; how long a result and a refusal show.
    public static let look: TimeInterval = 15, slowAfter: TimeInterval = 60, resultShows: TimeInterval = 8, refusalShows: TimeInterval = 30
}

/// Every sentence of a move.
public enum MoveWords {
    public static let menu = "Move to", confirm = "Move", cancelMove = "Cancel move", processHere = "Process here"
    public static let notesOnly = "A meeting made from Gemini notes stays with its Google account."
    public static let inWork = "Mossad is working on this meeting. Move it when its notes are ready."
    public static let heldForGone = "This call was for a profile that is gone. Mossad does not process it until you choose."

    public static func title(_ meeting: String, to target: String) -> String { "Move “\(meeting)” to “\(target)”?" }

    public static func sent(_ sent: MoveRules.Sent, from active: String, to target: String) -> String {
        switch sent {
        case .all: "“\(active)” already sent this meeting to its transcription and notes services, and a move cannot take that back."
        case .live: "The live transcript of this call went to the transcription service of “\(active)”. Nothing else was sent."
        case .nothing: "As far as Mossad knows, nothing of this meeting was sent from “\(active)”. “\(target)” does all the work with its own keys."
        case .inWork: inWork
        }
    }

    public static func leaves(_ active: String) -> String {
        "The meeting leaves “\(active)” with its tasks, its chats, and what Mossad learned from it."
    }

    /// The meeting's row while it moves: the share copied, else after a while where it waits.
    public static func row(to target: String, waited: TimeInterval, copied: Double?) -> String {
        if let copied { return "Moving to \(target)… \(Int((copied * 100).rounded()))%" }
        if waited >= MoveRules.slowAfter { return "Moving to \(target)… It arrives when “\(target)” is next open." }
        return "Moving to \(target)…"
    }

    public static func moved(to target: String) -> String { "Moved to \(target)" }
    public static func tooLate(_ target: String) -> String { "“\(target)” has the meeting already." }

    /// Why a move ended without moving; nil for the owner's own Cancel.
    public static func refusal(_ why: MovePlan.Cancel, target: String) -> String? {
        switch why {
        case .byOwner: nil
        case .targetGone: "“\(target)” is no longer a profile. The meeting stays here."
        case .lost: "The copy in “\(target)” is gone. The meeting stays here."
        case .refusedIDTaken: "“\(target)” cannot take this meeting in. The meeting stays here."
        case .refusedUnreadable: "“\(target)” could not read this meeting. The meeting stays here."
        case .refusedNotWhole: "The copy in “\(target)” was not whole. The meeting stays here."
        case .noRoom: "There is not enough room on this Mac to move the meeting. Nothing was moved."
        case .copyFailed: "The copy did not match the meeting. Nothing was moved."
        case .backupFailed: "The recording is only in the backup, and Mossad could not get it. Nothing was moved."
        }
    }
}
