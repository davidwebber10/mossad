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

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var call: PhoneRecording {
        PhoneRecording(id: "20270115-090000", start: t0, end: t0 + 600, title: nil, kind: .phoneCall, person: "Sam Carter", personID: "p1")
    }

    func testAPlanBecomesAPhoneCallRecording() {
        let plan = CallImport.Plan(id: "20270115-090000", start: t0, end: t0 + 600, title: nil,
                                   person: .init(name: "Sam Carter", personID: "p1"), convert: false)
        XCTAssertEqual(PhoneRecording(plan), call)
        XCTAssertTrue(call.isPhoneCall)
    }

    func testAPayloadFromBeforeTheNewFieldsStillReads() throws {
        let p = try JSONDecoder().decode(PhoneRecording.self, from: Data(#"{"id":"20270115-090000","start":0,"end":3,"title":"Offsite planning"}"#.utf8))
        XCTAssertNil(p.kind)
        XCTAssertNil(p.person)
        XCTAssertNil(p.personID)
        XCTAssertFalse(p.isPhoneCall)
        XCTAssertEqual(p.title, "Offsite planning")
    }

    func testAPhoneCallIsWrittenWithItsKindAndPerson() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(call)) as! [String: Any]
        XCTAssertEqual(json["kind"] as? String, "phoneCall")
        XCTAssertEqual(json["person"] as? String, "Sam Carter")
        XCTAssertEqual(json["personID"] as? String, "p1")
        XCTAssertEqual(try JSONDecoder().decode(PhoneRecording.self, from: JSONEncoder().encode(call)), call)
    }

    func testARoomRecordingIsWrittenWithNoNewKeys() throws {
        let room = PhoneRecording(id: "a", start: t0, end: t0 + 3, title: "Offsite")
        XCTAssertEqual(Set((try JSONSerialization.jsonObject(with: JSONEncoder().encode(room)) as! [String: Any]).keys), ["id", "start", "end", "title"])
        XCTAssertEqual(Set(room.fields.keys), ["start", "end", "title"])
    }

    func testAKindThisBuildDoesNotKnowReadsAsARoomRecording() throws {
        let p = try JSONDecoder().decode(PhoneRecording.self, from: Data(#"{"id":"a","start":0,"end":3,"kind":"voicemail"}"#.utf8))
        XCTAssertNil(p.kind)
        XCTAssertFalse(p.isPhoneCall)
    }

    func testTheStoreFieldsRoundTrip() {
        XCTAssertEqual(Set(call.fields.keys), ["start", "end", "kind", "person", "personID"])
        XCTAssertEqual(call.fields["kind"], .string("phoneCall"))
        XCTAssertEqual(PhoneRecording(id: call.id, fields: call.fields), call)
        XCTAssertNil(PhoneRecording(id: "a", fields: ["end": .date(t0)]))
        XCTAssertNil(PhoneRecording(id: "a", fields: ["start": .date(t0), "end": .date(t0), "kind": .string("voicemail")])?.kind)
    }

    /// A CAF file whose header says 1 Hz: it reads, and no converter takes it.
    private func audioWithNoConverter() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        try writeTestAudio(url, seconds: 0.1, sampleRate: 8_000)
        var data = try Data(contentsOf: url)
        let desc = try XCTUnwrap(data.range(of: Data("desc".utf8)))
        var one = Double(1).bitPattern.bigEndian
        data.replaceSubrange((desc.upperBound + 8)..<(desc.upperBound + 16), with: Data(bytes: &one, count: 8))
        try data.write(to: url)
        return url
    }

    func testAFileTheConverterCannotTakeFailsTheImportAndLeavesNoCallFolder() throws {
        let paths = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let rec = PhoneRecording(id: "20270115-090000", start: t0, end: t0 + 600, title: nil)
        XCTAssertThrowsError(try PhoneRecording.importAudio(try audioWithNoConverter(), recording: rec, into: paths)) {
            XCTAssertTrue($0 is PhoneRecording.ConversionFailed, "\($0)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.callDirectory(rec.id).appendingPathComponent(CallRecord.fileName).path))
    }
}
