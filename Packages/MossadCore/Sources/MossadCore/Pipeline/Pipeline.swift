import AVFoundation
import Foundation

/// Turns recorded calls into named, summarized Markdown files. Each step saves `call.json`,
/// so a call resumes where it stopped after a failure or a restart.
public actor Pipeline {
    static let maxSummaryAttempts = 3
    /// After this many failed attempts at one step (about four days of backoff) the call is marked failed.
    public static let maxAttempts = 8
    /// Tracks shorter than this have no speech worth uploading.
    static let minimumTrackDuration: TimeInterval = 1

    private var inFlight: Set<String> = []

    private let paths: Paths
    private let queue: ProcessingQueue
    private let transcriber: Transcribing
    private let library: VoiceLibrary
    private let identifier: SpeakerIdentifier
    private let calendar: CalendarSource
    private let summarizer: Summarizing?
    private let notify: @Sendable (CallRecord) -> Void
    private let now: @Sendable () -> Date
    private let ownerName: String
    private let voiceFingerprints: Bool
    private let onStep: @Sendable (CallRecord) -> Void
    /// A short text for the sub-step in progress (call ID, text; nil when processing stops). Shown, not saved.
    private let onDetail: @Sendable (String, String?) -> Void
    private var stages: [String: [Track: TranscriptionStage]] = [:]
    /// Calls in the transcription step; a late stage update after it must not overwrite the next sub-step.
    private var transcribing: Set<String> = []

    /// `onStep` receives the record after every save of `call.json`, so the UI can show the live step.
    public init(paths: Paths, transcriber: Transcribing, library: VoiceLibrary, embeddings: EmbeddingProvider,
                calendar: CalendarSource, summarizer: Summarizing?, notify: @escaping @Sendable (CallRecord) -> Void,
                now: @escaping @Sendable () -> Date = Date.init, ownerName: String = "Me", voiceFingerprints: Bool = true,
                onStep: @escaping @Sendable (CallRecord) -> Void = { _ in },
                onDetail: @escaping @Sendable (String, String?) -> Void = { _, _ in }) {
        self.onStep = onStep
        self.onDetail = onDetail
        self.paths = paths
        self.queue = ProcessingQueue(paths: paths)
        self.transcriber = transcriber
        self.library = library
        self.identifier = SpeakerIdentifier(library: library, provider: embeddings, ownerName: ownerName)
        self.ownerName = ownerName
        self.voiceFingerprints = voiceFingerprints
        self.calendar = calendar
        self.summarizer = summarizer
        self.notify = notify
        self.now = now
    }

    public func runPending() async {
        for r in queue.pending(now: now()) { await process(r.id) }
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
        }
        // `process` suspends at every await; without this a timer run and a call-end run could overlap.
        guard inFlight.insert(id).inserted else { return }
        defer { inFlight.remove(id) }
        let dir = paths.callDirectory(id)
        guard var r = try? CallRecord.load(from: dir) else { return }
        do {
            while r.status != .written {
                switch r.status {
                case .recorded: try await transcribe(&r, dir: dir)
                case .transcribed: try await identify(&r, dir: dir)
                case .identified:
                    guard await summarize(&r) else {
                        try store(r, dir: dir)
                        return
                    }
                case .summarized: try write(&r)
                case .recording, .failed, .written: return
                }
                r.attempts = 0
                r.nextAttempt = nil
                r.failureReason = nil
                try store(r, dir: dir)
            }
        } catch let error as MissingAPIKey {
            // Not the call's fault: wait for the key without using up attempts or a backoff delay.
            Log.error("Processing \(id) waits for an API key")
            r.failureReason = Self.failureReason(error)
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
            try? store(r, dir: dir)
        }
    }

    /// Asks Claude for a new summary of a finished meeting, for example after the summary format changed.
    /// The transcript and speakers stay; only the summary step and the note run again.
    public func regenerateSummary(_ id: String) async {
        let dir = paths.callDirectory(id)
        guard var r = try? CallRecord.load(from: dir), r.status == .written, !r.utterances.isEmpty else { return }
        r.status = .identified
        do { try store(r, dir: dir) } catch { return }
        await process(id)
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

    private func store(_ r: CallRecord, dir: URL) throws {
        try r.save(to: dir)
        onStep(r)
    }

    /// Deletes a finished or failed call: its note, audio, and record. A call that is still recording or
    /// processing is refused, so the pipeline never writes into a folder that is gone.
    public func delete(callID: String) -> Bool {
        let dir = paths.callDirectory(callID)
        guard let r = try? CallRecord.load(from: dir), r.status == .written || r.status == .failed else { return false }
        if let note = r.markdownPath { try? FileManager.default.removeItem(atPath: note) }
        do { try FileManager.default.removeItem(at: dir) } catch {
            Log.error("Deleting \(callID) failed: \(error)")
            return false
        }
        Log.info("Deleted call \(callID)")
        return true
    }

    private func transcribe(_ r: inout CallRecord, dir: URL) async throws {
        transcribing.insert(r.id)
        async let me = transcribeIfNeeded(r.meUtterances, track: .me, dir: dir, callID: r.id)
        async let them = transcribeIfNeeded(r.themUtterances, track: .them, dir: dir, callID: r.id)
        let (meResult, themResult) = await (me, them)
        // Keep whichever track succeeded, then fail if either did.
        if case .success(let u) = meResult { r.meUtterances = u }
        if case .success(let u) = themResult { r.themUtterances = u }
        try store(r, dir: dir)
        transcribing.remove(r.id)
        onDetail(r.id, "Joining the two tracks")
        // Without the them track (deleted or unreadable) only the word rule removes echo.
        let themSound = try? SoundTimeline.measure(url: dir.appendingPathComponent(Track.them.fileName))
        r.utterances = TranscriptMerger.merge(me: try meResult.get(), them: try themResult.get(), themSound: themSound)
        r.status = .transcribed
        Log.info("Transcribed \(r.id): \(r.utterances.count) utterances")
    }

    private func transcribeIfNeeded(_ done: [Utterance]?, track: Track, dir: URL, callID: String) async -> Result<[Utterance], Error> {
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
        do {
            return .success(try await UsageContext.$callID.withValue(callID) {
                try await transcriber.transcribe(file: url, track: track) { stage in
                    Task { await self.stageChanged(callID, track, stage) }
                }
            })
        } catch { return .failure(error) }
    }

    /// "Uploading your mic to AssemblyAI", or both tracks when they differ.
    private func stageChanged(_ id: String, _ track: Track, _ stage: TranscriptionStage) {
        guard transcribing.contains(id) else { return }
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
        onDetail(r.id, "Identifying speakers")
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
        onDetail(r.id, "Finding the calendar invite")
        let events = await calendar.events(from: r.start.addingTimeInterval(-600), to: r.end.addingTimeInterval(600))
        if let event = CalendarMatcher.bestEvent(for: r.platform, meetingID: r.meetingID, start: r.start, end: r.end, in: events) {
            r.calendarTitle = event.title
            r.attendees = event.attendees
        }
        if summarizer != nil, !r.utterances.isEmpty { onDetail(r.id, "Claude is writing the summary") }
        if let summarizer, !r.utterances.isEmpty {
            do {
                let transcript = MarkdownWriter.transcript(r), title = r.title, known = knownTags()
                let s = try await UsageContext.$callID.withValue(r.id) {
                    try await summarizer.summarize(transcript: transcript, title: title, knownTags: known)
                }
                r.apply(s)
            } catch {
                Log.error("Summary for \(r.id) failed: \(error)")
                r.failureReason = Self.failureReason(error)
                queue.markFailure(&r, now: now())
                if r.attempts < Self.maxSummaryAttempts { return false }
                Log.info("Writing \(r.id) without a summary after \(r.attempts) attempts")
            }
        }
        r.status = .summarized
        return true
    }

    private func knownTags() -> [String] { Tags.known(queue.allRecords()) }

    private func write(_ r: inout CallRecord) throws {
        onDetail(r.id, "Writing the note")
        let url = paths.meetings.appendingPathComponent(MarkdownWriter.fileName(for: r))
        if let old = r.markdownPath, old != url.path { try? FileManager.default.removeItem(atPath: old) }
        try MarkdownWriter.render(r).write(to: url, atomically: true, encoding: .utf8)
        r.markdownPath = url.path
        r.status = .written
        Log.info("Wrote \(url.lastPathComponent)")
        onDetail(r.id, "Making the recording")
        Recording.makeIfMissing(in: paths.callDirectory(r.id))
        // Without fingerprints a name is never learned, so asking after every call would only nag.
        if voiceFingerprints, !r.unknownSpeakers.isEmpty { notify(r) }
    }

    /// Applies names chosen by David, learns those voices, and rewrites the summary and the file.
    /// `emails` uses the same speaker keys as `names`; each email is stored on that person's voice profile.
    public func applyNames(callID: String, names: [String: String], emails: [String: String] = [:]) async {
        let dir = paths.callDirectory(callID)
        guard var r = try? CallRecord.load(from: dir) else { return }
        for (key, raw) in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            r.speakerNames[key] = name
            r.unknownSpeakers.removeAll { $0 == key }
            if let e = r.speakerEmbeddings[key] {
                do { try library.add(e, to: name) } catch { Log.error("Saving voice for \(name) failed: \(error)") }
            }
        }
        for (key, email) in emails {
            guard let name = r.speakerNames[key] else { continue }
            do { try library.setEmail(email, for: name) } catch { Log.error("Saving email for \(name) failed: \(error)") }
        }
        // Save the names before the summary request, so a second save made meanwhile starts from them.
        save(&r, dir: dir)
        guard let summarizer, r.status == .written, !r.utterances.isEmpty else { return }
        let names = r.speakerNames
        let transcript = MarkdownWriter.transcript(r), title = r.title, id = r.id, known = knownTags()
        guard let s = try? await UsageContext.$callID.withValue(id, operation: {
            try await summarizer.summarize(transcript: transcript, title: title, knownTags: known)
        }),
              var latest = try? CallRecord.load(from: dir), latest.speakerNames == names else { return }
        // Names changed during the request: that save's own summary is newer.
        latest.apply(s)
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

    /// Joins meetings that a restart split before automatic continuation existed.
    public func continueSplitMeetings() async {
        for r in queue.allRecords() where r.status == .written && r.meetingID != nil {
            await continueSplitMeeting(r.id)
        }
    }

    /// Joins finished or failed meetings into the earliest one: audio, transcript, and speakers. The others
    /// are deleted with their notes, and the joined meeting gets a new summary and note. Returns its ID.
    @discardableResult
    public func merge(callIDs: [String]) async -> String? {
        let records = callIDs.compactMap { try? CallRecord.load(from: paths.callDirectory($0)) }.sorted { $0.start < $1.start }
        guard records.count >= 2, records.count == Set(callIDs).count,
              records.allSatisfy({ $0.status == .written || $0.status == .failed }) else { return nil }
        let target = records[0]
        let dir = paths.callDirectory(target.id)
        var durations: [String: TimeInterval] = [:]
        for r in records { durations[r.id] = Self.audioLength(paths.callDirectory(r.id)) ?? r.end.timeIntervalSince(r.start) }
        let lengths = records.map { durations[$0.id]! }
        do {
            // Joined into temporary files first: the target's own tracks are inputs too.
            var joined: [(URL, URL)] = []
            for name in [Track.me.fileName, Track.them.fileName, Recording.fileName] {
                let inputs = records.map { r -> URL? in
                    let url = paths.callDirectory(r.id).appendingPathComponent(name)
                    return FileManager.default.fileExists(atPath: url.path) ? url : nil
                }
                guard inputs.contains(where: { $0 != nil }) else { continue }
                let temp = dir.appendingPathComponent("joined-" + name)
                try AudioJoin.join(inputs, durations: lengths, to: temp)
                joined.append((temp, dir.appendingPathComponent(name)))
            }
            for (temp, final) in joined {
                try? FileManager.default.removeItem(at: final)
                try FileManager.default.moveItem(at: temp, to: final)
            }
        } catch {
            Log.error("Merging \(callIDs) failed: \(error)")
            for name in [Track.me.fileName, Track.them.fileName, Recording.fileName] {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("joined-" + name))
            }
            return nil
        }
        // Old samples point into the old tracks.
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix("clip-") { try? FileManager.default.removeItem(at: file) }
        var merged = MeetingMerge.combine(records, durations: durations)
        do { try store(merged, dir: dir) } catch {
            Log.error("Saving merged \(target.id) failed: \(error)")
            return nil
        }
        for r in records.dropFirst() {
            if let note = r.markdownPath { try? FileManager.default.removeItem(atPath: note) }
            try? FileManager.default.removeItem(at: paths.callDirectory(r.id))
        }
        Log.info("Merged \(records.map(\.id).joined(separator: ", ")) into \(target.id)")
        await process(target.id)
        if let latest = try? CallRecord.load(from: dir) { merged = latest }
        return merged.id
    }

    /// The longest of the call's audio files, in seconds.
    static func audioLength(_ dir: URL) -> TimeInterval? {
        [Track.me.fileName, Track.them.fileName, Recording.fileName].compactMap { name -> TimeInterval? in
            guard let file = try? AVAudioFile(forReading: dir.appendingPathComponent(name)) else { return nil }
            return Double(file.length) / file.processingFormat.sampleRate
        }.max()
    }

    /// Skipped voices stay in the transcript as letters, but the call stops asking for them.
    /// Replaces a meeting's tags, without case duplicates, and rewrites its note.
    public func setTags(callID: String, _ tags: [String]) {
        let dir = paths.callDirectory(callID)
        guard var r = try? CallRecord.load(from: dir) else { return }
        var seen = Set<String>()
        r.tags = tags.compactMap(\.nonBlank).filter { seen.insert($0.lowercased()).inserted }
        save(&r, dir: dir)
    }

    public func dismissSpeakers(callID: String, keys: [String]) {
        let dir = paths.callDirectory(callID)
        guard var r = try? CallRecord.load(from: dir) else { return }
        r.unknownSpeakers.removeAll { keys.contains($0) }
        save(&r, dir: dir)
    }

    /// Renames a person in every meeting: speaker names, action item owners, and the notes. An email
    /// address is also replaced inside the summary text, where it cannot be part of another word.
    @discardableResult
    public func renamePerson(_ old: String, to new: String) -> Int {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != old else { return 0 }
        var changed = 0
        for record in ProcessingQueue(paths: paths).allRecords() where record.mentions(old) {
            var r = record
            for (key, name) in r.speakerNames where name == old { r.speakerNames[key] = new }
            r.actionItems = r.actionItems.map { ActionItem(owner: $0.owner == old ? new : $0.owner, task: $0.task) }
            if old.contains("@") {
                func swap(_ text: String) -> String { text.replacingOccurrences(of: old, with: new) }
                r.summary = r.summary.map(swap)
                r.headline = r.headline.map(swap)
                r.decisions = r.decisions.map(swap)
                r.actionItems = r.actionItems.map { ActionItem(owner: $0.owner, task: swap($0.task)) }
            }
            save(&r, dir: paths.callDirectory(r.id))
            changed += 1
        }
        if changed > 0 { Log.info("Renamed \(old) to \(new) in \(changed) meetings") }
        return changed
    }

    private func save(_ r: inout CallRecord, dir: URL) {
        do {
            if r.status == .written {
                let url = paths.meetings.appendingPathComponent(MarkdownWriter.fileName(for: r))
                try MarkdownWriter.render(r).write(to: url, atomically: true, encoding: .utf8)
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
