import AVFoundation
import XCTest
@testable import MossadCore

final class PhoneRecordingTests: XCTestCase {
    /// A 3 second AAC file like the phone writes.
    private func phoneAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        let file = try AVAudioFile(forWriting: url, settings: PhoneRecording.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.3 }
        try file.write(from: buffer)
        return url
    }

    func testAPhoneRecordingBecomesAnInPersonCallReadyToProcess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = Paths(root: root)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let rec = PhoneRecording(id: "20270115-090000", start: start, end: start.addingTimeInterval(3), title: "Offsite planning")
        let r = try PhoneRecording.importAudio(try phoneAudio(), recording: rec, into: paths)
        XCTAssertEqual(r.platform, .inPerson)
        XCTAssertEqual(r.status, .recorded)
        XCTAssertEqual(r.calendarTitle, "Offsite planning")
        let dir = paths.callDirectory("20270115-090000")
        let me = try AVAudioFile(forReading: dir.appendingPathComponent(Track.me.fileName))
        XCTAssertEqual(me.fileFormat.sampleRate, TrackWriter.sampleRate)
        XCTAssertEqual(Double(me.length) / me.fileFormat.sampleRate, 3, accuracy: 0.2)
        let them = try AVAudioFile(forReading: dir.appendingPathComponent(Track.them.fileName))
        XCTAssertEqual(them.length, 0, "A room has no call app: the second track is empty")
        XCTAssertEqual(try CallRecord.load(from: dir).id, "20270115-090000")
        XCTAssertThrowsError(try PhoneRecording.importAudio(try phoneAudio(), recording: rec, into: paths), "Never overwrite a call")
    }

    func testRecordingsUseTheirOwnRecordNames() {
        XCTAssertEqual(PhoneRecording.recordName("20270115-090000"), "rec-20270115-090000")
    }
}
