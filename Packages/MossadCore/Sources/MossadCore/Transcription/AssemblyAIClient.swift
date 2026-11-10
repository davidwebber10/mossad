import AVFoundation
import Foundation

/// Where a track is in AssemblyAI's batch process, for the progress line.
public enum TranscriptionStage: Equatable, Sendable {
    /// The share of the file sent so far, when known.
    case uploading(Double?)
    case queued, transcribing
}

public protocol Transcribing: Sendable {
    var serviceName: String { get }
    var runsOnThisDevice: Bool { get }
    func transcribe(file: URL, track: Track, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [Utterance]
    /// `speakers`: how many voices the track holds, when the person said so. Services that cannot use it ignore it.
    func transcribe(file: URL, track: Track, speakers: Int?, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [Utterance]
}

extension Transcribing {
    /// The name in the progress line, such as "Deepgram is transcribing".
    public var serviceName: String { "AssemblyAI" }

    /// True for a model that runs on this Mac: its work waits while a call records.
    public var runsOnThisDevice: Bool { false }

    public func transcribe(file: URL, track: Track, speakers: Int?, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [Utterance] {
        try await transcribe(file: file, track: track, progress: progress)
    }

    public func transcribe(file: URL, track: Track) async throws -> [Utterance] {
        try await transcribe(file: file, track: track, progress: { _ in })
    }
}

/// Where a transcription keeps the service's job id while the job runs, so a quit or a crash during the wait
/// polls the same job on the next run instead of paying for a second one. The pipeline sets it per track.
public struct TranscriptionJobStore: Sendable {
    /// The job saved by an earlier run, if any.
    public var saved: String?
    /// Saves the new job id, or clears it (nil) when the job ended without a result.
    public var save: @Sendable (String?) async -> Void

    public init(saved: String?, save: @escaping @Sendable (String?) async -> Void) {
        self.saved = saved
        self.save = save
    }
}

public enum TranscriptionJob {
    @TaskLocal public static var store: TranscriptionJobStore?
}

/// Batch transcription with speaker labels through the AssemblyAI v2 REST API.
public struct AssemblyAIClient: Transcribing {
    static let base = URL(string: "https://api.assemblyai.com/v2")!
    /// The mic hears one room (a 12-person meeting is normal). Without a cap, a long room meeting once split into 137 voices.
    static let maxRoomSpeakers = 20

    private let apiKey: String
    private let session: URLSession
    private let pollInterval: Duration
    private let retryPause: Duration
    /// Uploads per attempt. A slow or dropping network (a plane) fails an upload now and then.
    static let uploadTries = 3
    private let usage: UsageLog?
    /// The longest wait for one job; nil uses three times the audio's length, at least half an hour.
    private let maxWait: TimeInterval?
    /// Polls per status check: one dropped connection (the Mac sleeps after a call) must not fail a paid job.
    static let pollTries = 5

    public init(apiKey: String, session: URLSession = .shared, pollInterval: Duration = .seconds(5), usage: UsageLog? = nil,
                retryPause: Duration = .seconds(10), maxWait: TimeInterval? = nil) {
        self.maxWait = maxWait
        self.retryPause = retryPause
        self.usage = usage
        self.apiKey = apiKey
        self.session = session
        self.pollInterval = pollInterval
    }

    public func transcribe(file: URL, track: Track, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [Utterance] {
        try await transcribe(file: file, track: track, speakers: nil, progress: progress)
    }

    public func transcribe(file: URL, track: Track, speakers: Int?, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [Utterance] {
        let jobs = TranscriptionJob.store
        var job: TranscriptResponse
        if let saved = jobs?.saved, let resumed = try await resume(saved) {
            Log.info("Resuming AssemblyAI job \(saved) for the \(track.rawValue) track")
            job = resumed
        } else {
            job = try await create(file: file, track: track, speakers: speakers, progress: progress)
            await jobs?.save(job.id)
        }
        let limit = maxWait ?? Self.maxWait(for: file)
        let clock = ContinuousClock(), began = clock.now
        while true {
            switch job.status {
            case "completed":
                usage?.record(service: .assemblyai, purpose: .transcription, model: job.speech_model, audioSeconds: job.audio_duration)
                return (job.utterances ?? []).flatMap { Self.split($0, track: track) }
            case "error":
                await jobs?.save(nil)
                throw TranscriptionError.failed(job.error ?? "unknown error")
            default:
                if clock.now - began > .seconds(limit) {
                    // A job that never ends must not hold the call forever; the next attempt starts a new one.
                    await jobs?.save(nil)
                    throw TranscriptionError.failed("no result after \(Int(limit / 60)) minutes")
                }
                progress(job.status == "queued" ? .queued : .transcribing)
                try await Task.sleep(for: pollInterval)
                job = try await poll(job.id)
            }
        }
    }

    /// Three times the audio's length, at least 30 minutes.
    static func maxWait(for file: URL) -> TimeInterval {
        let seconds = (try? AVAudioFile(forReading: file)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
        return max(1800, seconds * 3)
    }

    /// The saved job, or nil when AssemblyAI no longer knows it (a new job starts). A dropped connection throws.
    private func resume(_ id: String) async throws -> TranscriptResponse? {
        do {
            let job = try await poll(id)
            return job.status == "error" ? nil : job
        } catch TranscriptionError.http(let status, _) where status == 404 || status == 400 {
            // Only "no such job" starts a new, paid job. A busy answer (429, 408) throws, and the saved job is kept.
            return nil
        }
    }

    private func poll(_ id: String) async throws -> TranscriptResponse {
        for attempt in 1... {
            do {
                return try await send(request("transcript/\(id)", method: "GET"), body: nil)
            } catch {
                guard attempt < Self.pollTries, Self.isPassing(error) else { throw error }
                Log.info("Checking AssemblyAI job \(id) failed (\(error.localizedDescription)); trying again")
                try await Task.sleep(for: retryPause)
            }
        }
        fatalError("unreachable")
    }

    private func create(file: URL, track: Track, speakers: Int?, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> TranscriptResponse {
        progress(.uploading(0))
        let uploadURL = try await upload(file, progress: progress)
        var body: [String: Any] = [
            "audio_url": uploadURL.upload_url,
            "speaker_labels": true,
            // Keeps "um" and "uh" so the coach can count them.
            "disfluencies": true,
            "language_detection": false,
            "language_code": "en_us",
        ]
        if let speakers {
            body["speakers_expected"] = speakers
        } else if track == .me {
            body["speaker_options"] = ["max_speakers_expected": Self.maxRoomSpeakers]
        }
        let create = try JSONSerialization.data(withJSONObject: body)
        return try await send(request("transcript", method: "POST", json: true), body: create)
    }

    private func upload(_ file: URL, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> UploadResponse {
        for attempt in 1... {
            do {
                return try await send(request("upload", method: "POST"), file: file, sent: { progress(.uploading($0)) })
            } catch {
                guard attempt < Self.uploadTries, Self.isPassing(error) else { throw error }
                Log.info("Upload to AssemblyAI failed (\(error.localizedDescription)); trying again")
                progress(.uploading(0))
                try await Task.sleep(for: retryPause)
            }
        }
        fatalError("unreachable")
    }

    /// A dropped connection or a server error, which can pass; not a bad key or a bad request.
    static func isPassing(_ error: Error) -> Bool {
        if case TranscriptionError.http(let status, _) = error { return status >= 500 || status == 429 || status == 408 }
        return error is URLError
    }

    private func request(_ path: String, method: String, json: Bool = false) -> URLRequest {
        var r = URLRequest(url: Self.base.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue(apiKey, forHTTPHeaderField: "Authorization")
        if json { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        r.timeoutInterval = 300
        return r
    }

    /// Uploads stream from disk, so an hour-long track is never held in memory.
    private func send<T: Decodable>(_ request: URLRequest, body: Data? = nil, file: URL? = nil,
                                    sent: (@Sendable (Double) -> Void)? = nil) async throws -> T {
        let (data, response) = if let file {
            try await session.upload(for: request, fromFile: file, delegate: sent.map(UploadProgress.init))
        } else if let body {
            try await session.upload(for: request, from: body)
        } else {
            try await session.data(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw TranscriptionError.http(status, String(decoding: data.prefix(500), as: UTF8.self))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct UploadResponse: Decodable { let upload_url: String }

    /// Reports the share of an upload sent, at most once per whole percent.
    final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let report: @Sendable (Double) -> Void
        private var last = -1

        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                        totalBytesExpectedToSend: Int64) {
            guard totalBytesExpectedToSend > 0 else { return }
            let percent = Int(totalBytesSent * 100 / totalBytesExpectedToSend)
            guard percent != last else { return }
            last = percent
            report(Double(percent) / 100)
        }
    }

    private struct TranscriptResponse: Decodable {
        let id: String
        let status: String
        let error: String?
        let utterances: [RawUtterance]?
        /// What AssemblyAI bills, in seconds.
        let audio_duration: Double?
        let speech_model: String?
    }

    /// Splits an utterance where the words pause longer than this (AssemblyAI joins a speaker's
    /// sentences across long silences, which on a single-speaker track can span minutes).
    static let maxWordGap = 1.5

    /// Times come from the words: an utterance's own start can include the silence before it.
    static func split(_ u: RawUtterance, track: Track) -> [Utterance] {
        guard let words = u.words, !words.isEmpty else {
            return [Utterance(track: track, speakerLabel: u.speaker, start: Double(u.start) / 1000, end: Double(u.end) / 1000, text: u.text)]
        }
        var groups: [[RawWord]] = [[words[0]]]
        for (previous, word) in zip(words, words.dropFirst()) {
            if Double(word.start - previous.end) / 1000 > maxWordGap { groups.append([]) }
            groups[groups.count - 1].append(word)
        }
        return groups.map { g in
            Utterance(track: track, speakerLabel: u.speaker, start: Double(g.first!.start) / 1000, end: Double(g.last!.end) / 1000,
                      text: g.map(\.text).joined(separator: " "),
                      words: g.map { Word(text: $0.text, start: Double($0.start) / 1000, end: Double($0.end) / 1000) })
        }
    }

    struct RawUtterance: Decodable {
        let speaker: String
        let start: Int
        let end: Int
        let text: String
        let words: [RawWord]?
    }

    struct RawWord: Decodable {
        let text: String
        let start: Int
        let end: Int
    }
}

public enum TranscriptionError: Error, CustomStringConvertible {
    case http(Int, String)
    case failed(String)

    public var description: String {
        switch self {
        case .http(let code, let body): "AssemblyAI HTTP \(code): \(body)"
        case .failed(let message): "AssemblyAI transcription failed: \(message)"
        }
    }
}
