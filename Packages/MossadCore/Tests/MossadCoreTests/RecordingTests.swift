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

    /// A meeting whose recording is in the archive, or whose tracks are gone, gave an error line at each pass.
    func testAMeetingThatCannotGetARecordingIsNotListedAsMissing() throws {
        let paths = Paths(root: tempDirectory())
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        func call(_ id: String, tracks: Bool, cloudKey: String? = nil) throws {
            let dir = paths.callDirectory(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var r = CallRecord(id: id, platform: .meet, bundleID: "com.google.Chrome", start: Date(), end: Date(), status: .written)
            r.cloudKey = cloudKey
            try r.save(to: dir)
            if tracks { try writeSegments(dir.appendingPathComponent("me.caf"), total: 5, [(0, 2, 200)]) }
        }
        try call("can", tracks: true)
        try call("no-tracks", tracks: false)
        try call("archived", tracks: true, cloudKey: "recordings/archived.m4a")
        XCTAssertEqual(Recording.missing(audioRoot: paths.audio).map(\.lastPathComponent), ["can"])
    }

    /// The pipeline's write step and the app's later pass can ask for the same recording at the same time.
    func testTwoRequestsForOneRecordingMakeOneWholeFile() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSegments(dir.appendingPathComponent("me.caf"), total: 60, [(0, 50, 200)])
        try writeSegments(dir.appendingPathComponent("them.caf"), total: 60, [(5, 55, 400)])
        DispatchQueue.concurrentPerform(iterations: 4) { _ in Recording.makeIfMissing(in: dir) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["me.caf", "recording.m4a", "them.caf"])
        let file = try AVAudioFile(forReading: Recording.url(in: dir))
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 60, accuracy: 0.5)
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
        r.speakerNames = ["me:A": "Avery Lane"]
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
        XCTAssertEqual(blocks.map(\.speaker), ["Avery Lane", "Speaker A", "Avery Lane"])
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
        XCTAssertEqual(talk.map(\.speaker), ["Speaker A", "Avery Lane"])
        XCTAssertEqual(talk.map(\.seconds), [10, 5])
    }

    /// A meeting with dozens of voices shows the top few and one line for the rest, so the card stays short.
    func testTalkTimeOverTheLimitFoldsTheRestIntoOthers() {
        let lengths: [(String, Double)] = [("A", 10), ("B", 9), ("C", 8), ("D", 7), ("E", 6)]
        let r = record(lengths.enumerated().map { i, l in
            Utterance(track: .them, speakerLabel: l.0, start: Double(i) * 100, end: Double(i) * 100 + l.1, text: "x")
        })
        let short = TranscriptBlock.talkTime(r, limit: 3)
        XCTAssertEqual(short.top.map(\.speaker), ["Speaker A", "Speaker B", "Speaker C"])
        XCTAssertEqual(short.others?.count, 2)
        XCTAssertEqual(short.others?.seconds, 13)
        XCTAssertNil(TranscriptBlock.talkTime(r, limit: 5).others)
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

    /// The turn that plays now must be the same one the scan of every turn found.
    func testTheCurrentTurnIsTheLastOneThatStartedBeforeThePlayTime() {
        let starts: [TimeInterval] = [0, 4, 4, 9.5, 30, 31, 120]
        let blocks = starts.enumerated().map { i, start in
            TranscriptBlock(id: i, speaker: "A", speakerKey: "them:A", start: start, end: start + 1, lines: [])
        }
        XCTAssertTrue(TranscriptBlock.startsAscend(blocks))
        for time in stride(from: -1.0, through: 130, by: 0.25) {
            XCTAssertEqual(TranscriptBlock.current(at: time, in: blocks), blocks.last { $0.start <= time }?.id, "at \(time) s")
        }
        XCTAssertNil(TranscriptBlock.current(at: 5, in: []))
        XCTAssertFalse(TranscriptBlock.startsAscend(blocks.reversed()))
    }
}
