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
        let a1 = try await embed("Samantha", "The cushions ship on Friday from the north plant, and the chairs follow next week.")
        let a2 = try await embed("Samantha", "Can you send me the forecast for the outdoor dining collection before the meeting?")
        let b1 = try await embed("Daniel", "The cushions ship on Friday from the north plant, and the chairs follow next week.")
        let same = VoiceLibrary.cosine(a1, a2)
        let different = VoiceLibrary.cosine(a1, b1)
        print("LIVE same-voice \(same) different-voice \(different)")
        XCTAssertGreaterThan(same, 0.65)
        XCTAssertLessThan(different, 0.65)
    }

    func testClaudeSummarizesTranscript() async throws {
        guard let key = APIKey.anthropic.value(in: ProcessInfo.processInfo.environment) else { throw XCTSkip("key not set") }
        let transcript = """
        [00:00:05] David Webber: Where are we on the cushion shipment?
        [00:00:09] Alex Rivera: Freight is booked. It leaves the north plant on Friday.
        [00:00:15] David Webber: Good. Can you send me the updated forecast by Thursday?
        [00:00:19] Alex Rivera: Yes, I will send it Thursday morning.
        """
        let result = try await ClaudeSummarizer(apiKey: key).summarize(transcript: transcript, title: "Cushion check-in")
        print("LIVE summary: \(result.summary) | items: \(result.actionItems)")
        XCTAssertFalse(result.summary.isEmpty)
        XCTAssertTrue(result.actionItems.contains { $0.owner == "Alex Rivera" && $0.task.lowercased().contains("forecast") })
        XCTAssertNotNil(result.headline)
    }

    /// Full pipeline on synthetic voices: me = Samantha, them = Daniel then Karen.
    func testEndToEndPipeline() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let aai = APIKey.assemblyai.value(in: env), let ant = APIKey.anthropic.value(in: env) else { throw XCTSkip("keys not set") }
        let paths = Paths(root: env["MOSSAD_E2E_ROOT"].map { URL(fileURLWithPath: $0) } ?? tempDirectory())
        try paths.ensureDirectories()
        let id = "20261020-143000"
        let dir = paths.callDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func speech(_ voice: String, _ text: String) throws -> [Float] {
            let url = tempDirectory().appendingPathComponent("s.caf")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", voice, "-o", url.path, "--data-format=LEF32@16000", text]
            try say.run()
            say.waitUntilExit()
            let f = try AVAudioFile(forReading: url)
            let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
            try f.read(into: b)
            return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
        }
        func place(_ parts: [(Double, [Float])], total: Double, to url: URL) throws {
            var samples = [Float](repeating: 0, count: Int(total * 16_000))
            for (at, s) in parts {
                let start = Int(at * 16_000)
                for i in 0..<min(s.count, samples.count - start) { samples[start + i] = s[i] }
            }
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
            b.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false).write(from: b)
        }
        let me1 = try speech("Samantha", "Good morning. Where are we on the cushion shipment for the Dallas store?")
        let them1 = try speech("Daniel", "Freight is booked. The truck leaves the north plant on Friday afternoon, and it should arrive on Tuesday.")
        let them2 = try speech("Karen", "I still need the final count of the Adirondack chairs before I can confirm the second truck.")
        let me2 = try speech("Samantha", "Okay. Daniel, please send me the updated forecast by Thursday morning.")
        try place([(1, me1), (40, me2)], total: 52, to: dir.appendingPathComponent("me.caf"))
        try place([(8, them1), (22, them2)], total: 52, to: dir.appendingPathComponent("them.caf"))
        let start = Date()
        try CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: start, end: start.addingTimeInterval(52), status: .recorded).save(to: dir)

        let library = VoiceLibrary(directory: paths.voices)
        let pipeline = Pipeline(paths: paths, transcriber: AssemblyAIClient(apiKey: aai, pollInterval: .seconds(2)), library: library,
                                embeddings: FluidEmbeddingProvider(), calendar: FakeCalendar(), summarizer: ClaudeSummarizer(apiKey: ant),
                                notify: { _ in })
        await pipeline.process(id)
        let r = try CallRecord.load(from: dir)
        let md = try String(contentsOfFile: try XCTUnwrap(r.markdownPath), encoding: .utf8)
        print("LIVE-E2E\n" + md)
        XCTAssertEqual(r.status, .written)
        XCTAssertEqual(r.speakerNames.values.filter { $0 == "David Webber" }.count, 1)
        XCTAssertEqual(r.unknownSpeakers.count, 2, "Daniel and Karen should be two unknown speakers: \(r.unknownSpeakers)")
        XCTAssertNotNil(r.summary)

        // Name them, then a second call with the same voices is labeled automatically.
        let daniel = r.utterances.first { $0.text.contains("Freight") }!.speakerKey
        let karen = r.utterances.first { $0.text.contains("Adirondack") }!.speakerKey
        await pipeline.applyNames(callID: id, names: [daniel: "Alex Rivera", karen: "Amy Lee"])
        let id2 = "20261020-160000"
        let dir2 = paths.callDirectory(id2)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        let them3 = try speech("Daniel", "The second truck can go out on Monday if the count is final by then.")
        let them4 = try speech("Karen", "I will have the count by Friday, and I will email everyone the numbers.")
        let me3 = try speech("Samantha", "Great, that works for me. Let us plan on Monday for the second truck.")
        try place([(1, me3)], total: 40, to: dir2.appendingPathComponent("me.caf"))
        try place([(10, them3), (24, them4)], total: 40, to: dir2.appendingPathComponent("them.caf"))
        try CallRecord(id: id2, platform: .meet, bundleID: "com.google.Chrome", start: start.addingTimeInterval(5400),
                       end: start.addingTimeInterval(5440), status: .recorded).save(to: dir2)
        await pipeline.process(id2)
        let r2 = try CallRecord.load(from: dir2)
        print("LIVE-E2E-2 names: \(r2.speakerNames) unknown: \(r2.unknownSpeakers)")
        XCTAssertEqual(Set(r2.speakerNames.values), ["David Webber", "Alex Rivera", "Amy Lee"])
        XCTAssertEqual(r2.unknownSpeakers, [])
    }
}
