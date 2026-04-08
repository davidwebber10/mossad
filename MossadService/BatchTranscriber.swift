// MossadService/BatchTranscriber.swift
import Foundation
import os.log

private let batchLog = Logger(subsystem: "com.mossad.app", category: "BatchTranscriber")

/// Handles uploading audio and requesting batch transcription from AssemblyAI
public final class BatchTranscriber {
    private let apiKey: String
    private let session = URLSession(configuration: .default)

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Upload a local audio file, then submit for transcription with speaker diarization.
    /// Calls completion with the transcript result (array of utterances with speaker labels).
    public func transcribe(
        audioFileURL: URL,
        completion: @escaping (Result<[TranscribedUtterance], Error>) -> Void
    ) {
        batchLog.notice("Uploading audio file: \(audioFileURL.lastPathComponent, privacy: .public)")

        uploadFile(audioFileURL) { [weak self] result in
            switch result {
            case .success(let uploadURL):
                batchLog.notice("Upload complete, submitting for transcription...")
                self?.submitTranscription(audioURL: uploadURL, completion: completion)
            case .failure(let error):
                batchLog.error("Upload failed: \(error.localizedDescription, privacy: .public)")
                completion(.failure(error))
            }
        }
    }

    // MARK: - Upload

    private func uploadFile(_ fileURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://api.assemblyai.com/v2/upload") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let task = session.uploadTask(with: request, fromFile: fileURL) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uploadURL = json["upload_url"] as? String else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
                batchLog.error("Upload response error: \(body, privacy: .public)")
                completion(.failure(TranscriberError.uploadFailed))
                return
            }
            completion(.success(uploadURL))
        }
        task.resume()
    }

    // MARK: - Submit + Poll

    private func submitTranscription(audioURL: String, completion: @escaping (Result<[TranscribedUtterance], Error>) -> Void) {
        guard let url = URL(string: "https://api.assemblyai.com/v2/transcript") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "audio_url": audioURL,
            "speaker_labels": true,
            "speech_model": "best"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let transcriptId = json["id"] as? String else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
                batchLog.error("Submit response error: \(body, privacy: .public)")
                completion(.failure(TranscriberError.submitFailed))
                return
            }

            batchLog.notice("Transcription submitted: \(transcriptId, privacy: .public)")
            self?.pollForResult(transcriptId: transcriptId, completion: completion)
        }
        task.resume()
    }

    private func pollForResult(transcriptId: String, completion: @escaping (Result<[TranscribedUtterance], Error>) -> Void) {
        guard let url = URL(string: "https://api.assemblyai.com/v2/transcript/\(transcriptId)") else { return }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String else {
                completion(.failure(TranscriberError.pollFailed))
                return
            }

            switch status {
            case "completed":
                batchLog.notice("Transcription complete!")
                let utterances = Self.parseUtterances(from: json)
                completion(.success(utterances))

            case "error":
                let errorMsg = json["error"] as? String ?? "Unknown error"
                batchLog.error("Transcription failed: \(errorMsg, privacy: .public)")
                completion(.failure(TranscriberError.transcriptionFailed(errorMsg)))

            default:
                // Still processing — poll again in 3 seconds
                batchLog.debug("Transcription status: \(status, privacy: .public), polling again...")
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    self?.pollForResult(transcriptId: transcriptId, completion: completion)
                }
            }
        }
        task.resume()
    }

    // MARK: - Parse

    private static func parseUtterances(from json: [String: Any]) -> [TranscribedUtterance] {
        // Use utterances array (speaker-labeled segments) if available
        if let utterances = json["utterances"] as? [[String: Any]] {
            return utterances.map { u in
                TranscribedUtterance(
                    speaker: u["speaker"] as? String ?? "?",
                    text: u["text"] as? String ?? "",
                    startMs: u["start"] as? Int ?? 0,
                    endMs: u["end"] as? Int ?? 0,
                    confidence: u["confidence"] as? Double ?? 0
                )
            }
        }
        // Fallback to full text without speaker labels
        if let text = json["text"] as? String, !text.isEmpty {
            return [TranscribedUtterance(speaker: "?", text: text, startMs: 0, endMs: 0, confidence: 0)]
        }
        return []
    }
}

public struct TranscribedUtterance {
    public let speaker: String  // "A", "B", etc.
    public let text: String
    public let startMs: Int
    public let endMs: Int
    public let confidence: Double
}

enum TranscriberError: Error {
    case uploadFailed
    case submitFailed
    case pollFailed
    case transcriptionFailed(String)
}
