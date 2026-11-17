import AVFoundation
import XCTest
@testable import MossadCore

final class CallImportFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The 3 second AAC file of `PhoneRecordingTests`, under a name that a shared call could have.
    private func callAudio() throws -> URL {
        let url = dir.appendingPathComponent("Call with Sam Carter.m4a")
        let file = try AVAudioFile(forWriting: url, settings: PhoneRecording.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.3 }
        try file.write(from: buffer)
        return url
    }

    func testAReadableFileGivesItsNameTypeSizeLengthAndFileDate() async throws {
        let url = try callAudio()
        let f = await CallImport.read(url)
        XCTAssertEqual(f.name, "Call with Sam Carter.m4a")
        XCTAssertEqual(f.typeIdentifier, "com.apple.m4a-audio")
        XCTAssertGreaterThan(f.bytes ?? 0, 0)
        XCTAssertEqual(f.length ?? 0, 3, accuracy: 0.2)
        XCTAssertEqual(f.fileDate?.timeIntervalSinceNow ?? -999, 0, accuracy: 60)
        XCTAssertEqual(f.metadataDate?.timeIntervalSinceNow ?? -999, 0, accuracy: 60,
                       "The AAC writer puts the time of the write in the file's own creation date")
    }

    func testAFileThatIsNotAudioHasNoLength() async throws {
        let url = dir.appendingPathComponent("notes.m4a")
        try Data("hello".utf8).write(to: url)
        let f = await CallImport.read(url)
        XCTAssertNil(f.length)
        XCTAssertEqual(f.bytes, 5)
        XCTAssertEqual(f.name, "notes.m4a")
        XCTAssertNil(f.metadataDate, "A file AVFoundation cannot read has no metadata date: unknown is nil")
    }

    func testAMissingFileGivesOnlyItsName() async {
        let f = await CallImport.read(URL(fileURLWithPath: "/nonexistent/gone.m4a"))
        XCTAssertEqual(f, CallImport.File(name: "gone.m4a", typeIdentifier: nil, bytes: nil, length: nil, metadataDate: nil, fileDate: nil))
    }
}
