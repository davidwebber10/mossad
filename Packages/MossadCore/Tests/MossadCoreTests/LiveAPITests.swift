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
}
