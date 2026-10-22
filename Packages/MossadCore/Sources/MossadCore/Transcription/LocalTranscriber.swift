import FluidAudio
import Foundation

/// Loads the on-device models once and keeps them: Parakeet for words, FluidAudio's diarizer for speakers.
actor LocalEngine {
    static let shared = LocalEngine()
    private var asr: AsrManager?
    private var diarizer: DiarizerManager?

    func transcribe(_ file: URL) async throws -> ASRResult {
        if asr == nil {
            let manager = AsrManager()
            try await manager.loadModels(try await AsrModels.downloadAndLoad(version: .v3))
            asr = manager
        }
        var state = try TdtDecoderState()
        return try await asr!.transcribe(file, decoderState: &state)
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
}

/// Transcription on this Mac: free and private, faster than real time by about 300 times, but weaker on
/// product names than the cloud providers. The models download once, on first use.
public struct LocalTranscriber: Transcribing {
    public var serviceName: String { "Mossad" }
    public init() {}

    public func transcribe(file: URL, track: Track, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [Utterance] {
        progress(.transcribing)
        let result = try await LocalEngine.shared.transcribe(file)
        let words = buildWordTimings(from: result.tokenTimings ?? []).map { (text: $0.word, start: $0.startTime, end: $0.endTime) }
        guard !words.isEmpty else { return [] }
        let segments = try await LocalEngine.shared.speakers(file)
        return SpokenWord.utterances(Self.assign(words, to: segments), track: track)
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
