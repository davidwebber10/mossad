import XCTest
@testable import MossadCore

final class LocalModelTests: XCTestCase {
    private let segments: [(start: Double, end: Double, speaker: String)] = [(0, 2, "S1"), (2, 10, "S2")]

    func testLocalModelsInOrderWithStableIDs() {
        XCTAssertEqual(TranscriptionProvider.local.models.map(\.id), ["parakeet-tdt-v3", "parakeet-tdt-v2", "apple-speech", "whisper-large-v3-turbo"])
        XCTAssertEqual(TranscriptionProvider.local.models.map(\.name), ["Parakeet TDT v3", "Parakeet TDT v2 (English only)", "Apple Speech", "Whisper Large v3 Turbo"])
    }

    func testTheTranscriberUsesTheChosenModelAndFallsBackToTheFirst() {
        func model(_ id: String) -> LocalModel? { (TranscriptionProvider.local.transcriber(model: id, apiKey: "", usage: nil) as? LocalTranscriber)?.model }
        XCTAssertEqual(model("parakeet-tdt-v2"), .parakeetV2)
        XCTAssertEqual(model("parakeet-tdt-v3"), .parakeetV3)
        XCTAssertEqual(model("apple-speech"), .appleSpeech)
        XCTAssertEqual(model("whisper-large-v3-turbo"), .whisperTurbo)
        XCTAssertEqual(model(""), .parakeetV3)
        XCTAssertEqual(model("a-model-that-is-gone"), .parakeetV3, "a model removed from the list falls back to the default")
    }

    func testEachModelHasItsOwnShortNote() {
        let notes = LocalModel.allCases.map(\.note)
        XCTAssertEqual(Set(notes).count, notes.count)
        for note in notes {
            XCTAssertFalse(note.isEmpty)
            XCTAssertFalse(note.contains("—"))
        }
        XCTAssertEqual(TranscriptionProvider.local.note(model: "parakeet-tdt-v2"), LocalModel.parakeetV2.note)
        XCTAssertEqual(TranscriptionProvider.local.note(model: ""), TranscriptionProvider.local.note)
        XCTAssertEqual(TranscriptionProvider.deepgram.note(model: "nova-3"), TranscriptionProvider.deepgram.note)
        XCTAssertTrue(LocalModel.parakeetV2.note.contains("English"))
    }

    func testWordsBecomeUtterancesWithTimesAndSpeakers() async throws {
        let file = tempDirectory().appendingPathComponent("them.caf")
        try writeTestAudio(file, seconds: 1, frequency: 220)
        let words = [TimedWord(text: "Hello", start: 0.2, end: 0.6), TimedWord(text: "there.", start: 0.7, end: 1.1),
                     TimedWord(text: "Hi.", start: 3, end: 3.4)]
        let segments = segments
        let t = LocalTranscriber(model: .parakeetV2, words: { _ in words }, speakers: { _ in segments })
        let u = try await t.transcribe(file: file, track: .them) { _ in }
        XCTAssertEqual(u.map(\.text), ["Hello there.", "Hi."])
        XCTAssertEqual(u.map(\.speakerLabel), ["A", "B"])
        XCTAssertEqual(u.first?.start, 0.2)
        XCTAssertEqual(u.first?.end, 1.1)
        XCTAssertEqual(u.last?.words?.first?.start, 3)
    }

    func testNoWordsSkipsTheSpeakerModel() async throws {
        let file = tempDirectory().appendingPathComponent("me.caf")
        try writeTestAudio(file, seconds: 1)
        let t = LocalTranscriber(model: .parakeetV3, words: { _ in [] }, speakers: { _ in XCTFail("no speakers without words"); return [] })
        let u = try await t.transcribe(file: file, track: .me) { _ in }
        XCTAssertEqual(u, [])
    }

    func testEmptyAudioNeedsNoModel() async throws {
        let file = tempDirectory().appendingPathComponent("me.caf")
        try writeTestAudio(file, seconds: 0)
        let t = LocalTranscriber(model: .parakeetV3, words: { _ in XCTFail("no model for empty audio"); return [] },
                                 speakers: { _ in XCTFail("no model for empty audio"); return [] })
        let u = try await t.transcribe(file: file, track: .me) { _ in }
        XCTAssertEqual(u, [])
    }

    func testAMissingModelReadsAsAPlainSentence() async throws {
        let file = tempDirectory().appendingPathComponent("me.caf")
        try writeTestAudio(file, seconds: 1, frequency: 220)
        let t = LocalTranscriber(model: .parakeetV2, words: { _ in throw LocalModelError.modelMissing(.parakeetV2) }, speakers: { _ in [] })
        do {
            _ = try await t.transcribe(file: file, track: .me) { _ in }
            XCTFail("expected an error")
        } catch {
            let friendly = FriendlyError(error, context: .transcribing)
            XCTAssertEqual(friendly.kind, .transcriptionFailed)
            XCTAssertTrue(friendly.title.contains("Parakeet TDT v2"), friendly.title)
            XCTAssertTrue(friendly.message.contains("download"), friendly.message)
        }
    }

