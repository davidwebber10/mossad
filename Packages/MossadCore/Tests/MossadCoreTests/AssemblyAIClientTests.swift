import XCTest
@testable import MossadCore

final class AssemblyAIClientTests: XCTestCase {
    var file: URL!

    override func setUp() {
        file = tempDirectory().appendingPathComponent("them.caf")
        try! Data("audio-bytes".utf8).write(to: file)
    }

    func client() -> AssemblyAIClient {
        AssemblyAIClient(apiKey: "key-123", session: StubURLProtocol.session(), pollInterval: .zero)
    }

    func testUploadThenCreateThenPoll() async throws {
        var polls = 0
        StubURLProtocol.handler = { r in
            switch (r.method, r.url.path) {
            case ("POST", "/v2/upload"): return (200, json(["upload_url": "https://cdn.assemblyai.com/upload/abc"]))
            case ("POST", "/v2/transcript"): return (200, json(["id": "t1", "status": "queued"]))
            case ("GET", "/v2/transcript/t1"):
                polls += 1
                if polls == 1 { return (200, json(["id": "t1", "status": "processing"])) }
                return (200, json(["id": "t1", "status": "completed", "utterances": [
                    ["speaker": "A", "start": 4120, "end": 6000, "text": "Hello there."],
                    ["speaker": "B", "start": 6500, "end": 9000, "text": "Hi."],
                ]]))
            default: return (404, Data())
            }
        }
        let utterances = try await client().transcribe(file: file, track: .them)
        XCTAssertEqual(utterances.map(\.withoutWords), [
            Utterance(track: .them, speakerLabel: "A", start: 4.12, end: 6.0, text: "Hello there."),
            Utterance(track: .them, speakerLabel: "B", start: 6.5, end: 9.0, text: "Hi."),
        ])
        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.map { "\($0.method) \($0.url.path)" },
                       ["POST /v2/upload", "POST /v2/transcript", "GET /v2/transcript/t1", "GET /v2/transcript/t1"])
        XCTAssertTrue(requests.allSatisfy { $0.headers["Authorization"] == "key-123" || $0.headers["authorization"] == "key-123" })
        XCTAssertEqual(requests[0].body, Data("audio-bytes".utf8))
        let create = try JSONSerialization.jsonObject(with: requests[1].body) as! [String: Any]
        XCTAssertEqual(create["audio_url"] as? String, "https://cdn.assemblyai.com/upload/abc")
        XCTAssertEqual(create["speaker_labels"] as? Bool, true)
        XCTAssertEqual(create["language_code"] as? String, "en_us")
    }

    func testErrorStatusThrows() async {
        StubURLProtocol.handler = { r in
            switch r.url.path {
            case "/v2/upload": return (200, json(["upload_url": "u"]))
            case "/v2/transcript": return (200, json(["id": "t2", "status": "queued"]))
            default: return (200, json(["id": "t2", "status": "error", "error": "Audio file is empty"]))
            }
        }
        do {
            _ = try await client().transcribe(file: file, track: .me)
            XCTFail("expected error")
        } catch {
            XCTAssertTrue("\(error)".contains("Audio file is empty"))
        }
    }

    func testHTTP500Throws() async {
        StubURLProtocol.handler = { _ in (500, Data("oops".utf8)) }
        do {
            _ = try await client().transcribe(file: file, track: .me)
            XCTFail("expected error")
        } catch {
            XCTAssertTrue("\(error)".contains("500"))
        }
    }

    func testNoUtterancesReturnsEmpty() async throws {
        StubURLProtocol.handler = { r in
            switch r.url.path {
            case "/v2/upload": return (200, json(["upload_url": "u"]))
            case "/v2/transcript": return (200, json(["id": "t3", "status": "queued"]))
            default: return (200, json(["id": "t3", "status": "completed", "utterances": NSNull()]))
            }
        }
        let result = try await client().transcribe(file: file, track: .me)
        XCTAssertEqual(result, [])
    }

    func testUsesWordTimesAndSplitsAtLongPauses() async throws {
        func w(_ text: String, _ start: Int, _ end: Int) -> [String: Any] { ["text": text, "start": start, "end": end] }
        StubURLProtocol.handler = { r in
            switch r.url.path {
            case "/v2/upload": return (200, json(["upload_url": "u"]))
            case "/v2/transcript": return (200, json(["id": "t4", "status": "queued"]))
            default: return (200, json(["id": "t4", "status": "completed", "utterances": [
                ["speaker": "A", "start": 0, "end": 45000, "text": "Good morning. Okay, send it.",
                 "words": [w("Good", 1000, 1300), w("morning.", 1300, 1900), w("Okay,", 40000, 40400), w("send", 40500, 40800), w("it.", 40800, 41000)]],
                ["speaker": "B", "start": 14193, "end": 26754, "text": "I still need it.",
                 "words": [w("I", 22062, 22200), w("still", 22200, 22500), w("need", 22500, 22900), w("it.", 22900, 26754)]],
            ]]))
            }
        }
        let result = try await client().transcribe(file: file, track: .me)
        XCTAssertEqual(result.map(\.withoutWords), [
            Utterance(track: .me, speakerLabel: "A", start: 1.0, end: 1.9, text: "Good morning."),
            Utterance(track: .me, speakerLabel: "A", start: 40.0, end: 41.0, text: "Okay, send it."),
            Utterance(track: .me, speakerLabel: "B", start: 22.062, end: 26.754, text: "I still need it."),
        ])
    }
}

extension Utterance {
    var withoutWords: Utterance { Utterance(track: track, speakerLabel: speakerLabel, start: start, end: end, text: text) }
}

final class AssemblyAISplitTests: XCTestCase {
    func testSplitKeepsWordTimes() {
        let raw = AssemblyAIClient.RawUtterance(speaker: "A", start: 0, end: 3000, text: "Ship it Friday", words: [
            .init(text: "Ship", start: 1000, end: 1300), .init(text: "it", start: 1300, end: 1500), .init(text: "Friday", start: 1500, end: 2000),
        ])
        let u = AssemblyAIClient.split(raw, track: .me)
        XCTAssertEqual(u.first?.words, [Word(text: "Ship", start: 1.0, end: 1.3), Word(text: "it", start: 1.3, end: 1.5),
                                        Word(text: "Friday", start: 1.5, end: 2.0)])
    }
}
