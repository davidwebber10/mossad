#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Apple's on-device SpeechTranscriber. macOS keeps the language files; Mossad asks it to install them when missing.
enum AppleSpeechEngine {
    static let locale = Locale(identifier: "en-US")

    static func words(_ file: URL) async throws -> [TimedWord] {
        guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw LocalModelError.notSupported(.appleSpeech)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        try await install(transcriber)
        let audio = try AVAudioFile(forReading: file)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task {
            var texts: [AttributedString] = []
            for try await result in transcriber.results where result.isFinal { texts.append(result.text) }
            return texts
        }
        do {
            if let end = try await analyzer.analyzeSequence(from: audio) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collect.cancel()
            throw error
        }
        var pieces: [TimedPiece] = []
        for text in try await collect.value {
            // Results come one sentence or phrase at a time, with no space between them.
            pieces.append(TimedPiece(text: " ", start: nil, end: nil))
            pieces += Self.pieces(in: text)
        }
        return TimedText.words(pieces)
    }

    static func words(in text: AttributedString) -> [TimedWord] { TimedText.words(pieces(in: text)) }

    /// Each run of the result with its audio time range, which covers a word or part of one.
    static func pieces(in text: AttributedString) -> [TimedPiece] {
        text.runs.map { run in
            let range = run.audioTimeRange
            return TimedPiece(text: String(text[run.range].characters),
                              start: range.map { $0.start.seconds }, end: range.map { $0.end.seconds })
        }
    }

    /// Installs the language files when macOS has not yet, and logs how far the download is.
    private static func install(_ transcriber: SpeechTranscriber) async throws {
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return
        case .unsupported: throw LocalModelError.notSupported(.appleSpeech)
        case .supported, .downloading: break
        @unknown default: break
        }
        Log.info("Installing the Apple Speech files for \(locale.identifier)")
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let steps = LocalEngine.Steps()
                let watch = request.progress.observe(\.fractionCompleted) { progress, _ in
                    if let percent = steps.next(progress.fractionCompleted) { Log.info("Downloading Apple Speech: \(percent)%") }
                }
                defer { watch.invalidate() }
                try await request.downloadAndInstall()
            }
        } catch {
            Log.error("Apple Speech files did not install: \(error)")
            throw LocalModelError.assetNotInstalled(.appleSpeech)
        }
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw LocalModelError.assetNotInstalled(.appleSpeech)
        }
    }
}
#endif
