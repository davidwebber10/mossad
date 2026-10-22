import AVFoundation
import Foundation

/// An error from a provider other than AssemblyAI or Anthropic, named so the failure line says which one.
public enum ProviderError: Error, CustomStringConvertible {
    case http(String, Int, String)
    case failed(String, String)

    public var description: String {
        switch self {
        case .http(let p, let code, let body): "\(p) HTTP \(code): \(body)"
        case .failed(let p, let message): "\(p): \(message)"
        }
    }
}

/// One word with its speaker, as Deepgram and ElevenLabs return them.
struct SpokenWord: Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var speaker: String

    /// Groups words into utterances: a new one at each change of speaker and at each pause longer than the
    /// AssemblyAI client's limit, so every provider's turns look alike. Speakers are lettered by first appearance.
    static func utterances(_ words: [SpokenWord], track: Track) -> [Utterance] {
        var letters: [String: String] = [:]
        func letter(_ s: String) -> String {
            if let l = letters[s] { return l }
            let l = String(Character(UnicodeScalar(UInt8(65 + letters.count % 26))))
            letters[s] = l
            return l
        }
        var groups: [[SpokenWord]] = []
        for w in words {
            if let last = groups.last?.last, last.speaker == w.speaker, w.start - last.end <= AssemblyAIClient.maxWordGap {
                groups[groups.count - 1].append(w)
            } else {
                groups.append([w])
            }
        }
        return groups.map { g in
            Utterance(track: track, speakerLabel: letter(g[0].speaker), start: g.first!.start, end: g.last!.end,
                      text: g.map(\.text).joined(separator: " "), words: g.map { Word(text: $0.text, start: $0.start, end: $0.end) })
        }
    }
}

/// Encodes a track to mono AAC: an hour is about 14 MB at 32 kbps instead of about 230 MB of raw samples.
enum TrackEncoder {
    static func m4a(_ source: URL, bitRate: Int = 32_000) throws -> URL {
        let input = try AVAudioFile(forReading: source)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mossad-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: input.processingFormat.sampleRate,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: bitRate]
        do {
            let output = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 160_000)!
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        }
        return out
    }

    static func duration(_ url: URL) -> TimeInterval {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(f.length) / f.fileFormat.sampleRate
    }
}

/// A multipart/form-data body with text fields and one file.
struct Multipart {
    let boundary = "mossad-\(UUID().uuidString)"
    private(set) var body = Data()

    mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func file(_ name: String, filename: String, type: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finished() -> Data { body + Data("--\(boundary)--\r\n".utf8) }
    var contentType: String { "multipart/form-data; boundary=\(boundary)" }
}

private func send(_ request: URLRequest, provider: String, session: URLSession) async throws -> [String: Any] {
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw ProviderError.http(provider, status, data.snippet) }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ProviderError.failed(provider, "the reply was not JSON")
    }
    return object
}

/// Deepgram pre-recorded transcription: one upload, words with speakers.
public struct DeepgramTranscriber: Transcribing {
    public var serviceName: String { "Deepgram" }
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let usage: UsageLog?

    public init(apiKey: String, model: String = "nova-3", session: URLSession = .shared, usage: UsageLog? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.usage = usage
    }

