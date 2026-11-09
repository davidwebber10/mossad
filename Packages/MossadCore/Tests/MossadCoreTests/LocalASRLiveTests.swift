import AVFoundation
import XCTest
@testable import MossadCore

/// Runs each local model on a short spoken file. The first run downloads the model, so it runs only when asked:
/// `MOSSAD_LOCAL_ASR_TEST=1 swift test --filter LocalASRLiveTests`
final class LocalASRLiveTests: XCTestCase {
    private static let sentence = "We should ship the cushions on Friday. The chairs can wait until Monday."

    func testParakeetV3() async throws { try await run(.parakeetV3) }
    func testParakeetV2() async throws { try await run(.parakeetV2) }

    private func run(_ model: LocalModel) async throws {
        guard ProcessInfo.processInfo.environment["MOSSAD_LOCAL_ASR_TEST"] == "1" else { throw XCTSkip("MOSSAD_LOCAL_ASR_TEST not set") }
        let file = try Self.speech()
        let transcriber = LocalTranscriber(model: model)
        let first = Date()
        let utterances = try await transcriber.transcribe(file: file, track: .me) { _ in }
        let firstSeconds = Date().timeIntervalSince(first)
        let again = Date()
        _ = try await transcriber.transcribe(file: file, track: .me) { _ in }
        let warmSeconds = Date().timeIntervalSince(again)
        let text = utterances.map(\.text).joined(separator: " ")
        let words = utterances.flatMap { $0.words ?? [] }
        print(String(format: "LOCAL-ASR %@: first run %.1f s (with load), warm run %.2f s, %d words: %@", model.name, firstSeconds, warmSeconds, words.count, text))
        if let w = words.first { print(String(format: "LOCAL-ASR %@: first word \"%@\" %.2f-%.2f s", model.name, w.text, w.start, w.end)) }
        XCTAssertTrue(text.lowercased().contains("friday"), text)
        XCTAssertTrue(words.allSatisfy { $0.end >= $0.start }, "every word has a time")
        XCTAssertEqual(words.map(\.start), words.map(\.start).sorted(), "words come in order")
    }

    /// About 5 seconds of a system voice, as 16 kHz mono Float32 like the recorded tracks.
    static func speech() throws -> URL {
        let file = tempDirectory().appendingPathComponent("me.caf")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "--data-format=LEF32@16000", sentence]
        try say.run()
        say.waitUntilExit()
        return file
    }
}
