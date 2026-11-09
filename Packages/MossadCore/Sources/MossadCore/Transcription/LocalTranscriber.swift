import AVFoundation
import FluidAudio
import Foundation

/// Loads the on-device models once and keeps them: the chosen model for words, FluidAudio's diarizer for speakers.
actor LocalEngine {
    static let shared = LocalEngine()
    private var parakeet: [LocalModel: AsrManager] = [:]
    private var diarizer: DiarizerManager?

    func words(_ file: URL, model: LocalModel) async throws -> [TimedWord] {
        switch model {
        case .parakeetV3: try await parakeetWords(file, model: model, version: .v3)
        case .parakeetV2: try await parakeetWords(file, model: model, version: .v2)
        }
    }

    private func parakeetWords(_ file: URL, model: LocalModel, version: AsrModelVersion) async throws -> [TimedWord] {
        if parakeet[model] == nil {
            let manager = AsrManager()
            let models: AsrModels
            do {
                models = try await AsrModels.downloadAndLoad(version: version, progressHandler: Self.logProgress(model))
            } catch is AsrModelsError {
                throw LocalModelError.modelMissing(model)
            }
            try await manager.loadModels(models)
            parakeet[model] = manager
        }
        var state = try TdtDecoderState()
        let result = try await parakeet[model]!.transcribe(file, decoderState: &state)
        return buildWordTimings(from: result.tokenTimings ?? []).map { TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime) }
    }

    func speakers(_ file: URL) async throws -> [(start: Double, end: Double, speaker: String)] {
        if diarizer == nil {
            let manager = DiarizerManager()
            manager.initialize(models: try await DiarizerModels.downloadIfNeeded())
            diarizer = manager
        }
        let samples = try AudioConverter().resampleAudioFile(file)
        return try diarizer!.performCompleteDiarization(samples).segments.map {
            (start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId)
        }
    }

    /// Logs a first download at each tenth. Loading models already on disk reports no download fractions worth noting.
    static func logProgress(_ model: LocalModel) -> @Sendable (DownloadProgress) -> Void {
        let steps = Steps()
        return { progress in
            guard case .downloading = progress.phase, let percent = steps.next(progress.fractionCompleted) else { return }
            Log.info("Downloading \(model.name): \(percent)%")
        }
    }

    /// The steps behind a lock: FluidAudio calls the handler on any queue.
    final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var steps = DownloadSteps()
        func next(_ fraction: Double) -> Int? { lock.withLock { steps.next(fraction) } }
    }
}

/// Transcription on this Mac: free and private. The chosen model gives words with times; FluidAudio's diarizer
/// splits the track by voice, and Mossad names the voices later, as it does for the cloud providers.
public struct LocalTranscriber: Transcribing {
    public typealias Segments = [(start: Double, end: Double, speaker: String)]
    public let model: LocalModel
    private let words: @Sendable (URL) async throws -> [TimedWord]
    private let speakers: @Sendable (URL) async throws -> Segments

    public var serviceName: String { "Mossad" }

    public init(model: LocalModel = .parakeetV3) {
        self.init(model: model, words: { try await LocalEngine.shared.words($0, model: model) },
                  speakers: { try await LocalEngine.shared.speakers($0) })
    }

    init(model: LocalModel, words: @escaping @Sendable (URL) async throws -> [TimedWord],
         speakers: @escaping @Sendable (URL) async throws -> Segments) {
        self.model = model
        self.words = words
        self.speakers = speakers
    }

    public func transcribe(file: URL, track: Track, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [Utterance] {
        // An empty track has nothing to say, and some models fail on it, so no model loads.
        if let audio = try? AVAudioFile(forReading: file), audio.length == 0 { return [] }
        progress(.transcribing)
        let words = try await words(file)
        guard !words.isEmpty else { return [] }
        let segments = try await speakers(file)
        return SpokenWord.utterances(Self.assign(words.map { ($0.text, $0.start, $0.end) }, to: segments), track: track)
    }

    /// Gives each word the speaker whose segment holds the word's middle, or the nearest segment.
    static func assign(_ words: [(text: String, start: Double, end: Double)], to segments: [(start: Double, end: Double, speaker: String)]) -> [SpokenWord] {
        words.map { w in
            let mid = (w.start + w.end) / 2
            let speaker = segments.first { $0.start <= mid && mid <= $0.end }?.speaker
                ?? segments.min { abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid) }?.speaker
                ?? "0"
            return SpokenWord(text: w.text, start: w.start, end: w.end, speaker: speaker)
        }
    }
}
