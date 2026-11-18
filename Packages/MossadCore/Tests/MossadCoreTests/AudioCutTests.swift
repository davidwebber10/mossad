import AVFoundation
import XCTest
@testable import MossadCore

final class AudioCutTests: XCTestCase {
    /// A track as `TrackWriter` writes it (16 kHz mono Int16 CAF), each sample a different value, so a sample that
    /// moved, doubled, or went missing shows.
    static func writeTrack(_ url: URL, frames: Int) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: TrackWriter.fileSettings, commonFormat: .pcmFormatInt16, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.int16ChannelData![0][i] = Int16(truncatingIfNeeded: i % 30_000 - 15_000) }
        try file.write(from: buffer)
    }

    static func samples(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        var out: [Int16] = []
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096)!
        // `read` may return fewer frames than asked for, so read until the end.
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            out.append(contentsOf: UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
        }
        return out
    }

    func testTwoRangesAddUpToTheSourceSampleForSample() throws {
        let dir = tempDirectory()
        let source = dir.appendingPathComponent("me.caf")
        try Self.writeTrack(source, frames: 16_000 * 7 + 123)
        let a = dir.appendingPathComponent("a.caf"), b = dir.appendingPathComponent("b.caf")
        let first = try AudioCut.copy(source, from: 0, to: 3.25, into: a)
        let second = try AudioCut.copy(source, from: 3.25, to: nil, into: b)
        XCTAssertEqual(first, 52_000)
        XCTAssertEqual(first + second, try AudioCut.frames(source))
        XCTAssertEqual(try AudioCut.frames(a), first)
        XCTAssertEqual(try AudioCut.frames(b), second)
        XCTAssertEqual(try Self.samples(a) + Self.samples(b), try Self.samples(source))
    }

    func testTheSampleAtABorderIsInExactlyOnePart() throws {
        let dir = tempDirectory()
        let source = dir.appendingPathComponent("them.caf")
        try Self.writeTrack(source, frames: 16_000 * 3)
        let cuts: [TimeInterval] = [0.00003, 1.0000312, 2.99997]
        var parts: [[Int16]] = []
        for (i, from) in ([0] + cuts).enumerated() {
            let to = i < cuts.count ? cuts[i] : nil
            let out = dir.appendingPathComponent("\(i).caf")
            _ = try AudioCut.copy(source, from: from, to: to, into: out)
            parts.append(try Self.samples(out))
        }
        XCTAssertEqual(parts.flatMap { $0 }, try Self.samples(source))
    }

    func testTheCopyHasTheTrackWritersFormat() throws {
        let dir = tempDirectory()
        let source = dir.appendingPathComponent("me.caf")
        try Self.writeTrack(source, frames: 16_000 * 2)
        let out = dir.appendingPathComponent("out.caf")
        _ = try AudioCut.copy(source, from: 0.5, to: 1.5, into: out)
        let file = try AVAudioFile(forReading: out)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(file.length, 16_000)
    }

    func testARangePastTheEndIsRefused() throws {
        let dir = tempDirectory()
        let source = dir.appendingPathComponent("me.caf")
        try Self.writeTrack(source, frames: 16_000 * 2)
        let out = dir.appendingPathComponent("out.caf")
        XCTAssertThrowsError(try AudioCut.copy(source, from: 2.5, to: nil, into: out))
        XCTAssertThrowsError(try AudioCut.copy(source, from: 1, to: 2.5, into: out))
        XCTAssertThrowsError(try AudioCut.copy(source, from: 1.5, to: 1, into: out))
        XCTAssertThrowsError(try AudioCut.copy(source, from: -1, to: 1, into: out))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testACopyReplacesAnUnfinishedOne() throws {
        let dir = tempDirectory()
        let source = dir.appendingPathComponent("me.caf")
        try Self.writeTrack(source, frames: 16_000 * 2)
        let out = dir.appendingPathComponent("out.caf")
        try Data("half a file".utf8).write(to: out)
        XCTAssertEqual(try AudioCut.copy(source, from: 1, to: nil, into: out), 16_000)
        XCTAssertEqual(try Self.samples(out), Array(try Self.samples(source)[16_000...]))
    }
}
