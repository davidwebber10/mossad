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
        let uploadURL: UploadResponse = try await send(request("upload", method: "POST"), body: try Data(contentsOf: file))
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
                return (job.utterances ?? []).map {
                    Utterance(track: track, speakerLabel: $0.speaker, start: Double($0.start) / 1000, end: Double($0.end) / 1000, text: $0.text)
                }
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

    private func send<T: Decodable>(_ request: URLRequest, body: Data?) async throws -> T {
        let (data, response) = if let body {
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

    private struct RawUtterance: Decodable {
        let speaker: String
        let start: Int
        let end: Int
        let text: String
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
