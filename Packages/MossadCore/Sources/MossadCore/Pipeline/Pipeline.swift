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

    /// `onStep` receives the record after every save of `call.json`, so the UI can show the live step.
    public init(paths: Paths, transcriber: Transcribing, library: VoiceLibrary, embeddings: EmbeddingProvider,
                calendar: CalendarSource, summarizer: Summarizing?, notify: @escaping @Sendable (CallRecord) -> Void,
                now: @escaping @Sendable () -> Date = Date.init, ownerName: String = "Me", voiceFingerprints: Bool = true,
                onStep: @escaping @Sendable (CallRecord) -> Void = { _ in }) {
        self.onStep = onStep
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
        async let me = transcribeIfNeeded(r.meUtterances, track: .me, dir: dir)
        async let them = transcribeIfNeeded(r.themUtterances, track: .them, dir: dir)
        let (meResult, themResult) = await (me, them)
        // Keep whichever track succeeded, then fail if either did.
        if case .success(let u) = meResult { r.meUtterances = u }
        if case .success(let u) = themResult { r.themUtterances = u }
        try store(r, dir: dir)
        // Without the them track (deleted or unreadable) only the word rule removes echo.
        let themSound = try? SoundTimeline.measure(url: dir.appendingPathComponent(Track.them.fileName))
        r.utterances = TranscriptMerger.merge(me: try meResult.get(), them: try themResult.get(), themSound: themSound)
        r.status = .transcribed
        Log.info("Transcribed \(r.id): \(r.utterances.count) utterances")
    }

    private func transcribeIfNeeded(_ done: [Utterance]?, track: Track, dir: URL) async -> Result<[Utterance], Error> {
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
        do { return .success(try await transcriber.transcribe(file: url, track: track)) } catch { return .failure(error) }
    }

    private func identify(_ r: inout CallRecord, dir: URL) async throws {
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
        r.status = .identified
    }

    /// Adds calendar details and the summary. Returns false when the summary should be retried later.
    private func summarize(_ r: inout CallRecord) async -> Bool {
        let events = await calendar.events(from: r.start.addingTimeInterval(-600), to: r.end.addingTimeInterval(600))
        if let event = CalendarMatcher.bestEvent(for: r.platform, meetingID: r.meetingID, start: r.start, end: r.end, in: events) {
            r.calendarTitle = event.title
            r.attendees = event.attendees
        }
        if let summarizer, !r.utterances.isEmpty {
            do {
                let s = try await summarizer.summarize(transcript: MarkdownWriter.transcript(r), title: r.title)
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

    private func write(_ r: inout CallRecord) throws {
        let url = paths.meetings.appendingPathComponent(MarkdownWriter.fileName(for: r))
        if let old = r.markdownPath, old != url.path { try? FileManager.default.removeItem(atPath: old) }
        try MarkdownWriter.render(r).write(to: url, atomically: true, encoding: .utf8)
        r.markdownPath = url.path
        r.status = .written
        Log.info("Wrote \(url.lastPathComponent)")
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
        guard let s = try? await summarizer.summarize(transcript: MarkdownWriter.transcript(r), title: r.title),
              var latest = try? CallRecord.load(from: dir), latest.speakerNames == names else { return }
        // Names changed during the request: that save's own summary is newer.
        latest.apply(s)
        save(&latest, dir: dir)
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
