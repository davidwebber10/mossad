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

    /// `onStep` receives the record after every save of `call.json`, so the UI can show the live step.
    public init(paths: Paths, transcriber: Transcribing, library: VoiceLibrary, embeddings: EmbeddingProvider,
                calendar: CalendarSource, summarizer: Summarizing?, notify: @escaping @Sendable (CallRecord) -> Void,
                now: @escaping @Sendable () -> Date = Date.init, ownerName: String = "Me", voiceFingerprints: Bool = true,
                onStep: @escaping @Sendable (CallRecord) -> Void = { _ in },
                onDetail: @escaping @Sendable (String, String?) -> Void = { _, _ in },
                onProgress: @escaping @Sendable (String, ProcessingProgress?) -> Void = { _, _ in },
                titles: @escaping @Sendable ([String]) -> [String] = { _ in [] },
                onDiscard: @escaping @Sendable (CallRecord) -> Void = { _ in },
                heavy: HeavyWorkGate = .shared) {
        self.heavy = heavy
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

    /// Marks a recording as archived in the bucket. Through this actor, so a run or an edit in flight keeps the key
    /// and the key never brings back an old copy of the record. False when the record cannot be read.
    @discardableResult
    public func setCloudKey(callID: String, key: String, size: Int64) -> Bool {
        guard let r = edit(callID, { $0.cloudKey = key; $0.cloudSize = size; return true }) else { return false }
        do { try store(r, dir: paths.callDirectory(callID)) } catch {
            Log.error("Saving the archive key of \(callID) failed: \(error)")
            return false
        }
        return true
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
        try r.save(to: dir)
        onStep(r)
    }

    /// Deletes a finished or failed call: its note, audio, and record. A call that is still recording or
    /// processing is refused, so the pipeline never writes into a folder that is gone.
    public func delete(callID: String) -> Bool { remove(callID: callID) != nil }

    /// Deletes like `delete` and returns the record as it was on disk, so the caller can remove what the meeting
    /// has outside this Mac (its archived recording) from the record's own values, not from a list in memory.
    public func remove(callID: String) -> CallRecord? {
        let dir = paths.callDirectory(callID)
        guard let r = try? CallRecord.load(from: dir), r.status == .written || r.status == .failed else { return nil }
        if let note = r.markdownPath { try? FileManager.default.removeItem(atPath: note) }
        do { try FileManager.default.removeItem(at: dir) } catch {
            Log.error("Deleting \(callID) failed: \(error)")
            return nil
        }
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
        // so off this actor.
        let them = dir.appendingPathComponent(Track.them.fileName)
        await waitForQuiet(r.id)
        let themSound = try? await HeavyWork.run { try SoundTimeline.measure(url: them) }
        r.utterances = TranscriptMerger.merge(me: try meResult.get(), them: try themResult.get(), themSound: themSound)
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
        await waitForQuiet(callID)
        let upload = (try? await HeavyWork.run { try UploadAudio.compress(url, into: dir) }) ?? url
        defer { if upload != url { try? FileManager.default.removeItem(at: upload) } }
        let transcriber = transcriber
        // A model on this Mac uses all of the processor for minutes.
        if transcriber.runsOnThisDevice { await waitForQuiet(callID) }
        let job = TranscriptionJobStore(saved: jobs[callID]?[track.rawValue]) { job in await self.saveJob(callID, track, job) }
        do {
            return .success(try await UsageContext.$callID.withValue(callID) {
                try await TranscriptionJob.$store.withValue(job) {
                    try await transcriber.transcribe(file: upload, track: track, speakers: speakers) { stage in
                        Task { await self.stageChanged(callID, track, stage) }
                    }
                }
            })
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
        detail(r.id, "Identifying speakers")
        guard voiceFingerprints else {
            // No fingerprints: the speaker who talks most on the mic is the owner; everyone else stays a letter.
            let talk = Dictionary(r.utterances.map { ($0.speakerKey, $0.end - $0.start) }, uniquingKeysWith: +)
            let owner = talk.filter { $0.key.hasPrefix("me:") }.max { $0.value < $1.value }?.key
            r.speakerNames = owner.map { [$0: ownerName] } ?? [:]
            var keys: [String] = []
            for u in r.utterances where u.speakerKey != owner && !keys.contains(u.speakerKey) { keys.append(u.speakerKey) }
            r.unknownSpeakers = keys
            r.speakerEmbeddings = [:]
            r.status = .identified
            return
        }
        await waitForQuiet(r.id)
        let result = try await identifier.identify(utterances: r.utterances, meURL: dir.appendingPathComponent(Track.me.fileName),
                                                   themURL: dir.appendingPathComponent(Track.them.fileName))
        r.speakerNames = result.names
        r.unknownSpeakers = result.unknown
        r.speakerEmbeddings = result.embeddings
        dropNamedEcho(&r)
        r.status = .identified
    }

    /// A mic voice recognized as someone who is also on the call audio is that person through the speakers.
    /// The echo filter cannot see it when the owner hardly spoke, because then the echo has the most
    /// quiet-time speech on the mic. Someone in the room with the owner is never on the call audio, so stays.
    private func dropNamedEcho(_ r: inout CallRecord) {
        let remote = Set(r.speakerNames.filter { $0.key.hasPrefix("them:") }.values)
        let echo = Set(r.speakerNames.filter { $0.key.hasPrefix("me:") && remote.contains($0.value) && $0.value != ownerName }.keys)
        guard !echo.isEmpty else { return }
        r.utterances.removeAll { echo.contains($0.speakerKey) }
        for key in echo {
            r.speakerNames[key] = nil
            r.speakerEmbeddings[key] = nil
        }
        r.unknownSpeakers.removeAll { echo.contains($0) }
        Log.info("Dropped \(echo.count) mic voices that are people on the call audio")
    }

    /// Adds calendar details and the summary. Returns false when the summary should be retried later.
    private func summarize(_ r: inout CallRecord) async -> Bool {
        if quietRuns[r.id] == nil {
            detail(r.id, "Finding the calendar invite")
            let events = await calendar.events(from: r.start.addingTimeInterval(-600), to: r.end.addingTimeInterval(600))
            if let event = CalendarMatcher.bestEvent(for: r.platform, meetingID: r.meetingID, start: r.start, end: r.end, in: events) {
                r.calendarTitle = event.title
                r.attendees = event.attendees
            }
        }
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

    private func knownTags() -> [String] { Tags.known(queue.allRecords()) }

    /// Processor-heavy work waits here while a call records.
    private func waitForQuiet(_ id: String) async {
        guard await heavy.isHeld else { return }
        detail(id, "Waiting for the current call to end")
        await heavy.waitForQuiet("the work on \(id)")
    }

    private func write(_ r: inout CallRecord) async throws {
        detail(r.id, "Writing the note")
        let url = MarkdownWriter.noteURL(for: r, in: paths.meetings)
        if let old = r.markdownPath, old != url.path { try? FileManager.default.removeItem(atPath: old) }
        try MarkdownWriter.render(r).write(to: url, atomically: true, encoding: .utf8)
        r.markdownPath = url.path
        r.status = .written
        Log.info("Wrote \(url.lastPathComponent)")
        // A mix and an AAC encode of the whole call, off this actor. While a call records, the note does not wait
        // for it: the app makes the missing recording when no call records (`Recording.backfill`), and until then
        // the player mixes the two tracks.
        if await heavy.isHeld {
            Log.info("A call records; the recording of \(r.id) is made later")
        } else {
            detail(r.id, "Making the recording")
            let dir = paths.callDirectory(r.id)
            try? await HeavyWork.run { Recording.makeIfMissing(in: dir) }
        }
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
        for (key, raw) in names {
            let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty else { continue }
            // Someone saved already, by email or by name in other case or spacing, stays one person.
            let name = library.existingName(name: typed, email: emails[key]) ?? typed
            if let old = before[key], old != name, current.speakerNames[key] == nil { renamed[old] = name }
            chosen[key] = name
            if let e = current.speakerEmbeddings[key] {
                do { try library.add(e, to: name) } catch { Log.error("Saving voice for \(name) failed: \(error)") }
            }
        }
        for (key, email) in emails {
            guard let name = chosen[key] ?? current.speakerNames[key] else { continue }
            do { try library.setEmail(email, for: name) } catch { Log.error("Saving email for \(name) failed: \(error)") }
        }
        // Save the names before the summary request, so a second save made meanwhile starts from them. The new
        // summary takes a while; until it lands, the old one shows the names in place of the letters.
        guard var r = edit(callID, { r in
            for (key, name) in chosen {
                r.speakerNames[key] = name
                r.unknownSpeakers.removeAll { $0 == key }
            }
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
        guard let r = try? CallRecord.load(from: paths.callDirectory(id)), r.status == .written, let meetingID = r.meetingID else { return }
        let sibling = queue.allRecords().first { other in
            other.id != r.id && other.status == .written && other.meetingID == meetingID
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
        let byMeeting = Dictionary(grouping: queue.allRecords().filter { $0.status == .written && $0.meetingID != nil }, by: { $0.meetingID! })
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
        for r in parts {
            if let note = r.markdownPath { try? fm.removeItem(atPath: note) }
            try? fm.removeItem(at: paths.callDirectory(r.id))
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
                r.actionItems = r.actionItems.map { ActionItem(owner: $0.owner == old ? new : $0.owner, task: $0.task) }
                if old.contains("@") {
                    func swap(_ text: String) -> String { text.replacingOccurrences(of: old, with: new) }
                    r.summary = r.summary.map(swap)
                    r.headline = r.headline.map(swap)
                    r.decisions = r.decisions.map { Decision(text: swap($0.text), at: $0.at) }
                    r.actionItems = r.actionItems.map { ActionItem(owner: $0.owner, task: swap($0.task)) }
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
