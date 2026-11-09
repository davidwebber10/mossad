#if os(macOS)
import AudioCommon
import FluidAudio
import Foundation
import Qwen3ASR

/// Qwen3-ASR 0.6B on MLX, with Qwen3's forced aligner for word times. The ASR model writes text for a window of up
/// to 30 seconds; the aligner then places each word of that text in the window.
final class QwenEngine: @unchecked Sendable {
    static let asrID = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    static let alignerID = "aufklarer/Qwen3-ForcedAligner-0.6B-4bit"
    static let rate = 16_000

    static var downloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mossad/Models/Qwen3", isDirectory: true)
    }

    private let asr: Qwen3ASRModel
    private let aligner: Qwen3ForcedAligner

    private init(asr: Qwen3ASRModel, aligner: Qwen3ForcedAligner) {
        self.asr = asr
        self.aligner = aligner
    }

    static func load(base: URL = downloadBase) async throws -> QwenEngine {
        let model = LocalModel.qwen3
        func progress() -> (Double, String) -> Void {
            let steps = LocalEngine.Steps()
            return { fraction, _ in if let p = steps.next(fraction) { Log.info("Downloading \(model.name): \(p)%") } }
        }
        do {
            let asr = try await Qwen3ASRModel.fromPretrained(
                modelId: asrID, cacheDir: try HuggingFaceDownloader.getCacheDirectory(for: asrID, basePath: base), progressHandler: progress())
            let aligner = try await Qwen3ForcedAligner.fromPretrained(
                modelId: alignerID, cacheDir: try HuggingFaceDownloader.getCacheDirectory(for: alignerID, basePath: base),
                progressHandler: progress())
            return QwenEngine(asr: asr, aligner: aligner)
        } catch let error as URLError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.error("\(model.name) did not load: \(error)")
            throw LocalModelError.modelMissing(model)
        }
    }

    func words(_ file: URL) async throws -> [TimedWord] {
        let samples = try AudioConverter().resampleAudioFile(file)
        var words: [TimedWord] = []
        for window in Self.windows(samples, rate: Self.rate) {
            try Task.checkCancellation()
            let audio = Array(samples[window])
            let text = asr.transcribe(audio: audio, sampleRate: Self.rate).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let aligned = aligner.alignLong(audio: audio, text: text, sampleRate: Self.rate, language: "English")
            words += Self.words(text: text, aligned: aligned.map { ($0.text, Double($0.startTime), Double($0.endTime)) },
                                offset: Double(window.lowerBound) / Double(Self.rate))
        }
        return words
    }

    /// The aligner drops punctuation, so each word of the ASR text takes the times of the next aligned word, and
    /// the text keeps its punctuation. Text with no letters, such as a dash, joins the word before it.
    static func words(text: String, aligned: [(text: String, start: Double, end: Double)], offset: Double) -> [TimedWord] {
        var next = aligned.makeIterator()
        var pieces: [TimedPiece] = []
        for token in text.split(whereSeparator: \.isWhitespace) {
            let hasLetters = token.contains { $0.isLetter || $0.isNumber }
            let time = hasLetters ? next.next() : nil
            pieces.append(TimedPiece(text: " " + token, start: time.map { $0.start + offset }, end: time.map { $0.end + offset }))
        }
        return TimedText.words(pieces)
    }

    /// Windows of at most `maxSeconds`, each cut at the quietest tenth of a second in its last 5 seconds, so a cut
    /// rarely splits a word.
    static func windows(_ samples: [Float], rate: Int, maxSeconds: Int = 30) -> [Range<Int>] {
        let maxLength = maxSeconds * rate, search = 5 * rate, frame = rate / 10
        var out: [Range<Int>] = []
        var start = 0
        while start < samples.count {
            var end = min(samples.count, start + maxLength)
            if end < samples.count {
                var quietest = end, lowest = Float.infinity
                var f = end - search
                while f + frame <= end {
                    var energy: Float = 0
                    for i in f..<(f + frame) { energy += samples[i] * samples[i] }
                    if energy < lowest { lowest = energy; quietest = f + frame / 2 }
                    f += frame
                }
                end = quietest
            }
            out.append(start..<end)
            start = end
        }
        return out
    }
}
#endif
