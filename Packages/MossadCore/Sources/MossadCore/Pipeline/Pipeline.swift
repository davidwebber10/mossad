import Foundation

/// Turns recorded calls into named, summarized Markdown files. Each step saves `call.json`,
/// so a call resumes where it stopped after a failure or a restart.
public actor Pipeline {
    static let maxSummaryAttempts = 3

    private let paths: Paths
    private let queue: ProcessingQueue
    private let transcriber: Transcribing
    private let library: VoiceLibrary
    private let identifier: SpeakerIdentifier
    private let calendar: CalendarSource
    private let summarizer: Summarizing?
    private let notify: @Sendable (CallRecord) -> Void
    private let now: @Sendable () -> Date

    public init(paths: Paths, transcriber: Transcribing, library: VoiceLibrary, embeddings: EmbeddingProvider,
                calendar: CalendarSource, summarizer: Summarizing?, notify: @escaping @Sendable (CallRecord) -> Void,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.paths = paths
        self.queue = ProcessingQueue(paths: paths)
        self.transcriber = transcriber
        self.library = library
        self.identifier = SpeakerIdentifier(library: library, provider: embeddings)
        self.calendar = calendar
        self.summarizer = summarizer
        self.notify = notify
        self.now = now
    }

    public func runPending() async {
        for r in queue.pending(now: now()) { await process(r.id) }
    }

    public func process(_ id: String) async {
        let dir = paths.callDirectory(id)
        guard var r = try? CallRecord.load(from: dir) else { return }
        do {
            while r.status != .written {
                switch r.status {
                case .recorded: try await transcribe(&r, dir: dir)
                case .transcribed: try await identify(&r, dir: dir)
                case .identified:
                    guard await summarize(&r) else {
                        try r.save(to: dir)
                        return
                    }
                case .summarized: try write(&r)
                case .recording, .failed, .written: return
                }
                r.attempts = 0
                r.nextAttempt = nil
                try r.save(to: dir)
            }
        } catch {
            Log.error("Processing \(id) failed at \(r.status.rawValue): \(error)")
            queue.markFailure(&r, now: now())
            try? r.save(to: dir)
        }
    }

    private func transcribe(_ r: inout CallRecord, dir: URL) async throws {
        async let me = transcriber.transcribe(file: dir.appendingPathComponent(Track.me.fileName), track: .me)
        async let them = transcriber.transcribe(file: dir.appendingPathComponent(Track.them.fileName), track: .them)
        r.utterances = TranscriptMerger.merge(me: try await me, them: try await them)
        r.status = .transcribed
        Log.info("Transcribed \(r.id): \(r.utterances.count) utterances")
    }

    private func identify(_ r: inout CallRecord, dir: URL) async throws {
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
        if let event = CalendarMatcher.bestEvent(for: r.platform, start: r.start, end: r.end, in: events) {
            r.calendarTitle = event.title
            r.attendees = event.attendees
        }
        if let summarizer, !r.utterances.isEmpty {
            do {
                let s = try await summarizer.summarize(transcript: MarkdownWriter.transcript(r), title: r.title)
                r.summary = s.summary
                r.actionItems = s.actionItems
            } catch {
                Log.error("Summary for \(r.id) failed: \(error)")
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
        if !r.unknownSpeakers.isEmpty { notify(r) }
    }

    /// Applies names chosen by David, learns those voices, and rewrites the summary and the file.
    public func applyNames(callID: String, names: [String: String]) async {
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
        if let summarizer, r.status == .written, !r.utterances.isEmpty {
            if let s = try? await summarizer.summarize(transcript: MarkdownWriter.transcript(r), title: r.title) {
                r.summary = s.summary
                r.actionItems = s.actionItems
            }
        }
        do {
            if r.status == .written {
                let url = paths.meetings.appendingPathComponent(MarkdownWriter.fileName(for: r))
                try MarkdownWriter.render(r).write(to: url, atomically: true, encoding: .utf8)
                r.markdownPath = url.path
            }
            try r.save(to: dir)
        } catch {
            Log.error("Applying names to \(callID) failed: \(error)")
        }
    }
}
