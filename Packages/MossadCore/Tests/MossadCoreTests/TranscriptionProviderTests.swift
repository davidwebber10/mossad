import XCTest
@testable import MossadCore

final class TranscriptionProviderTests: XCTestCase {
    private func track() throws -> URL {
        let url = tempDirectory().appendingPathComponent("them.caf")
        try writeTestAudio(url, seconds: 2, frequency: 220)
        return url
    }

    private func field(_ body: Data, _ name: String) -> String? {
        let text = String(decoding: body, as: UTF8.self)
        guard let r = text.range(of: "name=\"\(name)\"\r\n\r\n") else { return nil }
        // "\r\n" is one Character in Swift, so split on the pair.
        return String(text[r.upperBound...]).components(separatedBy: "\r\n").first
    }

    // MARK: Words to utterances

    func testWordsBecomeOneUtterancePerSpeakerTurnAndLongPause() {
        let words: [SpokenWord] = [
            SpokenWord(text: "Hi", start: 0, end: 0.3, speaker: "0"), SpokenWord(text: "there.", start: 0.4, end: 0.8, speaker: "0"),
            SpokenWord(text: "Hello.", start: 1, end: 1.5, speaker: "1"),
            SpokenWord(text: "Back", start: 1.6, end: 2, speaker: "0"), SpokenWord(text: "later.", start: 5, end: 5.4, speaker: "0"),
        ]
        let u = SpokenWord.utterances(words, track: .them)
        XCTAssertEqual(u.map(\.text), ["Hi there.", "Hello.", "Back", "later."])
        XCTAssertEqual(u.map(\.speakerLabel), ["A", "B", "A", "A"])
        XCTAssertEqual(u.first?.words?.count, 2)
        XCTAssertEqual(u.last?.start, 5)
    }

    // MARK: Deepgram

