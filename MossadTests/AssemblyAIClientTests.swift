import XCTest
@testable import MossadService

final class AssemblyAIClientTests: XCTestCase {
    func testParseSessionBegins() throws {
        let json = "{\"message_type\": \"SessionBegins\", \"session_id\": \"abc123\", \"expires_at\": \"2026-03-20T12:00:00Z\"}"
        let message = try AssemblyAIMessage.parse(json)
        guard case .sessionBegins(let sessionId) = message else { XCTFail("Expected sessionBegins"); return }
        XCTAssertEqual(sessionId, "abc123")
    }

    func testParsePartialTranscript() throws {
        let json = "{\"message_type\": \"PartialTranscript\", \"text\": \"hello world\", \"audio_start\": 0, \"audio_end\": 2500}"
        let message = try AssemblyAIMessage.parse(json)
        guard case .partialTranscript(let text) = message else { XCTFail("Expected partialTranscript"); return }
        XCTAssertEqual(text, "hello world")
    }

    func testParseFinalTranscript() throws {
        let json = """
        {"message_type": "FinalTranscript", "text": "We need to fix the auth bug", "audio_start": 1000, "audio_end": 3500, "words": [{"text": "We", "start": 1000, "end": 1200, "speaker": "A"}, {"text": "need", "start": 1200, "end": 1400, "speaker": "A"}]}
        """
        let message = try AssemblyAIMessage.parse(json)
        guard case .finalTranscript(let transcript) = message else { XCTFail("Expected finalTranscript"); return }
        XCTAssertEqual(transcript.text, "We need to fix the auth bug")
        XCTAssertEqual(transcript.audioStartMs, 1000)
        XCTAssertEqual(transcript.audioEndMs, 3500)
        XCTAssertEqual(transcript.speakerLabel, "A")
    }

    func testParseFinalTranscriptPicksMajoritySpeaker() throws {
        let json = """
        {"message_type": "FinalTranscript", "text": "Hello there", "audio_start": 0, "audio_end": 2000, "words": [{"text": "Hello", "start": 0, "end": 500, "speaker": "A"}, {"text": "there", "start": 500, "end": 1000, "speaker": "B"}, {"text": "friend", "start": 1000, "end": 1500, "speaker": "A"}]}
        """
        let message = try AssemblyAIMessage.parse(json)
        guard case .finalTranscript(let transcript) = message else { XCTFail("Expected finalTranscript"); return }
        XCTAssertEqual(transcript.speakerLabel, "A")
    }

    func testParseErrorMessage() throws {
        let json = "{\"message_type\": \"SessionTerminated\", \"error\": \"Session expired\"}"
        let message = try AssemblyAIMessage.parse(json)
        guard case .terminated = message else { XCTFail("Expected terminated"); return }
    }
}
