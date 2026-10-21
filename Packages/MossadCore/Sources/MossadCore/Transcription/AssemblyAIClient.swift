import Foundation

public protocol Transcribing: Sendable {
    func transcribe(file: URL, track: Track) async throws -> [Utterance]
}

/// Batch transcription with speaker labels through the AssemblyAI v2 REST API.
public struct AssemblyAIClient: Transcribing {
    static let base = URL(string: "https://api.assemblyai.com/v2")!

    private let apiKey: String
    private let session: URLSession
    private let pollInterval: Duration

    public init(apiKey: String, session: URLSession = .shared, pollInterval: Duration = .seconds(5)) {
        self.apiKey = apiKey
        self.session = session
        self.pollInterval = pollInterval
    }

    public func transcribe(file: URL, track: Track) async throws -> [Utterance] {
        let uploadURL: UploadResponse = try await send(request("upload", method: "POST"), file: file)
        let create = try JSONSerialization.data(withJSONObject: [
            "audio_url": uploadURL.upload_url,
            "speaker_labels": true,
            "language_detection": false,
            "language_code": "en_us",
        ])
        var job: TranscriptResponse = try await send(request("transcript", method: "POST", json: true), body: create)
        while true {
            switch job.status {
            case "completed":
                return (job.utterances ?? []).flatMap { Self.split($0, track: track) }
            case "error":
                throw TranscriptionError.failed(job.error ?? "unknown error")
            default:
                try await Task.sleep(for: pollInterval)
                job = try await send(request("transcript/\(job.id)", method: "GET"), body: nil)
            }
        }
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
    private func send<T: Decodable>(_ request: URLRequest, body: Data? = nil, file: URL? = nil) async throws -> T {
        let (data, response) = if let file {
            try await session.upload(for: request, fromFile: file)
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

    private struct TranscriptResponse: Decodable {
        let id: String
        let status: String
        let error: String?
        let utterances: [RawUtterance]?
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
                      text: g.map(\.text).joined(separator: " "))
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
