#if os(macOS)
import Foundation
import WhisperKit

/// Whisper Large v3 Turbo through WhisperKit on Core ML. The model downloads once to Application Support and loads
/// from there without the network afterwards.
final class WhisperEngine: @unchecked Sendable {
    static let variant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let repo = "argmaxinc/whisperkit-coreml"

    static var downloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mossad/Models/WhisperKit", isDirectory: true)
    }

    /// Where a finished download sits, the layout WhisperKit's hub download uses.
    static func modelFolder(base: URL = downloadBase) -> URL {
        base.appendingPathComponent("models/\(repo)/\(variant)", isDirectory: true)
    }

    private let whisper: WhisperKit

    private init(whisper: WhisperKit) { self.whisper = whisper }

    /// Loads the model from `base`, downloading it first when it is not there and `download` allows it.
    static func load(base: URL = downloadBase, download: Bool = true) async throws -> WhisperEngine {
        var folder = modelFolder(base: base)
        let present = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.contains { $0.hasSuffix(".mlmodelc") } == true
        if !present {
            guard download else { throw LocalModelError.modelMissing(.whisperTurbo) }
            Log.info("Downloading \(LocalModel.whisperTurbo.name) to \(base.path)")
            let steps = LocalEngine.Steps()
            do {
                folder = try await WhisperKit.download(variant: variant, downloadBase: base, from: repo) { progress in
                    if let percent = steps.next(progress.fractionCompleted) { Log.info("Downloading \(LocalModel.whisperTurbo.name): \(percent)%") }
                }
            } catch let error as URLError {
                throw error
            } catch {
                Log.error("\(LocalModel.whisperTurbo.name) did not download: \(error)")
                throw LocalModelError.modelMissing(.whisperTurbo)
            }
        }
        do {
            let config = WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .error, load: true, download: false)
            return WhisperEngine(whisper: try await WhisperKit(config))
        } catch {
            Log.error("\(LocalModel.whisperTurbo.name) did not load: \(error)")
            throw LocalModelError.modelMissing(.whisperTurbo)
        }
    }

    func words(_ file: URL) async throws -> [TimedWord] {
        // VAD chunks let long calls run in parallel windows; the language is found per window.
        let options = DecodingOptions(language: nil, detectLanguage: true, skipSpecialTokens: true, wordTimestamps: true, chunkingStrategy: .vad)
        let results = try await whisper.transcribe(audioPath: file.path, decodeOptions: options)
        let segments = results.flatMap(\.segments).map { ($0.words ?? []).map { (text: $0.word, start: Double($0.start), end: Double($0.end)) } }
        return Self.words(segments)
    }

    /// Whisper's words begin with a space when they start a new word, and each segment starts a new word. Special
    /// tokens such as `<|en|>` are dropped.
    static func words(_ segments: [[(text: String, start: Double, end: Double)]]) -> [TimedWord] {
        TimedText.words(segments.flatMap { words in
            [TimedPiece(text: " ", start: nil, end: nil)]
                + words.filter { !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("<|") }
                    .map { TimedPiece(text: $0.text, start: $0.start, end: $0.end) }
        })
    }
}
#endif
