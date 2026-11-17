import XCTest
@testable import MossadCore

final class MovedRecordTests: XCTestCase {
    private func json(_ r: CallRecord) throws -> [String: Any] {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return try XCTUnwrap(JSONSerialization.jsonObject(with: e.encode(r)) as? [String: Any])
    }

    private func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): (a as AnyObject).isEqual(b)
        default: false
        }
    }

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MovedRecordTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    /// Every stored property of `CallRecord`, by reflection: a field added later, even one that is nil by default and so
    /// absent from the JSON, is in this list and fails the test until it has a rule.
    private var storedFields: Set<String> {
        let blank = CallRecord(id: "x", platform: .zoom, bundleID: "b", start: Date(), end: Date(), status: .written)
        return Set(Mirror(reflecting: blank).children.compactMap { $0.label.map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 } })
    }

    func testEveryFieldOfARecordHasARule() throws {
        XCTAssertEqual(storedFields, Set(MovedRecord.fields.keys), "a field of CallRecord with no rule, or a rule with no field")
        XCTAssertEqual(Set(try json(fullRecord()).keys), Set(MovedRecord.fields.keys), "fullRecord sets every field")
        XCTAssertEqual(MovedRecord.fields.count, 61)
    }

    func testTheFieldsOfAMovedRecord() throws {
        let before = try json(fullRecord())
        let after = try json(MovedRecord.prepared(fullRecord(), to: "1a2b3c4d"))
        let fresh = try json(CallRecord(id: "20261101-100000", platform: .zoom, bundleID: "us.zoom.xos",
                                        start: Date(timeIntervalSince1970: 1_793_520_000), end: Date(timeIntervalSince1970: 1_793_521_800),
                                        status: .written))
        for (key, rule) in MovedRecord.fields {
            switch rule {
            case .kept: XCTAssertTrue(same(after[key], before[key]), "kept: \(key)")
            case .cleared: XCTAssertTrue(same(after[key], fresh[key]), "cleared: \(key)")
            case .changed: XCTAssertFalse(same(after[key], before[key]), "changed: \(key)")
            }
        }
        let counts = Dictionary(grouping: MovedRecord.fields.values, by: { $0 }).mapValues(\.count)
        XCTAssertEqual(counts[.kept], 43)
        XCTAssertEqual(counts[.changed], 5)
        XCTAssertEqual(counts[.cleared], 13)
    }

    func testTheMovedRecordHasNoIDOfTheFirstProfile() throws {
        let r = MovedRecord.prepared(fullRecord(), to: "1a2b3c4d")
        XCTAssertNil(r.speakerPeople)
        XCTAssertEqual(r.invitees?.map(\.personID), [nil, nil])
        XCTAssertEqual(r.invitees?.map(\.name), ["Sam Carter", "Avery Webb"])
        XCTAssertEqual(r.invitees?.map(\.email), ["sam@example.com", "avery@example.com"])
        XCTAssertNil(r.organizer?.personID)
        XCTAssertEqual(r.organizer?.email, "sam@example.com")
        XCTAssertEqual(r.actionItems.map(\.ownerID), [nil])
        XCTAssertEqual(r.actionItems.map(\.owner), ["Sam Carter"])
        XCTAssertNil(r.personHint?.personID)
        XCTAssertEqual(r.personHint?.name, "Sam Carter")
        let text = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        for id in ["p-sam", "p-owner"] { XCTAssertFalse(text.contains(id), id) }
    }

    func testTheMovedRecordNamesNoPlaceOfTheFirstProfile() throws {
        let r = MovedRecord.prepared(fullRecord(), to: "1a2b3c4d")
        XCTAssertNil(r.markdownPath, "an absolute path into the first profile: the target would delete that note")
        XCTAssertNil(r.cloudKey)
        XCTAssertNil(r.cloudSize)
        XCTAssertNil(r.cloudBackend)
        XCTAssertNil(r.cloudServer)
        XCTAssertNil(r.cloudHash)
        XCTAssertNil(r.cloudLeftovers)
        XCTAssertNil(r.gemini)
        XCTAssertNil(r.transcriptionJobs)
        XCTAssertNil(r.nextAttempt)
        XCTAssertNil(r.failureReason)
        XCTAssertEqual(r.attempts, 0)
        XCTAssertTrue(r.mutedAudioPending)
        XCTAssertEqual(r.muteSpans, fullRecord().muteSpans)
        XCTAssertEqual(r.moveTo, "1a2b3c4d")
        let text = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        XCTAssertFalse(text.contains("/Users/"), "no path of the first profile")
        XCTAssertFalse(text.contains("Mossad/Meetings"))
    }

    func testTheMarkIsTheOnlyNewKeyAndOnlyForAMove() throws {
        let plain = CallRecord(id: "20261101-100000", platform: .zoom, bundleID: "us.zoom.xos", start: Date(), end: Date(), status: .written)
        XCTAssertNil(try json(plain)["moveTo"])
        var marked = plain
        marked.moveTo = "1a2b3c4d"
        let paths = temp()
        let dir = paths.callDirectory(plain.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try marked.save(to: dir)
        XCTAssertEqual(try CallRecord.load(from: dir).moveTo, "1a2b3c4d")
    }

    func testTheFilesOfACallFolder() throws {
        XCTAssertEqual(MovedFiles.rule("call.json"), .prepared)
        for name in ["me.caf", "them.caf", "recording.m4a", "frames.json", "frames"] { XCTAssertEqual(MovedFiles.rule(name), .asIs, name) }
        for name in ["call.previous.json", "coach.json", "findings.json", "live.json", "live-points.json", "upload-me.m4a", "upload-them.m4a",
                     "clip-them-A.caf", "3F2504E0-4F89-11D3-9A0C-0305E82C3301.caf", "notes.txt"] {
            XCTAssertEqual(MovedFiles.rule(name), .never, name)
        }
        for name in ["call.quiet.json", "call.merged.json", "merge.json", "premerge-me.caf", "joined-them.caf", "frames.merged.json"] {
            XCTAssertEqual(MovedFiles.rule(name), .inWork, name)
        }
        let paths = temp()
        try writtenCall(in: paths)
        XCTAssertEqual(MovedFiles.list(in: paths.callDirectory("20261101-100000")),
                       ["frames.json", "frames/000012000.heic", "me.caf", "recording.m4a", "them.caf"])
        XCTAssertTrue(MovedFiles.inWork(["call.json", "merge.json"]))
        XCTAssertFalse(MovedFiles.inWork(["call.json", "me.caf"]))
    }

    func testAMovedChatHasNoReceipts() throws {
        let paths = temp()
        try writtenCall(in: paths)
        let chat = try XCTUnwrap(ChatStore(directory: paths.chats).all().first)
        XCTAssertNotNil(chat.messages.last?.actions)
        let moved = MovedRecord.prepared(chat)
        XCTAssertEqual(moved.id, chat.id)
        XCTAssertEqual(moved.title, chat.title)
        XCTAssertEqual(moved.callID, chat.callID)
        XCTAssertEqual(moved.summary, chat.summary)
        XCTAssertEqual(moved.messages.map(\.text), chat.messages.map(\.text))
        XCTAssertEqual(moved.messages.map(\.steps), chat.messages.map(\.steps))
        XCTAssertTrue(moved.messages.allSatisfy { $0.actions == nil })
    }

    func testTheOwnersKeysComeFromTheFirstProfile() {
        var r = fullRecord()
        r.speakerPeople = ["me:A": "p1"]
        XCTAssertEqual(MovedRecord.ownerKeys(r, owner: OwnerIdentity(name: "A. Webb", id: "p1")), ["me:A"], "by the id though the name differs")
        r.speakerPeople = nil
        XCTAssertEqual(MovedRecord.ownerKeys(r, owner: OwnerIdentity(name: "Avery Webb")), ["me:A"])
        r.speakerNames = ["them:A": "Sam Carter"]
        XCTAssertEqual(MovedRecord.ownerKeys(r, owner: OwnerIdentity(name: "Avery Webb")), [])
    }

    func testTheArrivalStatus() {
        XCTAssertEqual(MovedRecord.arrival(status: .recorded, failedStep: nil, namesChanged: true), .recorded)
        XCTAssertEqual(MovedRecord.arrival(status: .failed, failedStep: nil, namesChanged: false), .recorded)
        XCTAssertEqual(MovedRecord.arrival(status: .failed, failedStep: .recorded, namesChanged: false), .recorded)
        XCTAssertEqual(MovedRecord.arrival(status: .failed, failedStep: .transcribed, namesChanged: false), .transcribed)
        XCTAssertEqual(MovedRecord.arrival(status: .failed, failedStep: .identified, namesChanged: false), .identified)
        XCTAssertEqual(MovedRecord.arrival(status: .written, failedStep: nil, namesChanged: true), .identified)
        XCTAssertEqual(MovedRecord.arrival(status: .written, failedStep: nil, namesChanged: false), .summarized)
        XCTAssertEqual(MovedRecord.arrival(status: .failed, failedStep: .summarized, namesChanged: true), .identified)
        XCTAssertEqual(MovedRecord.arrival(status: .failed, failedStep: .summarized, namesChanged: false), .summarized)
    }
}
