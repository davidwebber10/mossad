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
        XCTAssertEqual(utterances, [
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
}
