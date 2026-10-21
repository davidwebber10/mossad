import AVFoundation
import XCTest
@testable import MossadCore

final class RecordingTests: XCTestCase {
    func testMixesBothTracksIntoOneCompressedFile() throws {
        let dir = tempDirectory()
        try writeSegments(dir.appendingPathComponent("me.caf"), total: 20, [(0, 5, 200)])
        try writeSegments(dir.appendingPathComponent("them.caf"), total: 30, [(10, 15, 400)])
        let url = try Recording.make(in: dir)
        XCTAssertEqual(url.lastPathComponent, "recording.m4a")
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 30, accuracy: 0.5)
        // Both voices are in the mix: sound at 2 s (me) and at 12 s (them), silence at 25 s.
        XCTAssertGreaterThan(try rms(file, at: 2), 0.1)
        XCTAssertGreaterThan(try rms(file, at: 12), 0.1)
        XCTAssertLessThan(try rms(file, at: 25), 0.01)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        XCTAssertLessThan(size, 30 * 6_000, "about 32 kbit/s")
    }

    func testOneMissingTrackStillMakesARecording() throws {
        let dir = tempDirectory()
        try writeSegments(dir.appendingPathComponent("them.caf"), total: 10, [(0, 5, 400)])
        XCTAssertNoThrow(try Recording.make(in: dir))
    }

    func testBackfillOnlyTouchesWrittenCalls() throws {
        let paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        for (id, status) in [("done", CallStatus.written), ("live", .recording)] {
            let dir = paths.callDirectory(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: Date(), end: Date(), status: status).save(to: dir)
            try writeSegments(dir.appendingPathComponent("me.caf"), total: 5, [(0, 2, 200)])
        }
        Recording.backfill(audioRoot: paths.audio)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Recording.url(in: paths.callDirectory("done")).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Recording.url(in: paths.callDirectory("live")).path))
    }

    func testNoTracksThrows() {
        XCTAssertThrowsError(try Recording.make(in: tempDirectory()))
    }

    private func rms(_ file: AVAudioFile, at second: Double) throws -> Float {
        let sr = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(second * sr)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(sr / 2))!
        try file.read(into: buffer, frameCount: AVAudioFrameCount(sr / 2))
        let d = buffer.floatChannelData![0]
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += d[i] * d[i] }
        return (sum / Float(max(1, buffer.frameLength))).squareRoot()
    }
}

final class TranscriptBlockTests: XCTestCase {
    func record(_ utterances: [Utterance]) -> CallRecord {
        var r = CallRecord(id: "x", platform: .meet, bundleID: "com.google.Chrome", start: Date(), end: Date(), status: .written)
        r.utterances = utterances
        r.speakerNames = ["me:A": "David Webber"]
        return r
    }

    func testJoinsConsecutiveLinesOfOneSpeaker() {
        let r = record([
            Utterance(track: .me, speakerLabel: "A", start: 0, end: 2, text: "Good morning."),
            Utterance(track: .me, speakerLabel: "A", start: 3, end: 5, text: "Can you hear me?"),
            Utterance(track: .them, speakerLabel: "A", start: 6, end: 7, text: "Yes."),
            Utterance(track: .me, speakerLabel: "A", start: 8, end: 9, text: "Great."),
        ])
        let blocks = TranscriptBlock.blocks(r)
        XCTAssertEqual(blocks.map(\.speaker), ["David Webber", "Speaker A", "David Webber"])
        XCTAssertEqual(blocks[0].lines.map(\.text), ["Good morning.", "Can you hear me?"])
        XCTAssertEqual(blocks[0].start, 0)
        XCTAssertEqual(blocks[1].start, 6)
    }

    func testTalkTimePerSpeakerLongestFirst() {
        let r = record([
            Utterance(track: .me, speakerLabel: "A", start: 0, end: 2, text: "Hi."),
            Utterance(track: .them, speakerLabel: "A", start: 3, end: 13, text: "Long answer."),
            Utterance(track: .me, speakerLabel: "A", start: 14, end: 17, text: "Thanks."),
        ])
        let talk = TranscriptBlock.talkTime(r)
        XCTAssertEqual(talk.map(\.speaker), ["Speaker A", "David Webber"])
        XCTAssertEqual(talk.map(\.seconds), [10, 5])
    }

    func testAPartOfAMergedMeetingStartsANewBlock() {
        var r = record([
            Utterance(track: .me, speakerLabel: "A", start: 0, end: 2, text: "Before."),
            Utterance(track: .me, speakerLabel: "A", start: 5, end: 7, text: "After."),
        ])
        r.parts = [CallPart(start: Date(), end: Date(), offset: 0), CallPart(start: Date(), end: Date(), offset: 4)]
        XCTAssertEqual(TranscriptBlock.blocks(r).count, 2)
    }

    func testALongPauseStartsANewBlock() {
        let r = record([
            Utterance(track: .me, speakerLabel: "A", start: 0, end: 2, text: "First."),
            Utterance(track: .me, speakerLabel: "A", start: 40, end: 42, text: "Much later."),
        ])
        XCTAssertEqual(TranscriptBlock.blocks(r).count, 2)
    }
}
