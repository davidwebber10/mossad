import AVFoundation
import XCTest
@testable import MossadCore

final class RoomAudioTests: XCTestCase {
    private func temp() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A part as the recorder writes it, `seconds` long.
    private func writePart(_ url: URL, seconds: Double, rate: Double = TrackWriter.sampleRate) throws {
        let file = try AVAudioFile(forWriting: url, settings: RoomAudio.recordingSettings(sampleRate: rate),
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        let n = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n)!
        buffer.frameLength = n
        for i in 0..<Int(n) { buffer.int16ChannelData![0][i] = Int16(sin(Double(i) * 0.05) * 8000) }
        try file.write(from: buffer)
    }

    func testPartsAreFoundInOrderAndIdsCoverEveryFile() throws {
        let dir = temp()
        for n in [2, 10, 1] { try writePart(RoomAudio.part("20270115-090000", n, in: dir), seconds: 0.1) }
        try Data().write(to: RoomAudio.finished("20270114-080000", in: dir))
        try Data().write(to: dir.appendingPathComponent(Outbox.fileName))
        XCTAssertEqual(RoomAudio.parts(of: "20270115-090000", in: dir).map(\.lastPathComponent),
                       ["20270115-090000.part1.caf", "20270115-090000.part2.caf", "20270115-090000.part10.caf"])
        XCTAssertEqual(RoomAudio.ids(in: dir), ["20270115-090000", "20270114-080000"])
    }

    func testFinishJoinsThePartsIntoOneFileTheMacCanRead() throws {
        let dir = temp(), id = "20270115-090000"
        try writePart(RoomAudio.part(id, 1, in: dir), seconds: 2)
        try writePart(RoomAudio.part(id, 2, in: dir), seconds: 1.5, rate: 44_100)
        XCTAssertEqual(RoomAudio.length(of: id, in: dir)!, 3.5, accuracy: 0.01)
        let length = try RoomAudio.finish(id, in: dir)
        XCTAssertEqual(length, 3.5, accuracy: 0.1)
        XCTAssertEqual(RoomAudio.parts(of: id, in: dir), [], "The parts go once the file is complete")
        let out = try AVAudioFile(forReading: RoomAudio.finished(id, in: dir))
        XCTAssertEqual(out.fileFormat.sampleRate, TrackWriter.sampleRate)
        XCTAssertEqual(RoomAudio.length(of: id, in: dir)!, 3.5, accuracy: 0.1)
        XCTAssertEqual(try RoomAudio.finish(id, in: dir), 3.5, accuracy: 0.1, "Finishing again is safe")
    }

    func testAPartThatCannotBeReadStaysOnDisk() throws {
        let dir = temp(), id = "20270115-090000"
        try writePart(RoomAudio.part(id, 1, in: dir), seconds: 1)
        try Data(repeating: 7, count: 50_000).write(to: RoomAudio.part(id, 2, in: dir))
        XCTAssertThrowsError(try RoomAudio.finish(id, in: dir))
        XCTAssertEqual(RoomAudio.parts(of: id, in: dir).count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RoomAudio.finished(id, in: dir).path))
    }

    func testAnEmptyPartAddsNothing() throws {
        let dir = temp(), id = "20270115-090000"
        try writePart(RoomAudio.part(id, 1, in: dir), seconds: 1)
        try Data().write(to: RoomAudio.part(id, 2, in: dir))
        XCTAssertEqual(try RoomAudio.finish(id, in: dir), 1, accuracy: 0.1)
    }

    func testDeleteRemovesEveryFileOfOneRecording() throws {
        let dir = temp()
        try writePart(RoomAudio.part("a", 1, in: dir), seconds: 0.1)
        try Data().write(to: RoomAudio.finished("a", in: dir))
        try writePart(RoomAudio.part("b", 1, in: dir), seconds: 0.1)
        RoomAudio.delete("a", in: dir)
        XCTAssertEqual(RoomAudio.ids(in: dir), ["b"])
    }
}
