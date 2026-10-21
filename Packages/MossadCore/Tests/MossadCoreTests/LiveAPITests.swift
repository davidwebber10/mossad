import AVFoundation
import XCTest
@testable import MossadCore

/// Calls the real services. Runs only when the keys are in the environment:
/// `doppler run --project dispatch --config prd -- swift test --filter LiveAPITests`
final class LiveAPITests: XCTestCase {
    func testAssemblyAITranscribesSpeech() async throws {
        guard let key = ProcessInfo.processInfo.environment["ASSEMBLYAI"] else { throw XCTSkip("ASSEMBLYAI not set") }
        let dir = tempDirectory()
        let aiff = dir.appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, "We should ship the cushions on Friday. The Adirondack chairs can wait until Monday."]
        try say.run()
        say.waitUntilExit()
        let caf = dir.appendingPathComponent("me.caf")
        let input = try AVAudioFile(forReading: aiff)
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length))!
        try input.read(into: buffer)
        let writer = try TrackWriter(url: caf, startTime: Date(), clock: { Date() })
        try writer.append(buffer)
        writer.close()

        let utterances = try await AssemblyAIClient(apiKey: key, pollInterval: .seconds(2)).transcribe(file: caf, track: .me)
        let text = utterances.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("cushions"), text)
        XCTAssertTrue(text.contains("friday"), text)
    }

    /// Same synthetic voice should score well above the match threshold; different voices below it.
    func testFluidEmbeddingsSeparateVoices() async throws {
        guard ProcessInfo.processInfo.environment["ASSEMBLYAI"] != nil else { throw XCTSkip("live tests not enabled") }
        let provider = FluidEmbeddingProvider()
        func embed(_ voice: String, _ text: String) async throws -> [Float] {
            let aiff = tempDirectory().appendingPathComponent("v.caf")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", voice, "-o", aiff.path, "--data-format=LEF32@16000", text]
            try say.run()
            say.waitUntilExit()
            let file = try AVAudioFile(forReading: aiff)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            return try await provider.embedding(for: samples)
        }
        let a1 = try await embed("Samantha", "The cushions ship on Friday from the Syracuse plant, and the chairs follow next week.")
        let a2 = try await embed("Samantha", "Can you send me the forecast for the outdoor dining collection before the meeting?")
        let b1 = try await embed("Daniel", "The cushions ship on Friday from the Syracuse plant, and the chairs follow next week.")
        let same = VoiceLibrary.cosine(a1, a2)
        let different = VoiceLibrary.cosine(a1, b1)
        print("LIVE same-voice \(same) different-voice \(different)")
        XCTAssertGreaterThan(same, 0.65)
        XCTAssertLessThan(different, 0.65)
    }

    func testClaudeSummarizesTranscript() async throws {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY_POLYWOOD_ANALYTICS"] else { throw XCTSkip("key not set") }
        let transcript = """
        [00:00:05] David Webber: Where are we on the cushion shipment?
        [00:00:09] Alex Rivera: Freight is booked. It leaves the Syracuse plant on Friday.
        [00:00:15] David Webber: Good. Can you send me the updated forecast by Thursday?
        [00:00:19] Alex Rivera: Yes, I will send it Thursday morning.
        """
        let result = try await ClaudeSummarizer(apiKey: key).summarize(transcript: transcript, title: "Cushion check-in")
        print("LIVE summary: \(result.summary) | items: \(result.actionItems)")
        XCTAssertFalse(result.summary.isEmpty)
        XCTAssertTrue(result.actionItems.contains { $0.contains("Alex Rivera") && $0.lowercased().contains("forecast") })
    }
}