    func testAppleSpeechProblemsSayWhatToDo() {
        let unsupported = FriendlyError(LocalModelError.notSupported(.appleSpeech), context: .transcribing)
        XCTAssertEqual(unsupported.title, "Apple Speech couldn't transcribe this audio")
        XCTAssertTrue(unsupported.message.contains("Choose another local model"), unsupported.message)
        let asset = FriendlyError(LocalModelError.assetNotInstalled(.appleSpeech), context: .transcribing)
        XCTAssertTrue(asset.message.contains("language files"), asset.message)
    }

    // MARK: Pieces of text with times

    func testPiecesSplitIntoWordsWithShareOfTheTime() {
        let w = TimedText.words([TimedPiece(text: "Hello there", start: 1, end: 3)])
        XCTAssertEqual(w, [TimedWord(text: "Hello", start: 1, end: 2), TimedWord(text: "there", start: 2, end: 3)])
    }

    func testPunctuationAndWordPartsJoinTheWordBefore() {
        let w = TimedText.words([
            TimedPiece(text: " We", start: 0, end: 0.2), TimedPiece(text: " don", start: 0.3, end: 0.5),
            TimedPiece(text: "'t", start: 0.5, end: 0.6), TimedPiece(text: " ship", start: 0.7, end: 1),
            TimedPiece(text: ".", start: nil, end: nil), TimedPiece(text: " ", start: nil, end: nil), TimedPiece(text: "Ok", start: 2, end: 2.4),
        ])
        XCTAssertEqual(w.map(\.text), ["We", "don't", "ship.", "Ok"])
        XCTAssertEqual(w[1].start, 0.3)
        XCTAssertEqual(w[1].end, 0.6)
        XCTAssertEqual(w[2].end, 1)
    }

    func testAPieceWithoutTimeTakesTheTimeBeforeIt() {
        let w = TimedText.words([TimedPiece(text: "Yes", start: 1, end: 1.5), TimedPiece(text: " sir", start: nil, end: nil)])
        XCTAssertEqual(w.last, TimedWord(text: "sir", start: 1.5, end: 1.5))
        XCTAssertEqual(TimedText.words([]), [])
        XCTAssertEqual(TimedText.words([TimedPiece(text: "  ", start: 0, end: 1)]), [])
    }

    func testDownloadProgressLogsEachTenthOnce() {
        var steps = DownloadSteps()
        let logged = [0.01, 0.05, 0.1, 0.12, 0.35, 0.36, 1.0, 1.0].compactMap { steps.next($0) }
        XCTAssertEqual(logged, [0, 10, 30, 100])
    }
}

#if os(macOS)
import CoreMedia
import Speech

final class AppleSpeechMappingTests: XCTestCase {
    func testTheAttributedStringTimesBecomeWords() {
        func timed(_ text: String, _ start: Double, _ end: Double) -> AttributedString {
            var a = AttributedString(text)
            a.audioTimeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1000), end: CMTime(seconds: end, preferredTimescale: 1000))
            return a
        }
        let text = timed("Ship", 0.5, 0.9) + AttributedString(" ") + timed("it", 1, 1.2) + AttributedString(".")
        let w = AppleSpeechEngine.words(in: text)
        XCTAssertEqual(w, [TimedWord(text: "Ship", start: 0.5, end: 0.9), TimedWord(text: "it.", start: 1, end: 1.2)])
    }
}

final class WhisperMappingTests: XCTestCase {
    func testWhisperWordsDropSpecialTokensAndEachSegmentStartsAWord() {
        let w = WhisperEngine.words([
            [("<|en|>", 0, 0), (" We", 0.1, 0.3), (" don", 0.4, 0.6), ("'t", 0.6, 0.7), (" wait.", 0.8, 1.2)],
            [("Then", 2, 2.3), (" go", 2.4, 2.6)],
        ])
        XCTAssertEqual(w.map(\.text), ["We", "don't", "wait.", "Then", "go"])
        XCTAssertEqual(w[1], TimedWord(text: "don't", start: 0.4, end: 0.7))
        XCTAssertEqual(w[3].start, 2)
    }

    func testAMissingWhisperModelIsNotDownloadedWhenNotAllowed() async {
        do {
            _ = try await WhisperEngine.load(base: tempDirectory(), download: false)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LocalModelError, .modelMissing(.whisperTurbo))
        }
    }

    func testAnUnreadableWhisperModelReadsAsMissing() async throws {
        let base = tempDirectory()
        let folder = WhisperEngine.modelFolder(base: base).appendingPathComponent("AudioEncoder.mlmodelc")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            _ = try await WhisperEngine.load(base: base, download: false)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? LocalModelError, .modelMissing(.whisperTurbo))
        }
    }
}
#endif
