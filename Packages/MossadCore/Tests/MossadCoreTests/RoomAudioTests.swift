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
        let length = try RoomAudio.finish(id, in: dir).length
        XCTAssertEqual(length, 3.5, accuracy: 0.1)
        XCTAssertEqual(RoomAudio.parts(of: id, in: dir), [], "The parts go once the file is complete")
        let out = try AVAudioFile(forReading: RoomAudio.finished(id, in: dir))
        XCTAssertEqual(out.fileFormat.sampleRate, TrackWriter.sampleRate)
        XCTAssertEqual(RoomAudio.length(of: id, in: dir)!, 3.5, accuracy: 0.1)
        XCTAssertEqual(try RoomAudio.finish(id, in: dir).length, 3.5, accuracy: 0.1, "Finishing again is safe")
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
        XCTAssertEqual(try RoomAudio.finish(id, in: dir).length, 1, accuracy: 0.1)
    }

    func testTheStartComesBackFromTheId() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(RoomAudio.start(of: CallID.make(start)), start)
        XCTAssertNil(RoomAudio.start(of: "not-an-id"))
    }

    func testAJoinInProgressIsNotARecording() throws {
        let dir = temp()
        try Data().write(to: dir.appendingPathComponent("20270115-090000.joining.m4a"))
        XCTAssertEqual(RoomAudio.ids(in: dir), [])
    }

    func testDeleteRemovesEveryFileOfOneRecording() throws {
        let dir = temp()
        try writePart(RoomAudio.part("a", 1, in: dir), seconds: 0.1)
        try Data().write(to: RoomAudio.finished("a", in: dir))
        try writePart(RoomAudio.part("b", 1, in: dir), seconds: 0.1)
        RoomAudio.delete("a", in: dir)
        XCTAssertEqual(RoomAudio.ids(in: dir), ["b"])
    }

    // MARK: Review fixes

    /// A part whose header promises `seconds` of audio, with the file cut to `kept` of them.
    private func writeCutPart(_ url: URL, seconds: Double, kept: Double) throws {
        try writePart(url, seconds: seconds)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 4096 + UInt64(kept * TrackWriter.sampleRate) * 2)
        try handle.close()
    }

    func testAPartCutShortFailsTheJoinAndEveryPartStays() throws {
        let dir = temp(), id = "20270115-090000"
        try writePart(RoomAudio.part(id, 1, in: dir), seconds: 1)
        try writeCutPart(RoomAudio.part(id, 2, in: dir), seconds: 4, kept: 1)
        XCTAssertThrowsError(try RoomAudio.finish(id, in: dir)) { XCTAssertTrue($0 is RoomAudio.Unreadable) }
        XCTAssertEqual(RoomAudio.parts(of: id, in: dir).count, 2, "A read that stops early is not the end of the part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: RoomAudio.finished(id, in: dir).path))
    }

    func testSalvageJoinsWhatCanBeReadAndSetsTheBadPartAside() throws {
        let dir = temp(), id = "20270115-090000"
        try writePart(RoomAudio.part(id, 1, in: dir), seconds: 2)
        try Data(repeating: 7, count: 50_000).write(to: RoomAudio.part(id, 2, in: dir))
        try writePart(RoomAudio.part(id, 3, in: dir), seconds: 1)
        let joined = try RoomAudio.finish(id, in: dir, salvage: true)
        XCTAssertEqual(joined.length, 3, accuracy: 0.1)
        XCTAssertEqual(joined.setAside, ["\(id).part2.unreadable.caf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(joined.setAside[0]).path))
        XCTAssertEqual(RoomAudio.parts(of: id, in: dir), [])
        XCTAssertEqual(RoomAudio.ids(in: dir), [id], "The part set aside is not a recording of its own")
        RoomAudio.delete(id, in: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(joined.setAside[0]).path),
                      "A part set aside is never deleted")
    }

    func testSalvageWithNothingReadableKeepsEverything() throws {
        let dir = temp(), id = "20270115-090000"
        try Data(repeating: 7, count: 50_000).write(to: RoomAudio.part(id, 1, in: dir))
        XCTAssertThrowsError(try RoomAudio.finish(id, in: dir, salvage: true))
        XCTAssertEqual(RoomAudio.parts(of: id, in: dir).count, 1)
    }

    func testOnlyARecordingThatIsShortByEveryMeasureIsSurelyShort() throws {
        let dir = temp()
        try writePart(RoomAudio.part("short", 1, in: dir), seconds: 2)
        XCTAssertTrue(RoomAudio.isSurelyShort("short", in: dir, minimum: 60))
        try writePart(RoomAudio.part("long", 1, in: dir), seconds: 3)
        XCTAssertFalse(RoomAudio.isSurelyShort("long", in: dir, minimum: 2))
        // A large part that does not open may hold the meeting: its length is unknown, not zero.
        try Data(repeating: 7, count: 500_000).write(to: RoomAudio.part("mixed", 1, in: dir))
        try writePart(RoomAudio.part("mixed", 2, in: dir), seconds: 1)
        XCTAssertFalse(RoomAudio.isSurelyShort("mixed", in: dir, minimum: 60))
        // A part that opens short but holds more bytes than it says.
        try writePart(RoomAudio.part("heavy", 1, in: dir), seconds: 1)
        let handle = try FileHandle(forWritingTo: RoomAudio.part("heavy", 1, in: dir))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: Int(TrackWriter.sampleRate) * 2 * 90))
        try handle.close()
        XCTAssertFalse(RoomAudio.isSurelyShort("heavy", in: dir, minimum: 60))
        XCTAssertFalse(RoomAudio.isSurelyShort("absent", in: dir, minimum: 60), "No audio is not a short recording")
    }

    func testAFolderThatCannotBeListedIsUnknownNotEmpty() throws {
        let dir = temp()
        XCTAssertEqual(RoomAudio.ids(in: dir.appendingPathComponent("never-made")), [], "No folder yet: no recordings")
        let file = dir.appendingPathComponent("a-file")
        try Data().write(to: file)
        XCTAssertNil(RoomAudio.ids(in: file))
    }

    func testAPartFromAWriterThatNeverClosedIsReadable() throws {
        let dir = temp(), id = "20270115-090000", rate = TrackWriter.sampleRate
        let live = dir.appendingPathComponent("live.caf")
        let file = try AVAudioFile(forWriting: live, settings: RoomAudio.recordingSettings(), commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate))!
        buffer.frameLength = AVAudioFrameCount(rate)
        for _ in 0..<5 { try file.write(from: buffer) }
        // The copy is what a stopped app leaves: the writer never closed the file.
        try FileManager.default.copyItem(at: live, to: RoomAudio.part(id, 1, in: dir))
        withExtendedLifetime(file) {}
        let length = try XCTUnwrap(RoomAudio.length(of: id, in: dir))
        XCTAssertGreaterThan(length, 3)
        XCTAssertEqual(try RoomAudio.finish(id, in: dir).length, length, accuracy: 0.1)
    }
}
