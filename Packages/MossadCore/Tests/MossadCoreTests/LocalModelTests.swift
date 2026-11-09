import XCTest
@testable import MossadCore

final class LocalModelTests: XCTestCase {
    private let segments: [(start: Double, end: Double, speaker: String)] = [(0, 2, "S1"), (2, 10, "S2")]

    func testLocalModelsInOrderWithStableIDs() {
        XCTAssertEqual(TranscriptionProvider.local.models.map(\.id), ["parakeet-tdt-v3", "parakeet-tdt-v2"])
        XCTAssertEqual(TranscriptionProvider.local.models.map(\.name), ["Parakeet TDT v3", "Parakeet TDT v2 (English only)"])
    }

    func testTheTranscriberUsesTheChosenModelAndFallsBackToTheFirst() {
        func model(_ id: String) -> LocalModel? { (TranscriptionProvider.local.transcriber(model: id, apiKey: "", usage: nil) as? LocalTranscriber)?.model }
        XCTAssertEqual(model("parakeet-tdt-v2"), .parakeetV2)
        XCTAssertEqual(model("parakeet-tdt-v3"), .parakeetV3)
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

    func testDownloadProgressLogsEachTenthOnce() {
        var steps = DownloadSteps()
        let logged = [0.01, 0.05, 0.1, 0.12, 0.35, 0.36, 1.0, 1.0].compactMap { steps.next($0) }
        XCTAssertEqual(logged, [0, 10, 30, 100])
    }
}
