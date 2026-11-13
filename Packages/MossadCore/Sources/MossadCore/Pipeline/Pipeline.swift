import AVFoundation
import Foundation
import Synchronization

/// Turns recorded calls into named, summarized Markdown files. Each step saves `call.json`,
/// so a call resumes where it stopped after a failure or a restart.
public actor Pipeline {
    static let maxSummaryAttempts = 3
    /// After this many failed attempts at one step the call is marked failed. The backoff table adds up to about a
    /// day; the hourly housekeeping and a wake from sleep set the real pace.
    public static let maxAttempts = 8
    /// Tracks shorter than this have no speech worth uploading.
    static let minimumTrackDuration: TimeInterval = 1
    /// A meeting written without a summary tries again this long after its last try.
    static let missingSummaryRetry: TimeInterval = 86_400

    /// What the owner can change in Settings. One pipeline lives as long as the app; a change of key, model, or
    /// name replaces this, so the calls in flight and their guards stay with the one actor.
    public struct Configuration: Sendable {
        public var transcriber: Transcribing
        public var summarizer: Summarizing?
        public var ownerName: String
        public var voiceFingerprints: Bool

        public init(transcriber: Transcribing, summarizer: Summarizing?, ownerName: String = "Me", voiceFingerprints: Bool = true) {
            self.transcriber = transcriber
            self.summarizer = summarizer
            self.ownerName = ownerName
            self.voiceFingerprints = voiceFingerprints
        }
    }

    private var inFlight: Set<String> = []
    /// Edits made while a call is in flight, applied again to the run's own copy before each of its saves, so the
    /// run never writes the old values back. See `edit`.
    private var ownerEdits: [String: [(inout CallRecord) -> Bool]] = [:]
    /// Calls running as the quiet backfill, with the record from before; see `regenerateSummary`.
    private var quietRuns: [String: CallRecord] = [:]
    /// The transcription job per call and track while it runs; copied into each save of the run.
    private var jobs: [String: [String: String]] = [:]

    private let paths: Paths
    private let queue: ProcessingQueue
    private let library: VoiceLibrary
    private let embeddings: EmbeddingProvider
    private let calendar: CalendarSource
    private let notify: @Sendable (CallRecord) -> Void
    private let now: @Sendable () -> Date
    private let heavy: HeavyWorkGate
    private nonisolated let settings: Mutex<Configuration>
    /// Called for each meeting a merge removes, so its archived recording and share links go too.
    private let onDiscard: @Sendable (CallRecord) -> Void
    private var configuration: Configuration { settings.withLock { $0 } }
    private var transcriber: Transcribing { configuration.transcriber }
    private var summarizer: Summarizing? { configuration.summarizer }
    private var ownerName: String { configuration.ownerName }
    private var voiceFingerprints: Bool { configuration.voiceFingerprints }
    private var identifier: SpeakerIdentifier { SpeakerIdentifier(library: library, provider: embeddings, ownerName: ownerName) }
    /// "Name, Title" lines for the names in a call; empty without an org chart.
    private let titles: @Sendable ([String]) -> [String]
    private let onStep: @Sendable (CallRecord) -> Void
    /// A short text for the sub-step in progress (call ID, text; nil when processing stops). Shown, not saved.
    private let onDetail: @Sendable (String, String?) -> Void
    private var stages: [String: [Track: TranscriptionStage]] = [:]
    /// Each call's progress for the progress card (call ID, progress; nil when processing stops).
    private let onProgress: @Sendable (String, ProcessingProgress?) -> Void
    private var progress: [String: ProcessingProgress] = [:]
    /// Calls in the transcription step; a late stage update after it must not overwrite the next sub-step.
    private var transcribing: Set<String> = []
    /// Reads the text on the kept frames of shared screens; nil where that is not done (tests, the iPhone).
    private let screenStep: ScreenStep?
    /// Each failed attempt at a step, by its kind only, for the anonymous usage statistics.
    private let onFailure: @Sendable (UsageStats.Step) -> Void

    /// `onStep` receives the record after every save of `call.json`, so the UI can show the live step.
    public init(paths: Paths, transcriber: Transcribing, library: VoiceLibrary, embeddings: EmbeddingProvider,
                calendar: CalendarSource, summarizer: Summarizing?, notify: @escaping @Sendable (CallRecord) -> Void,
                now: @escaping @Sendable () -> Date = Date.init, ownerName: String = "Me", voiceFingerprints: Bool = true,
                onStep: @escaping @Sendable (CallRecord) -> Void = { _ in },
                onDetail: @escaping @Sendable (String, String?) -> Void = { _, _ in },
                onProgress: @escaping @Sendable (String, ProcessingProgress?) -> Void = { _, _ in },
                titles: @escaping @Sendable ([String]) -> [String] = { _ in [] },
                onDiscard: @escaping @Sendable (CallRecord) -> Void = { _ in },
                heavy: HeavyWorkGate = .shared, screenStep: ScreenStep? = nil,
                onFailure: @escaping @Sendable (UsageStats.Step) -> Void = { _ in }) {
        self.heavy = heavy
        self.onFailure = onFailure
        // The text step asks the same gate whether a call records. It does not wait there: it rests between frames.
        self.screenStep = screenStep?.gated(by: heavy)
        self.titles = titles
        self.onStep = onStep
        self.onProgress = onProgress
        self.onDetail = onDetail
        self.onDiscard = onDiscard
        self.paths = paths
        self.queue = ProcessingQueue(paths: paths)
        self.library = library
        self.embeddings = embeddings
        self.settings = Mutex(Configuration(transcriber: transcriber, summarizer: summarizer, ownerName: ownerName,
                                            voiceFingerprints: voiceFingerprints))
        self.calendar = calendar
        self.notify = notify
        self.now = now
    }

    /// Takes new settings at once; a step that already started finishes with the ones it read.
    public nonisolated func configure(_ configuration: Configuration) {
        settings.withLock { $0 = configuration }
    }

    public func runPending() async {
        finishInterruptedMerges()
        // Calls held because their muted parts could not be silenced (a full disk): try that again.
        for r in queue.allRecords() where r.mutedAudioPending && r.status == .failed && r.failedStep == .recorded { await retry(r.id) }
        for r in queue.pending(now: now()) { await process(r.id) }
        await retryMissingSummaries()
    }

    /// Meetings written without a summary (the provider failed three times) try again once a day while a model is set.
    private func retryMissingSummaries() async {
        guard summarizer != nil else { return }
        for r in queue.allRecords() where r.status == .written && r.summaryMissing == true && !r.utterances.isEmpty
            && (r.nextAttempt ?? .distantPast) <= now() && !inFlight.contains(r.id) {
            let next = now().addingTimeInterval(Self.missingSummaryRetry)
            // Saved first, so a failure or a crash waits a day too. Quiet: the calendar match and the names are done.
            // The due check is made again on the record as it is now: a second run with an older list (the timer, a
            // wake, and a sync can each start one) must not try the same meeting a second time today.
            let time = now()
            guard let latest = edit(r.id, { r in
                guard r.status == .written, r.summaryMissing == true, (r.nextAttempt ?? .distantPast) <= time else { return false }
                r.nextAttempt = next
                return true
            }) else { continue }
            do { try store(latest, dir: paths.callDirectory(r.id)) } catch { continue }
            Log.info("Trying the summary of \(r.id) again")
            await regenerateSummary(r.id, quiet: true)
        }
    }

    public func process(_ id: String) async {
        await processSteps(id)
        // Outside `processSteps`, so this call is no longer in flight when the merge processes the joined record.
        await continueSplitMeeting(id)
    }

    private func processSteps(_ id: String) async {
        defer {
            stages[id] = nil
            transcribing.remove(id)
            onDetail(id, nil)
            progress[id] = nil
            onProgress(id, nil)
        }
        // `process` suspends at every await; without this a timer run and a call-end run could overlap.
        guard inFlight.insert(id).inserted else { return }
        let dir = paths.callDirectory(id)
        // Only the run that owns the id clears its quiet mark; an overlapping call returns at the guard above.
        defer {
            inFlight.remove(id)
            ownerEdits[id] = nil
            quietRuns[id] = nil
            jobs[id] = nil
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.quietFileName))
        }
        guard var r = try? CallRecord.load(from: dir) else { return }
        // A quiet run that a quit interrupted is still quiet: its record from before was saved beside it.
        if quietRuns[id] == nil, let original = try? CallRecord.load(from: dir, fileName: Self.quietFileName) { quietRuns[id] = original }
        jobs[id] = r.transcriptionJobs ?? [:]
        do {
            while r.status != .written {
                carryOwnerEdits(into: &r, dir: dir)
                if let step = ProcessingStep(status: r.status) { startStep(r, step) }
                switch r.status {
                case .recorded:
                    // The mic track may still hold what was said while muted. Never send it anywhere like that.
                    if r.mutedAudioPending {
                        try MutedAudio.apply(to: &r, in: dir)
                        try store(r, dir: dir)
                    }
                    try await transcribe(&r, dir: dir)
                case .transcribed: try await identify(&r, dir: dir)
                case .identified:
                    guard await summarize(&r) else {
                        // A failed backfill must not leave the meeting waiting for a normal retry, which would notify.
                        if let original = quietRuns[id] { r = original }
                        carryOwnerEdits(into: &r, dir: dir)
                        try store(r, dir: dir)
                        return
                    }
                case .summarized: try await write(&r)
                case .recording, .failed, .written: return
                }
                r.attempts = 0
                // A note written without its summary keeps the reason and tries again in a day.
                r.nextAttempt = r.summaryMissing == true ? now().addingTimeInterval(Self.missingSummaryRetry) : nil
                if r.summaryMissing != true { r.failureReason = nil }
                carryOwnerEdits(into: &r, dir: dir)
                try store(r, dir: dir)
            }
        } catch let error as MutedAudio.NotSilenced {
            // Held back, with no attempts used: each launch and each hourly run tries the silence again.
            Log.error("Processing \(id) waits: \(error.localizedDescription)")
            MutedAudio.hold(&r)
            carryOwnerEdits(into: &r, dir: dir)
            try? store(r, dir: dir)
        } catch let error as MissingAPIKey {
            // Not the call's fault: wait for the key without using up attempts or a backoff delay.
            Log.error("Processing \(id) waits for an API key")
            r.failureReason = Self.failureReason(error)
            carryOwnerEdits(into: &r, dir: dir)
            try? store(r, dir: dir)
        } catch {
            Log.error("Processing \(id) failed at \(r.status.rawValue): \(error)")
            if let step = UsageStats.Step(failedAt: r.status) { onFailure(step) }
            r.failureReason = Self.failureReason(error)
            queue.markFailure(&r, now: now())
            if r.attempts >= Self.maxAttempts {
                r.failedStep = r.status
                r.status = .failed
                Log.error("Gave up on \(id) after \(r.attempts) attempts")
            }
            carryOwnerEdits(into: &r, dir: dir)
            try? store(r, dir: dir)
        }
    }

    /// Asks Claude for a new summary of a finished meeting, for example after the summary format changed.
    /// The transcript and speakers stay; only the summary step and the note run again.
    /// `quiet` is for the one-time backfill: no "name this voice" notification and no calendar match, so old
    /// meetings keep their calendar title and attendees and the owner is not pinged once per meeting.
    public func regenerateSummary(_ id: String, quiet: Bool = false) async {
        let dir = paths.callDirectory(id)
        guard !inFlight.contains(id), var r = try? CallRecord.load(from: dir), r.status == .written, !r.utterances.isEmpty else { return }
        let original = r
        if quiet {
            // On disk too, so a quit during the run neither matches the calendar again nor notifies on the next launch.
            do { try original.save(to: dir, fileName: Self.quietFileName) } catch { return }
            quietRuns[id] = original
        }
        r.status = .identified
        do { try store(r, dir: dir) } catch { return }
        await process(id)
    }

    /// The record from before a quiet run, kept until the run ends.
    static let quietFileName = "call.quiet.json"

    /// The one-time catch-up for meetings written before titles and decision times: the summary step again.
    /// Names, owner-set tags, the custom and calendar titles, and bookmarks stay; `apply` keeps owner tags.
    /// Returns whether the new summary landed. Tags never change.
    public func backfill(_ id: String) async -> Bool {
        // Saved first, so a retry after a failure keeps the tags too. Old owner tags and old model tags look alike.
        let dir = paths.callDirectory(id)
        if var r = try? CallRecord.load(from: dir), r.status == .written, !r.tags.isEmpty, r.tagsSetByOwner != true {
            r.tagsSetByOwner = true
            try? store(r, dir: dir)
        }
        await regenerateSummary(id, quiet: true)
        guard let r = try? CallRecord.load(from: paths.callDirectory(id)) else { return false }
        return r.status == .written && (r.summaryVersion ?? 0) >= SummaryBackfill.currentVersion
    }

    /// Where the transcript from before the last "Transcribe again" is kept, for one undo.
    public static let previousFileName = "call.previous.json"

    /// The raw tracks are what gets transcribed; they are deleted some weeks after the meeting.
    public static func canTranscribeAgain(_ dir: URL) -> Bool {
        [Track.me, .them].contains { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.fileName).path) }
    }

    public static func hasPreviousTranscript(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(previousFileName).path)
    }

    /// Transcribes a finished meeting again from its audio, optionally with how many people spoke, then names the
    /// voices and writes a new summary and note. The current record is kept first, so the person can go back.
    @discardableResult
    public func transcribeAgain(_ id: String, speakers: Int?) async -> Bool {
        let dir = paths.callDirectory(id)
        guard var r = try? CallRecord.load(from: dir), r.status == .written || r.status == .failed,
              Self.canTranscribeAgain(dir), !inFlight.contains(id) else { return false }
        do {
            let previous = dir.appendingPathComponent(Self.previousFileName)
            try? FileManager.default.removeItem(at: previous)
            try FileManager.default.copyItem(at: dir.appendingPathComponent(CallRecord.fileName), to: previous)
        } catch {
            Log.error("Could not keep the transcript of \(id) before transcribing again: \(error)")
            return false
        }
        r.speakersExpected = speakers
        // A job left by a failed run was made with the old settings; this run must start its own.
        r.transcriptionJobs = nil
        r.meUtterances = nil
        r.themUtterances = nil
        r.utterances = []
        r.speakerNames = [:]
        r.unknownSpeakers = []
        r.speakerEmbeddings = [:]
        r.speakerSamples = nil
        r.fromInvite = nil
        r.status = .recorded
        r.failedStep = nil
        r.failureReason = nil
        r.attempts = 0
        r.nextAttempt = nil
        do { try store(r, dir: dir) } catch { return false }
        Log.info("Transcribing \(id) again" + (speakers.map { " for \($0) speakers" } ?? ""))
        await process(id)
        return true
    }

    /// Puts back the transcript from before the last "Transcribe again", and its note.
    @discardableResult
    public func restorePreviousTranscript(_ id: String) async -> Bool {
        let dir = paths.callDirectory(id)
        guard let current = try? CallRecord.load(from: dir), current.status == .written || current.status == .failed,
              var r = try? CallRecord.load(from: dir, fileName: Self.previousFileName), !inFlight.contains(id) else { return false }
        // The note is written again from the old record; any path change follows the current one.
        r.markdownPath = current.markdownPath
        // Edits made since the transcribe-again belong to the owner, not to the old record.
        r.customTitle = current.customTitle
        r.tags = current.tags
        r.tagsSetByOwner = current.tagsSetByOwner
        r.markers = current.markers
        r.screens = current.screens
        r.screenGaps = current.screenGaps
        r.deletedScreens = current.deletedScreens
        r.status = .summarized
        do { try store(r, dir: dir) } catch { return false }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.previousFileName))
        Log.info("Restored the previous transcript of \(id)")
        await process(id)
        return true
    }

    /// Starts a failed or waiting call again now.
    public func retry(_ id: String) async {
        let dir = paths.callDirectory(id)
        guard var r = try? CallRecord.load(from: dir) else { return }
        if r.status == .failed, let step = r.failedStep {
            r.status = step
            r.failedStep = nil
        }
        r.attempts = 0
        r.nextAttempt = nil
        r.failureReason = nil
        try? store(r, dir: dir)
        await process(id)
    }

    /// The owner edits a call while it is still processing (names, title, tags, bookmarks, a rename in People), and
    /// each edit saves `call.json` at once. `processSteps` holds its own copy across slow network steps, so each
    /// edit made in flight is applied to that copy again here. Called before each step and each save; nothing
    /// awaits in between.
    private func carryOwnerEdits(into r: inout CallRecord, dir: URL) {
        if let disk = try? CallRecord.load(from: dir) {
            r.markers = disk.markers
            r.customTitle = disk.customTitle
        }
        for change in ownerEdits[r.id] ?? [] { _ = change(&r) }
        if let j = jobs[r.id] { r.transcriptionJobs = j.isEmpty ? nil : j }
    }

    /// Loads one record and changes it. While the call is in flight the change is also kept for `carryOwnerEdits`,
    /// so it must give the same result when applied again. Returns nil when the record cannot be read, or when
    /// `change` returns false (nothing to change). The caller saves.
    private func edit(_ id: String, _ change: @escaping (inout CallRecord) -> Bool) -> CallRecord? {
        guard var r = try? CallRecord.load(from: paths.callDirectory(id)), change(&r) else { return nil }
        if inFlight.contains(id) { ownerEdits[id, default: []].append(change) }
        return r
    }

    /// Marks a recording as archived in a backup. Through this actor, so a run or an edit in flight keeps the mark
    /// and the mark never brings back an old copy of the record. A copy the record had in another key or place
    /// becomes a leftover, for the archive to remove once this one is safe. With `ifCurrent`, nothing changes
    /// unless the record still names that copy. False when the record cannot be read or was not changed.
    @discardableResult
    public func setArchived(callID: String, _ object: ArchivedObject, size: Int64, sha256: String? = nil, ifCurrent: ArchivedObject? = nil) -> Bool {
        let changed = edit(callID) { r in
            let current = r.archived
            if let ifCurrent, current != ifCurrent, current != object { return false }
            if let current, current != object, r.cloudLeftovers?.contains(current) != true { r.cloudLeftovers = (r.cloudLeftovers ?? []) + [current] }
            r.cloudKey = object.key
            r.cloudSize = size
            // The bucket has no name in the record, as before places had names, so an older build reads it the same.
            r.cloudBackend = object.kind == .bucket ? nil : object.backend
            r.cloudServer = object.server
            r.cloudHash = sha256
            return true
        }
        guard let r = changed else { return false }
        do { try store(r, dir: paths.callDirectory(callID)) } catch {
            Log.error("Saving the archive key of \(callID) failed: \(error)")
            return false
        }
        return true
    }

    /// Takes away a backup mark that is false: the place answered that it does not have the file. Without the mark
    /// the recording counts as not backed up, so its audio on this Mac stays and it is sent again. Only a record
    /// that still names `object` changes.
    @discardableResult
    public func clearArchived(callID: String, ifCurrent object: ArchivedObject) -> Bool {
        let changed = edit(callID) { r in
            guard r.archived == object else { return false }
            r.cloudKey = nil
            r.cloudSize = nil
            r.cloudBackend = nil
            r.cloudServer = nil
            r.cloudHash = nil
            return true
        }
        guard let r = changed else { return false }
        do { try store(r, dir: paths.callDirectory(callID)) } catch {
            Log.error("Saving the archive mark of \(callID) failed: \(error)")
            return false
        }
        return true
    }

    /// Marks a recording as archived in the bucket.
    @discardableResult
    public func setCloudKey(callID: String, key: String, size: Int64) -> Bool {
        setArchived(callID: callID, ArchivedObject(key: key, kind: .bucket), size: size)
    }

    /// Forgets older copies that the archive removed.
    public func dropLeftovers(callID: String, _ gone: [ArchivedObject]) {
        guard !gone.isEmpty else { return }
        let changed = edit(callID) { r in
            guard let list = r.cloudLeftovers else { return false }
            let rest = list.filter { !gone.contains($0) }
            guard rest.count != list.count else { return false }
            r.cloudLeftovers = rest.isEmpty ? nil : rest
            return true
        }
        guard let r = changed else { return }
        do { try store(r, dir: paths.callDirectory(callID)) } catch { Log.error("Saving the archive mark of \(callID) failed: \(error)") }
    }

    /// Saves a transcription job id as soon as the service gives it, so a restart polls the same job.
    private func saveJob(_ id: String, _ track: Track, _ job: String?) {
        guard jobs[id] != nil else { return }
        jobs[id]?[track.rawValue] = job
        let dir = paths.callDirectory(id)
        guard var disk = try? CallRecord.load(from: dir) else { return }
        disk.transcriptionJobs = jobs[id].flatMap { $0.isEmpty ? nil : $0 }
        try? disk.save(to: dir)
    }

    private func store(_ r: CallRecord, dir: URL) throws {
        var r = r
        // The ids of its people go with each save. The labels change only where the note is written too.
        if let refs = references() {
            let next = refs.refresh(r, relabel: false)
            // A written meeting that gets ids here for the first time keeps a copy of how it was.
            if next != r, r.status == .written { ReferenceBackup.keep(record: dir, paths: paths) }
            r = next
        }
        try r.save(to: dir)
        onStep(r)
    }

    /// The people's references, while the people store follows the voice library. Nil before that, and when a file
    /// stopped it: then records keep their labels only, as before ids.
    private func references() -> PersonReferences? {
        guard let people = library.identity?.people.people, !people.isEmpty else { return nil }
        return PersonReferences(people: people)
    }

    /// Brings each record in step with the people: ids where a label is surely a saved person, and the name of now
    /// where a label is a name the person had (after a rename or a merge), with the note written again. Each record
    /// is compared before it is written, so a stop in the middle is finished by the next run. A copy of each record
    /// goes to the backup folder before its first change. `renamed` is a rename that the owner made just now: a
    /// label that still has the old name (no people store, or a record no id reached) gets the new one, as before ids.
    @discardableResult
    public func refreshLabels(renamed: (old: String, new: String)? = nil) -> Int {
        var changed = 0
        if let refs = references() {
            for record in ProcessingQueue(paths: paths).allRecords() {
                // A first look at the record in memory: most runs change nothing, and then no file is read again.
                guard refs.refresh(record) != record else { continue }
                let dir = paths.callDirectory(record.id)
                var refused = false, relabeled = false
                guard var r = edit(record.id, { r in
                    let next = refs.refresh(r)
                    guard next != r else { return false }
                    guard refs.changesOnlyReferences(from: r, to: next) else {
                        refused = true
                        return false
                    }
                    relabeled = next.speakerNames != r.speakerNames || next.actionItems.map(\.owner) != r.actionItems.map(\.owner)
                    r = next
                    return true
                }) else {
                    if refused { Log.error("People: \(record.id) is left as it is: the refresh would change more than the references") }
                    continue
                }
                guard ReferenceBackup.keep(record: dir, paths: paths) else { continue }
                if relabeled, r.status == .written {
                    // A label changed: the note is written again, after a copy of it as it was.
                    if let note = r.markdownPath, !ReferenceBackup.keep(note: note, paths: paths) { continue }
                    save(&r, dir: dir)
                } else {
                    // Only ids: the note does not change, so it is not written.
                    do { try store(r, dir: dir) } catch {
                        Log.error("People: the ids of \(r.id) were not saved: \(error)")
                        continue
                    }
                }
                changed += 1
            }
            if changed > 0 { Log.info("People: \(changed) meetings have their people's ids and names of now") }
        }
        if let renamed { changed += renamePerson(renamed.old, to: renamed.new) }
        return changed
    }

    /// Makes a notes-only meeting from Gemini's notes and runs its steps: the summary, the note, and what follows.
    /// False when a meeting with this id exists: an import never replaces one.
    @discardableResult
    public func importNotes(_ record: CallRecord) async -> Bool {
        let dir = paths.callDirectory(record.id)
        guard !FileManager.default.fileExists(atPath: dir.path) else { return false }
        // Each document once, also when two runs planned it: the check is here, on the one actor.
        if let doc = record.gemini?.docID, queue.allRecords().contains(where: { $0.gemini?.docID == doc }) {
            Log.info("Gemini notes: the document of \(record.id) is in another meeting already")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try store(record, dir: dir)
        } catch {
            Log.error("Gemini notes: \(record.id) was not saved: \(error)")
            return false
        }
        Log.info("Gemini notes: made \(record.id) with \(record.utterances.count) lines")
        await process(record.id)
        return true
    }

    /// Gives a recorded meeting its Gemini notes as a second source. The note gets the link when it is written.
    /// False when the meeting has notes already or cannot be read.
    @discardableResult
    public func attachNotes(callID: String, _ notes: GeminiNotesRef) -> Bool {
        guard var r = edit(callID, { r in
            guard r.gemini == nil else { return false }
            r.gemini = notes
            return true
        }) else { return false }
        save(&r, dir: paths.callDirectory(callID))
        Log.info("Gemini notes: \(callID) has its Gemini notes as a second source")
        return true
    }

    /// A recording of a meeting that was made from its notes before: the notes go to the recording, and the
    /// notes-only meeting goes without a mark, since its notes live on.
    @discardableResult
    public func moveNotes(from notesID: String, to callID: String) -> Bool {
        // Only a notes-only meeting that can be removed: else the recording would get the notes and both would stay.
        guard let notes = try? CallRecord.load(from: paths.callDirectory(notesID)), notes.isNotesOnly, var ref = notes.gemini,
              notes.status == .written || notes.status == .failed, !inFlight.contains(notesID) else { return false }
        ref.notes = nil
        guard attachNotes(callID: callID, ref) else { return false }
        if let removed = remove(callID: notesID, keepNotes: true) { onDiscard(removed) }
        Log.info("Gemini notes: \(notesID) joined its recording \(callID)")
        return true
    }

    /// Deletes a finished or failed call: its note, audio, and record. A call that is still recording or
    /// processing is refused, so the pipeline never writes into a folder that is gone.
    public func delete(callID: String) -> Bool { remove(callID: callID) != nil }

    /// Deletes like `delete` and returns the record as it was on disk, so the caller can remove what the meeting
    /// has outside this Mac (its archived recording) from the record's own values, not from a list in memory.
    public func remove(callID: String) -> CallRecord? { remove(callID: callID, keepNotes: false) }

    /// `keepNotes` false marks a deleted meeting (a recording or a notes-only meeting), so its notes are never imported
    /// or billed again.
    func remove(callID: String, keepNotes: Bool) -> CallRecord? {
        let dir = paths.callDirectory(callID)
        guard let r = try? CallRecord.load(from: dir), r.status == .written || r.status == .failed else { return nil }
        if !keepNotes { RemovedNotes.add(r, paths: paths) }
        if let note = r.markdownPath { try? FileManager.default.removeItem(atPath: note) }
        // The copy of the record from before the ids goes with the meeting.
        ReferenceBackup.forget(callID: callID, paths: paths)
        do { try FileManager.default.removeItem(at: dir) } catch {
            Log.error("Deleting \(callID) failed: \(error)")
            return nil
        }
        heavy.forget(callID)
        Log.info("Deleted call \(callID)")
        return r
    }

    private func transcribe(_ r: inout CallRecord, dir: URL) async throws {
        transcribing.insert(r.id)
        // The full transcript replaces the live one, which was only for use during the call.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(LiveTranscript.fileName))
        // A compressed copy left by a crash during an upload.
        for track in [Track.me, .them] { try? FileManager.default.removeItem(at: dir.appendingPathComponent("upload-\(track.rawValue).m4a")) }
        let hints = Self.speakerHints(r)
        let id = r.id, done: [Track: [Utterance]] = [.me: r.meUtterances, .them: r.themUtterances].compactMapValues { $0 }
        var results: [Track: Result<[Utterance], Error>] = [:]
        await withTaskGroup(of: (Track, Result<[Utterance], Error>).self) { group in
            for track in [Track.me, .them] {
                let speakers = hints[track], finished = done[track]
                group.addTask { (track, await self.transcribeIfNeeded(finished, track: track, speakers: speakers, dir: dir, callID: id)) }
            }
            // Keep whichever track succeeded, saved as each lands, so a quit while the other waits keeps this one.
            for await (track, result) in group {
                results[track] = result
                guard case .success(let u) = result else { continue }
                if track == .me { r.meUtterances = u } else { r.themUtterances = u }
                jobs[id]?[track.rawValue] = nil
                trackChanged(id, track, u.isEmpty ? .skipped : .done)
                carryOwnerEdits(into: &r, dir: dir)
                try? store(r, dir: dir)
            }
        }
        let meResult = results[.me]!, themResult = results[.them]!
        // Then fail if either track did.
        carryOwnerEdits(into: &r, dir: dir)
        try store(r, dir: dir)
        transcribing.remove(r.id)
        detail(r.id, "Joining the two tracks")
        // Without the them track (deleted or unreadable) only the word rule removes echo. A full read of the track,
        // so off this actor. It reads one buffer at a time, so it also runs behind a call.
        let them = dir.appendingPathComponent(Track.them.fileName)
        let meWords = try meResult.get(), themWords = try themResult.get()
        let plan = await clearance(r.id, .trackJoin)
        r.utterances = try await runHeavy(r.id, .trackJoin, plan) {
            TranscriptMerger.merge(me: meWords, them: themWords, themSound: try? SoundTimeline.measure(url: them))
        }
        r.status = .transcribed
        Log.info("Transcribed \(r.id): \(r.utterances.count) utterances")
    }

    /// The person's speaker count goes with the track that holds those voices: in a room the mic hears everyone;
    /// on a call the owner is on the mic and the rest are in the call audio.
    static func speakerHints(_ r: CallRecord) -> [Track: Int] {
        guard let n = r.speakersExpected, n > 0 else { return [:] }
        return r.platform == .inPerson ? [.me: n] : [.them: max(1, n - 1)]
    }

    private func transcribeIfNeeded(_ done: [Utterance]?, track: Track, speakers: Int?, dir: URL, callID: String) async -> Result<[Utterance], Error> {
        if let done { return .success(done) }
        let url = dir.appendingPathComponent(track.fileName)
        let duration: Double
        do {
            let file = try AVAudioFile(forReading: url)
            duration = Double(file.length) / file.fileFormat.sampleRate
        } catch {
            // Unreadable is not empty: retry instead of writing an empty transcript.
            return .failure(error)
        }
        if duration < Self.minimumTrackDuration {
            Log.info("\(track.rawValue) track is empty; skipping transcription")
            return .success([])
        }
        // A compressed copy goes up; the raw track stays for speaker identification and the recording. The encode
        // takes seconds of processor time: it waits out a call and runs off this actor. The upload does not wait.
        let encode = await clearance(callID, .uploadEncode)
        let upload = (try? await runHeavy(callID, .uploadEncode, encode) { try UploadAudio.compress(url, into: dir) }) ?? url
        defer { if upload != url { try? FileManager.default.removeItem(at: upload) } }
        let transcriber = transcriber
        let job = TranscriptionJobStore(saved: jobs[callID]?[track.rawValue]) { job in await self.saveJob(callID, track, job) }
        let work: @Sendable () async throws -> [Utterance] = {
            try await UsageContext.$callID.withValue(callID) {
                try await TranscriptionJob.$store.withValue(job) {
                    try await transcriber.transcribe(file: upload, track: track, speakers: speakers) { stage in
                        Task { await self.stageChanged(callID, track, stage) }
                    }
                }
            }
        }
        do {
            // A model on this Mac uses all of the processor for minutes.
            guard transcriber.runsOnThisDevice else { return .success(try await work()) }
            let plan = await clearance(callID, .onDeviceTranscription)
            return .success(try await runHeavy(callID, .onDeviceTranscription, plan, work))
        } catch { return .failure(error) }
    }

    private func startStep(_ r: CallRecord, _ step: ProcessingStep) {
        var p = progress[r.id] ?? ProcessingProgress(step: step, started: now())
        p.step = step
        p.stepStarted = now()
        p.detail = nil
        if step == .transcribing {
            p.tracks = [.me: r.meUtterances == nil ? .uploading(nil) : .done, .them: r.themUtterances == nil ? .uploading(nil) : .done]
            // A room has no call audio to wait for.
            if r.platform == .inPerson { p.tracks[.them] = .skipped }
        }
        progress[r.id] = p
        onProgress(r.id, p)
    }

    /// The sub-step text, for the list and menu, and on the progress card.
    private func detail(_ id: String, _ text: String) {
        onDetail(id, text)
        guard var p = progress[id] else { return }
        p.detail = text
        progress[id] = p
        onProgress(id, p)
    }

    private func trackChanged(_ id: String, _ track: Track, _ state: ProcessingProgress.TrackState) {
        guard var p = progress[id], p.step == .transcribing else { return }
        p.tracks[track] = state
        progress[id] = p
        onProgress(id, p)
    }

    /// "Uploading your mic to AssemblyAI", or both tracks when they differ.
    private func stageChanged(_ id: String, _ track: Track, _ stage: TranscriptionStage) {
        guard transcribing.contains(id) else { return }
        let state: ProcessingProgress.TrackState = switch stage {
        case .uploading(let f): .uploading(f)
        case .queued: .queued
        case .transcribing: .transcribing
        }
        trackChanged(id, track, state)
        // The list and menu line changes only when the stage does, not with every percent.
        if case .uploading = stage, case .uploading? = stages[id]?[track] { return }
        stages[id, default: [:]][track] = stage
        let name = transcriber.serviceName
        func text(_ t: Track, _ s: TranscriptionStage) -> String {
            switch s {
            case .uploading: t == .me ? "Uploading your mic to \(name)" : "Uploading the call audio to \(name)"
            case .queued: "Waiting in \(name)'s queue"
            case .transcribing: "\(name) is transcribing"
            }
        }
        let current = stages[id] ?? [:]
        let parts = [Track.me, .them].compactMap { t in current[t].map { (t, $0) } }
        let line = Set(parts.map { text($0.0, $0.1) }).count == 1
            ? text(parts[0].0, parts[0].1)
            : parts.map { "\($0.0 == .me ? "Mic" : "Call audio"): \(text($0.0, $0.1).replacingOccurrences(of: " to \(name)", with: ""))" }.joined(separator: " · ")
        onDetail(id, line)
    }

    private func identify(_ r: inout CallRecord, dir: URL) async throws {
        guard voiceFingerprints else {
            detail(r.id, "Identifying speakers")
            // No fingerprints: the speaker who talks most on the mic is the owner; everyone else stays a letter.
            let talk = Dictionary(r.utterances.map { ($0.speakerKey, $0.end - $0.start) }, uniquingKeysWith: +)
            let owner = talk.filter { $0.key.hasPrefix("me:") }.max { $0.value < $1.value }?.key
            r.speakerNames = owner.map { [$0: ownerName] } ?? [:]
            var keys: [String] = []
            for u in r.utterances where u.speakerKey != owner && !keys.contains(u.speakerKey) { keys.append(u.speakerKey) }
            r.unknownSpeakers = keys
            r.speakerEmbeddings = [:]
            r.speakerSamples = nil
            r.fromInvite = nil
            r.status = .identified
            return
        }
        // Who was invited decides whose voice may be named on a call. The invite found when the call started was
        // matched to a guessed end, and can have changed since: it is matched again with the call's real times. A
        // room recording keeps the rules of before.
        let onCall = r.platform != .inPerson && !r.isNotesOnly
        let sure = onCall ? await matchInvite(&r) : false
        let invite = onCall ? CallInvite(record: r, sure: sure) : nil
        detail(r.id, "Identifying speakers")
        // Short pieces of each voice, at most a minute per speaker, through the one copy of the voice models that the
        // live transcript's namer also uses; so it runs behind a call.
        let plan = await clearance(r.id, .voiceIdentification)
        let identifier = identifier, utterances = r.utterances, call = (id: r.id, start: r.start)
        let me = dir.appendingPathComponent(Track.me.fileName), them = dir.appendingPathComponent(Track.them.fileName)
        let result = try await runHeavy(r.id, .voiceIdentification, plan) {
            try await identifier.identify(utterances: utterances, meURL: me, themURL: them, call: call, invite: invite)
        }
        r.speakerNames = result.names
        r.unknownSpeakers = result.unknown
        r.speakerEmbeddings = result.embeddings
        r.speakerSamples = result.details.isEmpty ? nil : result.details
        r.fromInvite = result.fromInvite.isEmpty ? nil : result.fromInvite.sorted()
        dropNamedEcho(&r)
        r.status = .identified
    }

    /// A mic voice recognized as someone who is also on the call audio is that person through the speakers.
    /// The echo filter cannot see it when the owner hardly spoke, because then the echo has the most
    /// quiet-time speech on the mic. Someone in the room with the owner is never on the call audio, so stays.
    private func dropNamedEcho(_ r: inout CallRecord) {
        let remote = Set(r.speakerNames.filter { $0.key.hasPrefix("them:") }.values)
        // The owner's profile keeps its name when "Your name" changes in Settings, so both names are the owner.
        let owner = library.owner?.name
        let echo = Set(r.speakerNames.filter { $0.key.hasPrefix("me:") && remote.contains($0.value) && $0.value != ownerName && $0.value != owner }.keys)
        guard !echo.isEmpty else { return }
        r.utterances.removeAll { echo.contains($0.speakerKey) }
        for key in echo {
            r.speakerNames[key] = nil
            r.speakerEmbeddings[key] = nil
            r.speakerSamples?[key] = nil
        }
        r.unknownSpeakers.removeAll { echo.contains($0) }
        r.fromInvite = r.fromInvite.map { $0.filter { !echo.contains($0) } }.flatMap { $0.isEmpty ? nil : $0 }
        Log.info("Dropped \(echo.count) mic voices that are people on the call audio")
    }

    /// True when the event found is surely the call's.
    @discardableResult
    private func matchInvite(_ r: inout CallRecord) async -> Bool {
        detail(r.id, "Finding the calendar invite")
        let events = await calendar.events(from: r.start.addingTimeInterval(-600), to: r.end.addingTimeInterval(600))
        guard let match = CalendarMatcher.match(for: r.platform, meetingID: r.meetingID, start: r.start, end: r.end, in: events) else { return false }
        r.setInvite(match.event)
        return match.sure
    }

    /// Adds calendar details and the summary. Returns false when the summary should be retried later.
    private func summarize(_ r: inout CallRecord) async -> Bool {
        // A notes-only meeting was made from its invite.
        if quietRuns[r.id] == nil, !r.isNotesOnly { await matchInvite(&r) }
        // After the calendar, so a presenter's name can be matched to the invited people.
        await readScreens(&r)
        if summarizer != nil, !r.utterances.isEmpty { detail(r.id, "Claude is writing the summary") }
        if let summarizer, !r.utterances.isEmpty {
            do {
                let transcript = MarkdownWriter.transcript(r), title = r.title, known = knownTags()
                let people = titles(Array(Set(r.speakerNames.values)).sorted())
                let s = try await UsageContext.$callID.withValue(r.id) {
                    try await summarizer.summarize(transcript: transcript, title: title, knownTags: known, people: people)
                }
                r.apply(s)
                r.summaryMissing = nil
            } catch where Self.keyRejected(error) {
                // Not the call's fault, and not billed: wait for a good key without using up attempts.
                Log.error("Summary for \(r.id) waits for a valid key: \(error)")
                r.failureReason = Self.failureReason(error)
                return false
            } catch {
                Log.error("Summary for \(r.id) failed: \(error)")
                onFailure(.summarize)
                r.failureReason = Self.failureReason(error)
                queue.markFailure(&r, now: now())
                if r.attempts < Self.maxSummaryAttempts { return false }
                // Marked, so the meeting shows why it has no summary and a later run tries again.
                r.summaryMissing = true
                Log.info("Writing \(r.id) without a summary after \(r.attempts) attempts")
            }
        }
        r.status = .summarized
        return true
    }

    /// The text on the shared screens, before the summary, so the summary sees it as lines of the transcript.
    /// Nothing changes for a call with no frames on disk.
    private func readScreens(_ r: inout CallRecord) async {
        let dir = paths.callDirectory(r.id)
        guard let screenStep, FrameStore.hasFrames(in: dir) else { return }
        detail(r.id, "Reading the shared screens")
        let known = Set(r.speakerNames.values).union(r.attendees).union(library.profiles.map(\.name))
        if let result = await screenStep.run(in: dir, known: known.sorted(), existing: r.screens ?? [], deleted: Set(r.deletedScreens ?? [])) {
            r.screens = result.screens
            r.screenGaps = result.gaps.isEmpty ? nil : result.gaps
        }
    }

    private func knownTags() -> [String] { Tags.known(queue.allRecords()) }

    /// A heavy step waits here while a call records, when `HeavyWorkPlan` says so; "Process now" ends the wait.
    /// Returns how the step runs.
    private func clearance(_ id: String, _ step: HeavyStep) async -> HeavyWorkPlan {
        let plan = await heavy.plan(step, callID: id)
        guard plan == .wait else { return plan }
        // The two tracks can wait together: the first wait keeps the line from before, the last one puts it back.
        if waits[id, default: (0, nil)].count == 0 {
            waits[id] = (0, progress[id]?.detail)
            detail(id, "Waiting for the current call to end")
            setWaitsForCall(id, true)
        }
        waits[id]!.count += 1
        let cleared = await heavy.waitForClearance(step, callID: id)
        waits[id]!.count -= 1
        if waits[id]!.count == 0 {
            let before = waits.removeValue(forKey: id)?.before
            setWaitsForCall(id, false)
            if let before { detail(id, before) } else { clearDetail(id) }
        }
        return cleared
    }

    /// The calls whose steps wait for a call, with how many wait and the sub-step line from before.
    private var waits: [String: (count: Int, before: String?)] = [:]

    private func setWaitsForCall(_ id: String, _ waits: Bool) {
        guard var p = progress[id] else { return }
        p.waitsForCall = waits
        progress[id] = p
        onProgress(id, p)
    }

    /// Back to the step's own lines (the tracks while transcribing).
    private func clearDetail(_ id: String) {
        onDetail(id, nil)
        guard var p = progress[id] else { return }
        p.detail = nil
        progress[id] = p
        onProgress(id, p)
    }

    /// Runs a heavy step off this actor at the plan's priority. A step that ran during a call logs its time.
    private func runHeavy<T: Sendable>(_ id: String, _ step: HeavyStep, _ plan: HeavyWorkPlan,
                                       _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        guard plan.duringCall else { return try await HeavyWork.run(priority: plan.priority, body) }
        let heavy = heavy
        return try await heavy.lane.run {
            let clock = ContinuousClock(), start = clock.now
            var failed = true
            defer {
                let d = (clock.now - start).components
                heavy.log(step.logLine(callID: id, seconds: Double(d.seconds) + Double(d.attoseconds) / 1e18, failed: failed))
            }
            let value = try await HeavyWork.run(priority: plan.priority, body)
            failed = false
            return value
        }.get()
    }

    /// Makes the recording file of a call folder. A test puts its own in, to edit a call during the encode.
    private var makeRecording: @Sendable (URL) -> Void = { Recording.makeIfMissing(in: $0) }
    func setRecordingMaker(_ make: @escaping @Sendable (URL) -> Void) { makeRecording = make }

    private func write(_ r: inout CallRecord) async throws {
        let dir = paths.callDirectory(r.id)
        // The recording first: a mix and an AAC encode of the whole call, off this actor. While a call records, the
        // note does not wait for it: the app makes the missing recording when no call records
        // (`Recording.backfill`), and until then the player mixes the two tracks.
        let plan = await heavy.plan(.recordingEncode, callID: r.id)
        if r.isNotesOnly {
            // No audio: nothing to make.
        } else if plan == .wait {
            Log.info("A call records; the recording of \(r.id) is made later")
        } else {
            detail(r.id, "Making the recording")
            let make = makeRecording
            try? await runHeavy(r.id, .recordingEncode, plan) { make(dir) }
        }
        // The encode takes seconds, and this actor was free for the owner's edits in that time (a title, a tag, a
        // name, a bookmark). Each edit saved the record at once, so the record is taken fresh from the disk. From
        // here to the save of the written record nothing awaits: the note and the record hold the same content.
        if let fresh = try? CallRecord.load(from: dir), fresh.status == r.status { r = fresh }
        carryOwnerEdits(into: &r, dir: dir)
        detail(r.id, "Writing the note")
        let url = MarkdownWriter.noteURL(for: r, in: paths.meetings)
        if let old = r.markdownPath, old != url.path { try? FileManager.default.removeItem(atPath: old) }
        try MarkdownWriter.render(r).write(to: url, atomically: true, encoding: .utf8)
        r.markdownPath = url.path
        r.status = .written
        heavy.forget(r.id)
        Log.info("Wrote \(url.lastPathComponent)")
        // Without fingerprints a name is never learned, so asking after every call would only nag.
        if voiceFingerprints, !r.unknownSpeakers.isEmpty, quietRuns[r.id] == nil { notify(r) }
    }

    /// Applies names chosen by David, learns those voices, and rewrites the summary and the file.
    /// `emails` uses the same speaker keys as `names`; each email is stored on that person's voice profile.
    public func applyNames(callID: String, names: [String: String], emails: [String: String] = [:]) async {
        let dir = paths.callDirectory(callID)
        guard let current = try? CallRecord.load(from: dir) else { return }
        // The labels the summary used before the names, such as "Speaker A".
        let before = MarkdownWriter.displayNames(current)
        var chosen: [String: String] = [:]
        var renamed: [String: String] = [:]
        var emails = emails
        for (key, raw) in names {
            let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty else { continue }
            // A new name over the old one, with the old person's address still in the field: a correction, and the
            // address is not the new person's.
            if let old = current.speakerNames[key], PersonNames.key(typed) != PersonNames.key(old),
               let email = emails[key], library.name(forEmail: email) == old {
                emails[key] = nil
            }
            // Someone saved already, by email or by name in other case or spacing, stays one person.
            let name = library.existingName(name: typed, email: emails[key]) ?? typed
            if let old = before[key], old != name, current.speakerNames[key] == nil { renamed[old] = name }
            chosen[key] = name
            // "That was not Sam": what this speaker of this call taught Sam's profile is taken back.
            if let old = current.speakerNames[key], old != name {
                do { try library.forget(callID: callID, speakerKey: key, from: old, voice: current.speakerEmbeddings[key]) } catch { Log.error("Taking the voice back from \(old) failed: \(error)") }
            }
            if let e = current.speakerEmbeddings[key] {
                let detail = current.speakerSamples?[key]
                let source = VoiceSampleSource(callID: callID, speakerKey: key, recorded: current.start, seconds: detail?.seconds,
                                               quality: detail?.quality, origin: .ownerNamed)
                do { try library.add(e, to: name, source: source) } catch { Log.error("Saving voice for \(name) failed: \(error)") }
            }
        }
        for (key, email) in emails {
            guard let name = chosen[key] ?? current.speakerNames[key] else { continue }
            // One more address of the person; one that another person has stays with them.
            do {
                if case .belongsTo = try library.addEmail(email, for: name) {
                    Log.info("An address picked for a voice is another person's; it stays with them")
                }
            } catch { Log.error("Saving email for \(name) failed: \(error)") }
        }
        // Save the names before the summary request, so a second save made meanwhile starts from them. The new
        // summary takes a while; until it lands, the old one shows the names in place of the letters.
        guard var r = edit(callID, { r in
            for (key, name) in chosen {
                r.speakerNames[key] = name
                r.unknownSpeakers.removeAll { $0 == key }
            }
            // The owner's word: the name no longer comes from the invite.
            r.fromInvite = r.fromInvite.map { $0.filter { chosen[$0] == nil } }.flatMap { $0.isEmpty ? nil : $0 }
            r.replaceSpeakerLabels(renamed)
            return true
        }) else { return }
        save(&r, dir: dir)
        guard let summarizer, r.status == .written, !r.utterances.isEmpty else { return }
        let names = r.speakerNames
        let transcript = MarkdownWriter.transcript(r), title = r.title, id = r.id, known = knownTags()
        guard let s = try? await UsageContext.$callID.withValue(id, operation: {
            try await summarizer.summarize(transcript: transcript, title: title, knownTags: known)
        }), !inFlight.contains(id),
              // Names changed during the request: that save's own summary is newer.
              var latest = edit(id, { $0.speakerNames == names }) else { return }
        latest.apply(s)
        latest.summaryMissing = nil
        save(&latest, dir: dir)
    }

    /// A recording of the same meeting link that ended or started within `MeetingMerge.continuationGap`
    /// of this one is the same meeting, split by a restart or a crash: join them.
    func continueSplitMeeting(_ id: String) async {
        // A meeting made from Gemini's notes has no audio to join: it is never a part of a recording.
        guard let r = try? CallRecord.load(from: paths.callDirectory(id)), r.status == .written, !r.isNotesOnly, let meetingID = r.meetingID else { return }
        let sibling = queue.allRecords().first { other in
            other.id != r.id && other.status == .written && !other.isNotesOnly && other.meetingID == meetingID
                && (abs(r.start.timeIntervalSince(other.end)) <= MeetingMerge.continuationGap
                    || abs(other.start.timeIntervalSince(r.end)) <= MeetingMerge.continuationGap)
        }
        guard let sibling else { return }
        Log.info("Continuing \(sibling.id) and \(r.id): the same meeting, split by a restart")
        await merge(callIDs: [sibling.id, r.id])
    }

    /// Joins meetings that a restart split before automatic continuation existed. One scan, grouped by meeting
    /// link, so a long history is not read once per meeting.
    public func continueSplitMeetings() async {
        finishInterruptedMerges()
        let byMeeting = Dictionary(grouping: queue.allRecords().filter { $0.status == .written && !$0.isNotesOnly && $0.meetingID != nil }, by: { $0.meetingID! })
        for group in byMeeting.values where group.count > 1 {
            for r in group { await continueSplitMeeting(r.id) }
        }
    }

    /// Joins finished or failed meetings into the earliest one: audio, transcript, and speakers. The others
    /// are deleted with their notes, and the joined meeting gets a new summary and note. Returns its ID.
    @discardableResult
    public func merge(callIDs: [String]) async -> String? {
        let records = callIDs.compactMap { try? CallRecord.load(from: paths.callDirectory($0)) }.sorted { $0.start < $1.start }
        guard records.count >= 2, records.count == Set(callIDs).count,
              records.allSatisfy({ $0.status == .written || $0.status == .failed }) else { return nil }
        if let notes = records.first(where: \.isNotesOnly) {
            Log.info("Not joining \(notes.id): it was made from Gemini's notes and has no audio")
            return nil
        }
        // A call whose muted parts are not silenced yet would carry that speech into the joined audio.
        if let held = records.first(where: \.mutedAudioPending) {
            Log.info("Not joining \(held.id): its muted parts are not silenced yet")
            return nil
        }
        let target = records[0]
        let dir = paths.callDirectory(target.id)
        guard records.allSatisfy({ !inFlight.contains($0.id) }),
              !FileManager.default.fileExists(atPath: dir.appendingPathComponent(MergePlan.fileName).path) else { return nil }
        var durations: [String: TimeInterval] = [:]
        for r in records { durations[r.id] = Self.audioLength(paths.callDirectory(r.id)) ?? r.end.timeIntervalSince(r.start) }
        let lengths = records.map { durations[$0.id]! }
        let fm = FileManager.default
        func has(_ r: CallRecord, _ name: String) -> Bool { FileManager.default.fileExists(atPath: paths.callDirectory(r.id).appendingPathComponent(name).path) }
        // A part whose only audio is in the bucket cannot be joined here; the joined recording would hold silence
        // in its place and would then replace the archived one.
        if let away = records.first(where: { r in r.cloudKey != nil && ![Track.me.fileName, Track.them.fileName, Recording.fileName].contains { has(r, $0) } }) {
            Log.error("Not merging \(callIDs): the audio of \(away.id) is only in the cloud archive")
            return nil
        }
        // With raw tracks for every part, the recording is made again from the joined tracks; a joined recording
        // would be silent for a part that never got one. Otherwise a part with tracks gets its recording first.
        let remake = records.allSatisfy { has($0, Track.me.fileName) || has($0, Track.them.fileName) }
        if !remake {
            for r in records where !has(r, Recording.fileName) { Recording.makeIfMissing(in: paths.callDirectory(r.id)) }
        }
        let names = [Track.me.fileName, Track.them.fileName] + (remake ? [] : [Recording.fileName])
        // The plan is saved first, so a crash at any point is finished or undone on the next run; see
        // `finishInterruptedMerges`. The target's files are kept as `premerge-` copies until the record is saved.
        var plan = MergePlan(ids: records.map(\.id), phase: .joining, had: names.filter { has(target, $0) } + (remake && has(target, Recording.fileName) ? [Recording.fileName] : []))
        do {
            try plan.save(in: dir)
            // Joined into temporary files first: the target's own tracks are inputs too.
            var joined: [(URL, URL)] = []
            for name in names {
                let inputs = records.map { r -> URL? in has(r, name) ? paths.callDirectory(r.id).appendingPathComponent(name) : nil }
                guard inputs.contains(where: { $0 != nil }) else { continue }
                let temp = dir.appendingPathComponent("joined-" + name)
                try AudioJoin.join(inputs, durations: lengths, to: temp)
                joined.append((temp, dir.appendingPathComponent(name)))
            }
            // The frames of shared screens move with their part; the first part's own stay as they are until the end.
            var starts: [TimeInterval] = [], total: TimeInterval = 0
            for length in lengths { starts.append(total); total += length }
            // An entry of a deleted screen that stayed in a part's list (a failed save) must not be joined in.
            for r in records { for file in r.deletedScreens ?? [] { FrameStore.removeFrame(file, in: paths.callDirectory(r.id)) } }
            try FrameStore.join(records.map { paths.callDirectory($0.id) }, offsets: starts)
            plan.phase = .replacing
            try plan.save(in: dir)
            if remake, has(target, Recording.fileName) {
                try fm.moveItem(at: Recording.url(in: dir), to: dir.appendingPathComponent(MergePlan.backup + Recording.fileName))
            }
            for (temp, final) in joined {
                if fm.fileExists(atPath: final.path) {
                    try fm.moveItem(at: final, to: dir.appendingPathComponent(MergePlan.backup + final.lastPathComponent))
                }
                try fm.moveItem(at: temp, to: final)
            }
        } catch {
            Log.error("Merging \(callIDs) failed: \(error)")
            rollBackMerge(in: dir, plan)
            return nil
        }
        // Old samples point into the old tracks.
        for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix("clip-") { try? fm.removeItem(at: file) }
        var merged = MeetingMerge.combine(records, durations: durations)
        // The merged record goes beside the old one, then the plan says "saved", then it takes the old one's place:
        // a crash before the plan changes undoes the merge, a crash after it finishes the merge.
        do {
            try merged.save(to: dir, fileName: MergePlan.recordFile)
            plan.phase = .saved
            try plan.save(in: dir)
        } catch {
            Log.error("Saving merged \(target.id) failed: \(error)")
            rollBackMerge(in: dir, plan)
            return nil
        }
        guard finishMerge(in: dir, plan, parts: Array(records.dropFirst())) else { return nil }
        onStep(merged)
        Log.info("Merged \(records.map(\.id).joined(separator: ", ")) into \(target.id)")
        await process(target.id)
        if let latest = try? CallRecord.load(from: dir) { merged = latest }
        return merged.id
    }

    /// What a merge in progress has done, in the target's folder until the merge ends.
    struct MergePlan: Codable {
        static let fileName = "merge.json"
        static let backup = "premerge-"
        static let recordFile = "call.merged.json"
        enum Phase: String, Codable { case joining, replacing, saved }
        var ids: [String]
        var phase: Phase
        /// The audio files the target had before the merge.
        var had: [String]

        func save(in dir: URL) throws {
            try JSONEncoder().encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
        }
    }

    /// Puts the target's own audio back and drops the joined files, as if the merge never started.
    private func rollBackMerge(in dir: URL, _ plan: MergePlan) {
        let fm = FileManager.default
        for name in [Track.me.fileName, Track.them.fileName, Recording.fileName] {
            let final = dir.appendingPathComponent(name), backup = dir.appendingPathComponent(MergePlan.backup + name)
            try? fm.removeItem(at: dir.appendingPathComponent("joined-" + name))
            if fm.fileExists(atPath: backup.path) {
                try? fm.removeItem(at: final)
                try? fm.moveItem(at: backup, to: final)
            } else if !plan.had.contains(name), plan.phase != .joining {
                try? fm.removeItem(at: final)
            }
        }
        FrameStore.undoJoin(in: dir)
        try? fm.removeItem(at: dir.appendingPathComponent(MergePlan.recordFile))
        try? fm.removeItem(at: dir.appendingPathComponent(MergePlan.fileName))
    }

    /// The merged record is saved beside the old one: puts it in place, then removes the other meetings and the
    /// target's old audio.
    @discardableResult
    private func finishMerge(in dir: URL, _ plan: MergePlan, parts: [CallRecord]) -> Bool {
        let fm = FileManager.default
        let saved = dir.appendingPathComponent(MergePlan.recordFile)
        if fm.fileExists(atPath: saved.path) {
            do { _ = try fm.replaceItemAt(dir.appendingPathComponent(CallRecord.fileName), withItemAt: saved) } catch {
                // The plan stays, so the next run tries again; nothing is deleted before the record is in place.
                Log.error("Putting the merged record of \(dir.lastPathComponent) in place failed: \(error)")
                return false
            }
        }
        FrameStore.finishJoin(in: dir)
        for r in parts {
            if let note = r.markdownPath { try? fm.removeItem(atPath: note) }
            try? fm.removeItem(at: paths.callDirectory(r.id))
            heavy.forget(r.id)
            onDiscard(r)
        }
        for name in [Track.me.fileName, Track.them.fileName, Recording.fileName] {
            try? fm.removeItem(at: dir.appendingPathComponent(MergePlan.backup + name))
        }
        try? fm.removeItem(at: dir.appendingPathComponent(MergePlan.fileName))
        return true
    }

    /// A merge that a crash or a quit stopped: undone before the merged record was saved, finished after.
    func finishInterruptedMerges() {
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: paths.audio, includingPropertiesForKeys: nil)) ?? [] {
            let url = dir.appendingPathComponent(MergePlan.fileName)
            guard fm.fileExists(atPath: url.path), !inFlight.contains(dir.lastPathComponent) else { continue }
            guard let data = try? Data(contentsOf: url), let plan = try? JSONDecoder().decode(MergePlan.self, from: data) else {
                Log.error("A merge plan in \(dir.lastPathComponent) could not be read; leaving the folder as it is")
                continue
            }
            if plan.phase == .saved {
                let parts = plan.ids.dropFirst().compactMap { try? CallRecord.load(from: paths.callDirectory($0)) }
                finishMerge(in: dir, plan, parts: parts)
                Log.info("Finished the interrupted merge into \(dir.lastPathComponent)")
            } else {
                rollBackMerge(in: dir, plan)
                Log.info("Undid the interrupted merge into \(dir.lastPathComponent)")
            }
        }
    }

    /// The longest of the call's audio files, in seconds.
    static func audioLength(_ dir: URL) -> TimeInterval? {
        [Track.me.fileName, Track.them.fileName, Recording.fileName].compactMap { name -> TimeInterval? in
            guard let file = try? AVAudioFile(forReading: dir.appendingPathComponent(name)) else { return nil }
            return Double(file.length) / file.processingFormat.sampleRate
        }.max()
    }


    /// Replaces a meeting's tags, without case duplicates, and rewrites its note.
    public func setTags(callID: String, _ tags: [String]) {
        var seen = Set<String>()
        let tags = tags.compactMap(\.nonBlank).filter { seen.insert($0.lowercased()).inserted }
        guard var r = edit(callID, { $0.tags = tags; $0.tagsSetByOwner = true; return true }) else { return }
        save(&r, dir: paths.callDirectory(callID))
    }

    /// Sets the title the owner chose, or clears it when `title` is nil or blank, and renames the note.
    public func setTitle(callID: String, _ title: String?) {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nonBlank
        guard var r = edit(callID, { $0.customTitle = title; return true }) else { return }
        save(&r, dir: paths.callDirectory(callID))
    }

    /// Sets a bookmark's note after the call, or adds a bookmark at `offset` when none is there, and rewrites the note.
    public func setBookmarkNote(callID: String, offset: TimeInterval, note: String) {
        guard var r = edit(callID, { r in
            let time = r.start.addingTimeInterval(offset).formatted(date: .omitted, time: .shortened)
            return r.setBookmarkNote(at: offset, note, markerText: "★ Bookmarked at \(time)")
        }) else { return }
        save(&r, dir: paths.callDirectory(callID))
    }

    /// Takes away the bookmark within a second of `offset` and rewrites the note: the Undo of one the chat added.
    @discardableResult
    public func removeBookmark(callID: String, offset: TimeInterval) -> Bool {
        guard var r = edit(callID, { $0.removeBookmark(at: offset) }) else { return false }
        save(&r, dir: paths.callDirectory(callID))
        return true
    }

    /// Adds a bookmark without a note after the call, from the player. Returns false when one is already within a
    /// second of `offset`, so a double click does not make two.
    @discardableResult
    public func addBookmark(callID: String, offset: TimeInterval) -> Bool {
        guard var r = edit(callID, { r in
            let time = r.start.addingTimeInterval(offset).formatted(date: .omitted, time: .shortened)
            return r.addBookmark(at: offset, markerText: "★ Bookmarked at \(time)")
        }) else { return false }
        save(&r, dir: paths.callDirectory(callID))
        return true
    }

    /// Deletes one shared screen of a finished meeting: its picture, its entry in `frames.json`, and its line in the
    /// transcript. The note is written again. The summary stays as it is; "Regenerate summary" makes a new one
    /// without that screen's text. Returns false when the meeting has no such screen.
    @discardableResult
    public func deleteScreen(callID: String, file: String) -> Bool {
        let dir = paths.callDirectory(callID)
        guard var r = edit(callID, { r in
            let listed = r.screens?.contains { $0.file == file } ?? false
            let known = r.deletedScreens?.contains(file) ?? false
            guard listed || known else { return false }
            r.screens = r.screens?.filter { $0.file != file }
            if !known { r.deletedScreens = (r.deletedScreens ?? []) + [file] }
            // A pause is shown next to a share session; with the screen gone, its session may be gone too.
            r.screenGaps = r.screenGaps.map { ScreenGap.shown($0, screens: r.screens ?? []) }.flatMap { $0.isEmpty ? nil : $0 }
            return listed
        }) else { return false }
        // The record remembers the delete, so an entry that stays in `frames.json` (a failed save, a text step that
        // reads at this moment) is dropped by the next run of that step and never comes back.
        FrameStore.removeFrame(file, in: dir)
        // The record kept for one undo of "Transcribe again" holds the screen's text too.
        if var previous = try? CallRecord.load(from: dir, fileName: Self.previousFileName), previous.screens?.contains(where: { $0.file == file }) == true {
            previous.screens?.removeAll { $0.file == file }
            try? previous.save(to: dir, fileName: Self.previousFileName)
        }
        save(&r, dir: dir)
        return true
    }

    /// Skipped voices stay in the transcript as letters, but the call stops asking for them.
    public func dismissSpeakers(callID: String, keys: [String]) {
        guard var r = edit(callID, { $0.unknownSpeakers.removeAll { keys.contains($0) }; return true }) else { return }
        save(&r, dir: paths.callDirectory(callID))
    }

    /// Asks for skipped voices again.
    public func restoreSpeakers(callID: String, keys: [String]) {
        guard var r = edit(callID, { r in
            r.unknownSpeakers += keys.filter { r.skippedSpeakers.contains($0) }
            return true
        }) else { return }
        save(&r, dir: paths.callDirectory(callID))
    }

    /// Renames a person in every meeting: speaker names, action item owners, and the notes. An email
    /// address is also replaced inside the summary text, where it cannot be part of another word.
    @discardableResult
    public func renamePerson(_ old: String, to new: String) -> Int {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != old else { return 0 }
        var changed = 0
        for record in ProcessingQueue(paths: paths).allRecords() where record.mentions(old) {
            guard var r = edit(record.id, { r in
                for (key, name) in r.speakerNames where name == old { r.speakerNames[key] = new }
                r.actionItems = r.actionItems.map { var a = $0; if a.owner == old { a.owner = new }; return a }
                if old.contains("@") {
                    func swap(_ text: String) -> String { text.replacingOccurrences(of: old, with: new) }
                    r.summary = r.summary.map(swap)
                    r.headline = r.headline.map(swap)
                    r.decisions = r.decisions.map { Decision(text: swap($0.text), at: $0.at) }
                    r.actionItems = r.actionItems.map { var a = $0; a.task = swap(a.task); return a }
                }
                return true
            }) else { continue }
            save(&r, dir: paths.callDirectory(r.id))
            changed += 1
        }
        if changed > 0 { Log.info("Renamed \(old) to \(new) in \(changed) meetings") }
        return changed
    }


    private func save(_ r: inout CallRecord, dir: URL) {
        if let refs = references() {
            let next = refs.refresh(r)
            if next != r, r.status == .written { ReferenceBackup.keep(record: dir, paths: paths) }
            r = next
        }
        do {
            if r.status == .written {
                let url = MarkdownWriter.noteURL(for: r, in: paths.meetings)
                try MarkdownWriter.render(r).write(to: url, atomically: true, encoding: .utf8)
                // A new title gives the note a new name; the old file must not stay as a second note.
                if let old = r.markdownPath, old != url.path { try? FileManager.default.removeItem(atPath: old) }
                r.markdownPath = url.path
            }
            try store(r, dir: dir)
        } catch {
            Log.error("Applying names to \(r.id) failed: \(error)")
        }
    }
}

/// Thrown when a service has no API key. The pipeline waits for the key instead of counting a failed attempt.
public struct MissingAPIKey: Error, CustomStringConvertible {
    public let service: String
    public init(service: String) { self.service = service }
    public var description: String { "No \(service) API key. Run scripts/import-keys.sh, then reopen Mossad." }
}

private extension CallRecord {
    func mentions(_ name: String) -> Bool {
        speakerNames.values.contains(name) || actionItems.contains { $0.owner == name }
    }
}