    public func transcribe(file: URL, track: Track, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [Utterance] {
        progress(.uploading)
        let audio = try TrackEncoder.m4a(file)
        defer { try? FileManager.default.removeItem(at: audio) }
        var url = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        // diarize_model replaces the old diarize flag; sending both is rejected.
        url.queryItems = [("model", model), ("diarize_model", "latest"), ("punctuate", "true"), ("smart_format", "true"),
                          ("filler_words", "true"), ("language", "en")].map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = URLRequest(url: url.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Data(contentsOf: audio)
        progress(.transcribing)
        let reply = try await send(request, provider: "Deepgram", session: session)
        let metadata = reply["metadata"] as? [String: Any]
        usage?.record(service: .deepgram, purpose: .transcription, model: model,
                      audioSeconds: metadata?["duration"] as? Double ?? TrackEncoder.duration(file))
        let channel = ((reply["results"] as? [String: Any])?["channels"] as? [[String: Any]])?.first
        let words = ((channel?["alternatives"] as? [[String: Any]])?.first?["words"] as? [[String: Any]]) ?? []
        return SpokenWord.utterances(words.compactMap { w in
            guard let start = w["start"] as? Double, let end = w["end"] as? Double else { return nil }
            let text = w["punctuated_word"] as? String ?? w["word"] as? String ?? ""
            return SpokenWord(text: text, start: start, end: end, speaker: "\(w["speaker"] as? Int ?? 0)")
        }, track: track)
    }
}

/// ElevenLabs Scribe: one upload, words with speakers.
public struct ElevenLabsTranscriber: Transcribing {
    public var serviceName: String { "ElevenLabs" }
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let usage: UsageLog?

    public init(apiKey: String, model: String = "scribe_v2", session: URLSession = .shared, usage: UsageLog? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.usage = usage
    }

    public func transcribe(file: URL, track: Track, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [Utterance] {
        progress(.uploading)
        let audio = try TrackEncoder.m4a(file)
        defer { try? FileManager.default.removeItem(at: audio) }
        var form = Multipart()
        form.field("model_id", model)
        form.field("diarize", "true")
        form.field("timestamps_granularity", "word")
        form.field("tag_audio_events", "false")
        form.field("language_code", "en")
        form.file("file", filename: "\(track.rawValue).m4a", type: "audio/mp4", data: try Data(contentsOf: audio))
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finished()
        progress(.transcribing)
        let reply = try await send(request, provider: "ElevenLabs", session: session)
        // The reply has no billed length; the track's own length is what is billed.
        usage?.record(service: .elevenlabs, purpose: .transcription, model: model, audioSeconds: TrackEncoder.duration(file))
        let words = (reply["words"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "word" }
        return SpokenWord.utterances(words.compactMap { w in
            guard let start = w["start"] as? Double, let end = w["end"] as? Double, let text = w["text"] as? String else { return nil }
            return SpokenWord(text: text.trimmingCharacters(in: .whitespaces), start: start, end: end, speaker: w["speaker_id"] as? String ?? "")
        }, track: track)
    }
}

/// OpenAI's diarizing transcription model. It returns segments without word times, and OpenAI deprecated it
/// (shutdown 2027-02-26), so it is offered but not recommended.
public struct OpenAITranscriber: Transcribing {
    public var serviceName: String { "OpenAI" }
    /// OpenAI's upload limit.
    static let maxBytes = 25 * 1024 * 1024

    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let usage: UsageLog?

    public init(apiKey: String, model: String = "gpt-4o-transcribe-diarize", session: URLSession = .shared, usage: UsageLog? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.usage = usage
    }

    public func transcribe(file: URL, track: Track, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [Utterance] {
        progress(.uploading)
        // 24 kbps keeps about 2 hours and 20 minutes under the 25 MB limit.
        let audio = try TrackEncoder.m4a(file, bitRate: 24_000)
        defer { try? FileManager.default.removeItem(at: audio) }
        let data = try Data(contentsOf: audio)
        guard data.count <= Self.maxBytes else { throw ProviderError.failed("OpenAI", "the track is over OpenAI's 25 MB limit") }
        var form = Multipart()
        form.field("model", model)
        form.field("response_format", "diarized_json")
        form.field("chunking_strategy", "auto")
        form.field("language", "en")
        form.file("file", filename: "\(track.rawValue).m4a", type: "audio/mp4", data: data)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finished()
        progress(.transcribing)
        let reply = try await send(request, provider: "OpenAI", session: session)
        let seconds = (reply["usage"] as? [String: Any])?["seconds"] as? Double ?? reply["duration"] as? Double ?? TrackEncoder.duration(file)
        usage?.record(service: .openai, purpose: .transcription, model: model, audioSeconds: seconds)
        var letters: [String: String] = [:]
        return (reply["segments"] as? [[String: Any]] ?? []).compactMap { s in
            guard let start = s["start"] as? Double, let end = s["end"] as? Double, let text = s["text"] as? String,
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let speaker = s["speaker"] as? String ?? "A"
            let label = letters[speaker] ?? String(Character(UnicodeScalar(UInt8(65 + letters.count % 26))))
            letters[speaker] = label
            return Utterance(track: track, speakerLabel: label, start: start, end: end, text: text.trimmingCharacters(in: .whitespaces))
        }
    }
}
