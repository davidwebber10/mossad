import FluidAudio
import XCTest
@testable import MossadCore

/// Compares on-device Parakeet transcription with the AssemblyAI transcripts already saved for real calls.
/// Nothing leaves the Mac. Runs only when asked:
/// `MOSSAD_ASR_CALLS=20261021-150259,20261021-160131 swift test --filter LocalASRExperiment`
final class LocalASRExperiment: XCTestCase {
    func testParakeetAgainstAssemblyAI() async throws {
        guard let ids = ProcessInfo.processInfo.environment["MOSSAD_ASR_CALLS"]?.split(separator: ",").map(String.init) else {
            throw XCTSkip("MOSSAD_ASR_CALLS not set")
        }
        let loadStart = Date()
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let asr = AsrManager()
        try await asr.loadModels(models)
        print("ASR models ready in \(Int(Date().timeIntervalSince(loadStart))) s")

        var totalAudio = 0.0, totalTime = 0.0, totalErrors = 0, totalWords = 0
        for id in ids {
            let dir = Paths.live.callDirectory(id)
            let record = try CallRecord.load(from: dir)
            for (track, reference) in [(Track.me, record.meUtterances ?? []), (Track.them, record.themUtterances ?? [])] {
                let url = dir.appendingPathComponent(track.fileName)
                var state = try TdtDecoderState()
                let started = Date()
                let result = try await asr.transcribe(url, decoderState: &state)
                let seconds = Date().timeIntervalSince(started)
                let ref = Self.words(reference.map(\.text).joined(separator: " "))
                let hyp = Self.words(result.text)
                // MOSSAD_ASR_OUT keeps both texts for a closer look at where they differ.
                if let out = ProcessInfo.processInfo.environment["MOSSAD_ASR_OUT"] {
                    try ref.joined(separator: " ").write(toFile: "\(out)/\(id)-\(track.rawValue)-assemblyai.txt", atomically: true, encoding: .utf8)
                    try hyp.joined(separator: " ").write(toFile: "\(out)/\(id)-\(track.rawValue)-local.txt", atomically: true, encoding: .utf8)
                }
                let errors = Self.distance(ref, hyp)
                totalAudio += result.duration
                totalTime += seconds
                totalErrors += errors
                totalWords += ref.count
                print(String(format: "RESULT %@ %@ %@: %.0f min audio in %.1f s (%.0fx), %d AssemblyAI words, %d local words, difference %.1f%%",
                             id, record.title, track.rawValue, result.duration / 60, seconds, result.duration / max(seconds, 0.01),
                             ref.count, hyp.count, 100 * Double(errors) / Double(max(ref.count, 1))))
                for sample in Self.samples(ref: ref, hyp: hyp, count: 4) { print("SAMPLE \(id) \(track.rawValue): \(sample)") }
            }
        }
        print(String(format: "TOTAL %.0f min audio in %.0f s (%.0fx real time), difference from AssemblyAI %.1f%% of %d words",
                     totalAudio / 60, totalTime, totalAudio / max(totalTime, 0.01), 100 * Double(totalErrors) / Double(max(totalWords, 1)), totalWords))
    }

    func testLocalTranscriberLabelsSpeakers() async throws {
        guard let id = ProcessInfo.processInfo.environment["MOSSAD_ASR_CALLS"]?.split(separator: ",").first.map(String.init) else {
            throw XCTSkip("MOSSAD_ASR_CALLS not set")
        }
        let dir = Paths.live.callDirectory(id)
        let started = Date()
        let utterances = try await LocalTranscriber().transcribe(file: dir.appendingPathComponent(Track.them.fileName), track: .them)
        let reference = Set((try CallRecord.load(from: dir).themUtterances ?? []).map(\.speakerLabel))
        print("LOCAL \(id): \(utterances.count) utterances, speakers \(Set(utterances.map(\.speakerLabel)).sorted()) (AssemblyAI found \(reference.count)), \(Int(Date().timeIntervalSince(started))) s")
        for u in utterances.prefix(6) { print("LOCAL  [\(Int(u.start))s] \(u.speakerLabel): \(u.text.prefix(90))") }
        XCTAssertFalse(utterances.isEmpty)
    }

    /// Lowercase words without punctuation, and without the fillers that AssemblyAI keeps and Parakeet drops.
    static func words(_ text: String) -> [String] {
        let fillers: Set<String> = ["um", "uh", "uhm", "umm", "er", "erm", "hmm", "mm", "mhm"]
        return text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init).filter { !fillers.contains($0) }
    }

    /// Word-level edit distance, with two rolling rows to keep memory small.
    static func distance(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count), current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// A few 12-word windows, evenly spaced, where the two transcripts differ, side by side.
    static func samples(ref: [String], hyp: [String], count: Int) -> [String] {
        guard ref.count > 24, hyp.count > 24 else { return [] }
        var out: [String] = []
        let step = ref.count / (count + 1)
        for k in 1...count {
            let i = k * step
            let j = min(hyp.count - 12, Int(Double(i) * Double(hyp.count) / Double(ref.count)))
            let a = ref[i..<min(ref.count, i + 12)].joined(separator: " "), b = hyp[max(0, j)..<min(hyp.count, j + 12)].joined(separator: " ")
            if a != b { out.append("AssemblyAI: \"\(a)\" | Local: \"\(b)\"") }
        }
        return out
    }
}
