import CloudKit
import XCTest
@testable import MossadCore

/// Where profiles meet the phone call import.
final class ProfilePhoneCallTests: XCTestCase {
    func testARecordOfAProfileIsInThatProfilesZone() {
        let stored = StoredRecord(name: "phone-20261117-090000", type: "PhoneRecording", fields: ["kind": .string("phoneCall")])
        let work = CloudKitStore.record(stored, in: CloudKitStore.zoneID(named: "Mossad-1a2b3c4d"))
        XCTAssertEqual(work.recordID.zoneID.zoneName, "Mossad-1a2b3c4d")
        XCTAssertEqual(work.recordID.recordName, "phone-20261117-090000")
        XCTAssertEqual(work["kind"] as? String, "phoneCall")
        let first = CloudKitStore.record(stored, in: CloudKitStore.zoneID(named: "Mossad"))
        XCTAssertEqual(first.recordID.zoneID.zoneName, "Mossad")
    }

    func testThePhoneHasNoProfilesAndKeepsTheFirstZone() {
        let phone = AppIdentity(bundleID: "com.dwebber.mossad.phone", arguments: ["Mossad", "--profile", "1a2b3c4d"])
        XCTAssertEqual(phone.profile, .default)
        XCTAssertEqual(phone.cloudZone, "Mossad")
        XCTAssertFalse(AppIdentity.readsRegistry(bundleID: "com.dwebber.mossad.phone", arguments: ["Mossad"], environment: [:]))
    }

    func testAPhoneCallsNoteInAProfilesFolderIsFound() throws {
        var r = CallRecord(id: "20261117-090000", platform: .phoneCall, bundleID: "", start: Date(timeIntervalSince1970: 1_800_000_000),
                           end: Date(timeIntervalSince1970: 1_800_000_600), status: .summarized)
        r.customTitle = "Call with Sam Carter"
        let text = MarkdownWriter.render(r, audioRoot: "~/Mossad Work")
        XCTAssertTrue(text.contains("\naudio: ~/Mossad Work/Audio/20261117-090000\n"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("phone-note-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("note.md")
        try Data(text.utf8).write(to: url)
        XCTAssertTrue(MarkdownWriter.isNote(url, of: "20261117-090000"))
        XCTAssertFalse(MarkdownWriter.isNote(url, of: "20261117-09000"))
    }
}
