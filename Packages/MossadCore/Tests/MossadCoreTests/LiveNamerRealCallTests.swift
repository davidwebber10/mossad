import XCTest
@testable import MossadCore

/// Runs the live namer on a real recorded call with the real voice model. Skips unless MOSSAD_NAMER_CALL is
/// set to a call folder; never part of the normal run.
final class LiveNamerRealCallTests: XCTestCase {
    func testTheLiveNamerAgreesWithTheNote() async throws {
        guard let path = ProcessInfo.processInfo.environment["MOSSAD_NAMER_CALL"] else { throw XCTSkip("MOSSAD_NAMER_CALL not set") }
        let dir = URL(fileURLWithPath: path)
        let r = try CallRecord.load(from: dir)
        var live = LiveTranscript()
        // One live "label" per finished speaker key, first 5 minutes only, as the namer would see early in a call.
        let keys = Array(Set(r.utterances.filter { $0.track == .them }.map(\.speakerKey))).sorted()
        for (i, u) in r.utterances.enumerated() where u.track == .them && u.start < (Double(ProcessInfo.processInfo.environment["MOSSAD_NAMER_UNTIL"] ?? "300") ?? 300) {
            let label = String(UnicodeScalar(65 + keys.firstIndex(of: u.speakerKey)!)!)
            let msg = #"{"type":"Turn","turn_order":\#(i),"end_of_turn":true,"transcript":"x","speaker_label":"\#(label)","words":[{"start":\#(Int(u.start * 1000)),"end":\#(Int(u.start * 1000 + 100)),"word_is_final":true},{"start":\#(Int(u.end * 1000 - 100)),"end":\#(Int(u.end * 1000)),"word_is_final":true}]}"#
            live.apply(Data(msg.utf8), source: .them, at: u.start)
        }
        let library = VoiceLibrary(directory: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Mossad/Voices"))
        let started = Date()
        let names = await LiveSpeakerNamer(library: library, provider: FluidEmbeddingProvider()).names(for: live, themURL: dir.appendingPathComponent("them.caf"))
        print("NAMER seconds:", Date().timeIntervalSince(started))
        for (i, key) in keys.enumerated() {
            print("NAMER", key, "note:", r.speakerNames[key] ?? "unknown", "live:", names["0" + String(UnicodeScalar(65 + i)!)] ?? "-")
        }
    }
}
