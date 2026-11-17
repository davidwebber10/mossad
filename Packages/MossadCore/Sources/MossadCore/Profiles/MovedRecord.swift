import Foundation

/// The record and the chats that leave a profile, and the status a moved record arrives with. Pure.
public enum MovedRecord {
    public enum Rule: String, Sendable { case kept, changed, cleared }

    /// Every stored field of `CallRecord` (its JSON key) and what a move does with it. A field with no rule fails
    /// `testEveryFieldOfARecordHasARule`, which lists the fields by reflection.
    public static let fields: [String: Rule] = {
        var f: [String: Rule] = [:]
        // The meeting itself. Names are labels. The target sets `id` and `status` when it takes the folder in.
        // `mutedAudioPending` travels: the silence is still to be written before anything is sent.
        for k in ["id", "platform", "bundleID", "start", "end", "status", "failedStep", "meetingID", "calendarTitle", "generatedTitle",
                  "customTitle", "plannedStart", "plannedEnd", "attendees", "calendarSeriesID", "utterances", "meUtterances",
                  "themUtterances", "speakerNames", "unknownSpeakers", "speakerEmbeddings", "speakerSamples", "fromInvite", "summary",
                  "topics", "kind", "tags", "tagsSetByOwner", "summaryVersion", "hasOutcomes", "decisions", "decisionTimes", "headline",
                  "parts", "markers", "summaryMissing", "speakersExpected", "muteSpans", "mutedAudioPending", "screens", "screenGaps",
                  "deletedScreens", "source"] { f[k] = .kept }
        // An id of the first profile's people goes; the name and the address stay. `moveTo` is the target's id.
        for k in ["invitees", "organizer", "actionItems", "personHint", "moveTo"] { f[k] = .changed }
        // Ids; a file of the first profile (an absolute path: the target would delete that note); its backup; a job in
        // its provider's account; a document of its Google account; the count and the words of its failed tries.
        for k in ["speakerPeople", "markdownPath", "cloudKey", "cloudSize", "cloudBackend", "cloudServer", "cloudHash", "cloudLeftovers",
                  "transcriptionJobs", "gemini", "attempts", "nextAttempt", "failureReason"] { f[k] = .cleared }
        return f
    }()

    /// The record as it leaves for `target`.
    public static func prepared(_ r: CallRecord, to target: String) -> CallRecord {
        var m = PersonReferences.withoutIDs(r)
        m.organizer?.personID = nil
        m.personHint?.personID = nil
        m.moveTo = target
        m.markdownPath = nil
        m.cloudKey = nil
        m.cloudSize = nil
        m.cloudBackend = nil
        m.cloudServer = nil
        m.cloudHash = nil
        m.cloudLeftovers = nil
        m.transcriptionJobs = nil
        m.gemini = nil
        m.attempts = 0
        m.nextAttempt = nil
        m.failureReason = nil
        return m
    }

    /// The speaker keys that are the owner here, found before the ids are taken off.
    public static func ownerKeys(_ r: CallRecord, owner: OwnerIdentity) -> [String] {
        owner.speakerKeys(in: r).sorted()
    }

    /// A chat as it leaves: no receipt, since each offers Undo on a point or a task of the first profile.
    public static func prepared(_ chat: Chat) -> Chat {
        var c = chat
        for i in c.messages.indices { c.messages[i].actions = nil }
        return c
    }

    /// The status a moved record has in the target. A written meeting is summarized again only where the target's
    /// naming changed a name; a failed one starts again at the step that failed.
    public static func arrival(status: CallStatus, failedStep: CallStatus?, namesChanged: Bool) -> CallStatus {
        let summarized: CallStatus = namesChanged ? .identified : .summarized
        switch status {
        case .written: return summarized
        case .failed:
            switch failedStep {
            case .transcribed?: return .transcribed
            case .identified?: return .identified
            case .summarized?, .written?: return summarized
            default: return .recorded
            }
        default: return .recorded
        }
    }
}

/// The rule of each file of a call folder in a move.
public enum MovedFiles {
    public enum Rule: Equatable, Sendable { case asIs, prepared, never, inWork }

    private static let asIs: Set<String> = ["me.caf", "them.caf", Recording.fileName, FrameIndex.fileName, FrameIndex.folder]
    private static let inWorkNames: Set<String> = [Pipeline.quietFileName, Pipeline.MergePlan.recordFile, Pipeline.MergePlan.fileName,
                                                   FrameStore.mergedFileName]

    /// The rule of a file by the first path component of its path in the call folder. Only the names that go are
    /// listed; every other name never goes (leftovers and files made again on demand).
    public static func rule(_ name: String) -> Rule {
        if name == CallRecord.fileName { return .prepared }
        if asIs.contains(name) { return .asIs }
        if inWorkNames.contains(name) || name.hasPrefix(Pipeline.MergePlan.backup) || name.hasPrefix("joined-") { return .inWork }
        return .never
    }

    /// A run or a merge that is not finished: the move is refused.
    public static func inWork(_ names: [String]) -> Bool {
        names.contains { rule($0) == .inWork }
    }

    /// The relative paths that go as they are, sorted.
    public static func list(in dir: URL) -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [String] = []
        let base = dir.resolvingSymlinksInPath().path + "/"
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(base) else { continue }
            let path = String(full.dropFirst(base.count))
            guard let first = path.split(separator: "/").first, rule(String(first)) == .asIs else { continue }
            out.append(path)
        }
        return out.sorted()
    }
}