    func testDeepgramSendsTheModelAndDiarizationAndReadsSpeakerWords() async throws {
        StubURLProtocol.handler = { _ in
            (200, json(["metadata": ["duration": 120.5], "results": ["channels": [["alternatives": [["words": [
                ["word": "hello", "punctuated_word": "Hello,", "start": 1.0, "end": 1.4, "speaker": 0],
                ["word": "team", "punctuated_word": "team.", "start": 1.5, "end": 1.9, "speaker": 0],
                ["word": "hi", "punctuated_word": "Hi.", "start": 2.2, "end": 2.5, "speaker": 1],
            ]]]]]]]))
        }
        let log = UsageLog(directory: tempDirectory())
        let client = DeepgramTranscriber(apiKey: "dg", model: "nova-3", session: StubURLProtocol.session(), usage: log)
        let u = try await client.transcribe(file: try track(), track: .them)
        XCTAssertEqual(u.map(\.text), ["Hello, team.", "Hi."])
        XCTAssertEqual(u.map(\.speakerLabel), ["A", "B"])
        let r = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(r.url.host, "api.deepgram.com")
        XCTAssertEqual(r.url.path, "/v1/listen")
        let query = URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "model" }?.value, "nova-3")
        XCTAssertEqual(query.first { $0.name == "diarize_model" }?.value, "latest")
        XCTAssertEqual(query.first { $0.name == "filler_words" }?.value, "true")
        XCTAssertNil(query.first { $0.name == "diarize" }, "the old diarize flag conflicts with diarize_model")
        XCTAssertEqual(r.headers["Authorization"] ?? r.headers["authorization"], "Token dg")
        XCTAssertEqual(log.all().first?.service, .deepgram)
        XCTAssertEqual(log.all().first?.audioSeconds, 120.5)
    }

    // MARK: ElevenLabs

    func testElevenLabsAsksForDiarizedWordsAndSkipsSpacing() async throws {
        StubURLProtocol.handler = { _ in
            (200, json(["text": "Hi. Yes.", "words": [
                ["text": "Hi.", "start": 0.1, "end": 0.4, "type": "word", "speaker_id": "speaker_0"],
                ["text": " ", "start": 0.4, "end": 0.5, "type": "spacing", "speaker_id": "speaker_0"],
                ["text": "Yes.", "start": 0.6, "end": 0.9, "type": "word", "speaker_id": "speaker_1"],
            ]]))
        }
        let log = UsageLog(directory: tempDirectory())
        let client = ElevenLabsTranscriber(apiKey: "xi", model: "scribe_v2", session: StubURLProtocol.session(), usage: log)
        let u = try await client.transcribe(file: try track(), track: .me)
        XCTAssertEqual(u.map(\.text), ["Hi.", "Yes."])
        XCTAssertEqual(u.map(\.speakerLabel), ["A", "B"])
        let r = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(r.url.absoluteString, "https://api.elevenlabs.io/v1/speech-to-text")
        XCTAssertEqual(r.headers["xi-api-key"], "xi")
        XCTAssertEqual(field(r.body, "model_id"), "scribe_v2")
        XCTAssertEqual(field(r.body, "diarize"), "true")
        XCTAssertEqual(field(r.body, "timestamps_granularity"), "word")
        XCTAssertEqual(log.all().first?.service, .elevenlabs)
        XCTAssertEqual(log.all().first?.audioSeconds ?? 0, 2, accuracy: 0.1)
    }

    // MARK: OpenAI

    func testOpenAIUsesTheDiarizedFormatAndReadsSegments() async throws {
        StubURLProtocol.handler = { _ in
            (200, json(["duration": 42.7, "segments": [
                ["type": "transcript.text.segment", "id": "seg_1", "start": 0.0, "end": 4.2, "speaker": "A", "text": "Morning all."],
                ["type": "transcript.text.segment", "id": "seg_2", "start": 4.5, "end": 6.0, "speaker": "B", "text": "Morning."],
            ], "usage": ["type": "duration", "seconds": 43]]))
        }
        let log = UsageLog(directory: tempDirectory())
        let client = OpenAITranscriber(apiKey: "sk", model: "gpt-4o-transcribe-diarize", session: StubURLProtocol.session(), usage: log)
        let u = try await client.transcribe(file: try track(), track: .them)
        XCTAssertEqual(u.map(\.text), ["Morning all.", "Morning."])
        XCTAssertEqual(u.map(\.speakerLabel), ["A", "B"])
        XCTAssertEqual(u.last?.start, 4.5)
        let r = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(r.url.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(r.headers["Authorization"] ?? r.headers["authorization"], "Bearer sk")
        XCTAssertEqual(field(r.body, "response_format"), "diarized_json")
        XCTAssertEqual(field(r.body, "chunking_strategy"), "auto")
        XCTAssertEqual(log.all().first?.service, .openai)
        XCTAssertEqual(log.all().first?.audioSeconds, 43)
    }

    func testProviderErrorsNameTheProvider() {
        XCTAssertEqual(Pipeline.failureReason(ProviderError.http("Deepgram", 500, "x")), "Deepgram error 500")
        XCTAssertEqual(Pipeline.failureReason(ProviderError.http("OpenAI", 401, "x")), "invalid API key")
    }

    // MARK: Prices

    func testTranscriptionPricesPerProvider() {
        func cost(_ s: UsageEvent.Service, _ model: String?) -> Double {
            Pricing.cost(UsageEvent(date: Date(), callID: nil, service: s, purpose: .transcription, model: model, audioSeconds: 3600))
        }
        XCTAssertEqual(cost(.deepgram, "nova-3"), 0.258, accuracy: 0.0001)
        XCTAssertEqual(cost(.elevenlabs, "scribe_v2"), 0.22, accuracy: 0.0001)
        XCTAssertEqual(cost(.openai, "gpt-4o-transcribe-diarize"), 0.36, accuracy: 0.0001)
    }
}
