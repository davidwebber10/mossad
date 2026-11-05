import AVFoundation
import XCTest
@testable import MossadCore

final class UploadAudioTests: XCTestCase {
    /// The raw track is about 115 MB an hour; the upload is AAC, so a slow network sends far less.
    func testTheUploadIsSmallAndKeepsTheLength() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("me.caf")
        try writeSegments(raw, total: 60, [(0, 20, 200), (30, 50, 400)])
        let upload = try UploadAudio.compress(raw, into: dir)
        defer { try? FileManager.default.removeItem(at: upload) }
        XCTAssertEqual(upload.pathExtension, "m4a")
        let rawSize = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: raw.path)[.size] as? Int)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: upload.path)[.size] as? Int)
        XCTAssertLessThan(size * 4, rawSize)
        let a = try AVAudioFile(forReading: raw), b = try AVAudioFile(forReading: upload)
        XCTAssertEqual(Double(b.length) / b.fileFormat.sampleRate, Double(a.length) / a.fileFormat.sampleRate, accuracy: 0.1)
    }
}
