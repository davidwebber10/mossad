import XCTest
@testable import MossadCore

final class PhoneProfileContextTests: XCTestCase {
    private let work = "1a2b3c4d"
    private let club = "5e6f7a8b"
    private let documents = URL(fileURLWithPath: "/D")

    private func context(_ id: String) -> PhoneProfileContext { PhoneProfileContext(id: id)! }

    func testTheDefaultContextIsTodaysPhoneByteForByte() {
        let c = PhoneProfileContext.default
        XCTAssertEqual(c.id, "default")
        XCTAssertTrue(c.isDefault)
        XCTAssertEqual(c.root(documents: documents, environment: [:]).path, "/D/Mossad")
        XCTAssertEqual(c.root(documents: documents, environment: ["MOSSAD_ROOT": "/tmp/x"]).path, "/tmp/x")
        XCTAssertEqual(c.root(documents: documents, environment: ["MOSSAD_ROOT": ""]).path, URL(fileURLWithPath: "").path,
                       "as today's Paths.live")
        let phone = AppIdentity(bundleID: "com.dwebber.mossad.phone")
        XCTAssertEqual(c.keychainService, "com.dwebber.mossad")
        XCTAssertEqual(c.keychainService, phone.keychainService)
        XCTAssertNil(c.settingsSuite)
        let s = try! MadeUpSuite(self).defaults
        XCTAssertTrue(c.settings(standard: s, makeSuite: { _ in XCTFail("the first profile makes no suite"); return nil }) === s)
        XCTAssertEqual(c.cloudZone, "Mossad")
        XCTAssertEqual(c.cloudZone, phone.cloudZone)
        XCTAssertEqual(c.aiAccount, "ai")
        XCTAssertEqual(c.serverAccount, "server")
        let recordings = c.paths(documents: documents, environment: [:]).root.appendingPathComponent("Recordings")
        XCTAssertEqual(recordings.appendingPathComponent(Outbox.fileName).path, "/D/Mossad/Recordings/outbox.json")
        XCTAssertEqual(recordings.appendingPathComponent(ImportMemory.fileName).path, "/D/Mossad/Recordings/imported.json")
    }

    func testAnotherProfileHasItsOwnOfEverything() {
        let c = context(work)
        XCTAssertFalse(c.isDefault)
        XCTAssertEqual(c.root(documents: documents, environment: [:]).path, "/D/Mossad Profiles/1a2b3c4d")
        XCTAssertEqual(c.root(documents: documents, environment: ["MOSSAD_ROOT": "/tmp/x"]).path, "/tmp/x Profiles/1a2b3c4d")
        XCTAssertEqual(c.keychainService, "com.dwebber.mossad.profile.1a2b3c4d")
        XCTAssertEqual(c.settingsSuite, "com.dwebber.mossad.profile.1a2b3c4d")
        XCTAssertEqual(c.cloudZone, "Mossad-1a2b3c4d")
        XCTAssertEqual(c.aiAccount, "ai.1a2b3c4d")
        XCTAssertEqual(c.serverAccount, "server.1a2b3c4d")
    }

    func testTwoProfilesShareNoName() {
        let all = [PhoneProfileContext.default, context(work), context(club)]
        let roots = all.map { $0.root(documents: documents, environment: [:]).path }
        for values in [roots, all.map(\.keychainService), all.map(\.cloudZone), all.map(\.aiAccount), all.map(\.serverAccount)] {
            XCTAssertEqual(Set(values).count, 3, "\(values)")
        }
        for a in roots {
            for b in roots where a != b { XCTAssertFalse(a.hasPrefix(b + "/"), "\(a) is inside \(b)") }
        }
    }

    func testAnIDThatIsNotEightHexIsNoContext() {
        for id in ["", "DEFAULT", "1A2B3C4D", "../x", "1a2b3c4", "1a2b3c4d5"] {
            XCTAssertNil(PhoneProfileContext(id: id), id)
        }
        XCTAssertEqual(PhoneProfileContext(id: "default"), .default)
    }

    func testAProfileWhoseSettingsCannotBeMadeNeverGetsTheFirstProfilesSettings() {
        let s = try! MadeUpSuite(self).defaults
        let t = try! MadeUpSuite(self).defaults
        XCTAssertNil(context(work).settings(standard: s, makeSuite: { _ in nil }))
        var asked: String?
        XCTAssertTrue(context(work).settings(standard: s, makeSuite: { asked = $0; return t }) === t)
        XCTAssertEqual(asked, "com.dwebber.mossad.profile.1a2b3c4d")
    }

    func testTheSyncOfAProfile() {
        let rows: [(PhoneProfileContext, String?, SyncChoice?, SyncChoice?)] = [
            (.default, nil, nil, .icloud), (.default, nil, .server, .icloud), (.default, "server", .icloud, .server),
            (.default, "junk", nil, .icloud), (context(work), nil, nil, nil), (context(work), nil, .server, .server),
            (context(work), "icloud", .server, .icloud), (context(work), "junk", .off, .off),
        ]
        for (c, saved, listed, expected) in rows {
            XCTAssertEqual(c.sync(saved: saved, listed: listed), expected, "\(c.id) \(saved ?? "nil") \(String(describing: listed))")
        }
    }

    func testOnlyAProfilesOwnFolderMayBeRemoved() {
        let env: [String: String] = [:]
        let own = context(work).root(documents: documents, environment: env)
        XCTAssertTrue(context(work).mayRemove(own, documents: documents, environment: env))
        XCTAssertFalse(context(work).mayRemove(URL(fileURLWithPath: "/D/Mossad"), documents: documents, environment: env))
        XCTAssertFalse(context(work).mayRemove(URL(fileURLWithPath: "/D/Mossad Profiles"), documents: documents, environment: env))
        XCTAssertFalse(context(work).mayRemove(context(club).root(documents: documents, environment: env), documents: documents, environment: env))
        XCTAssertFalse(PhoneProfileContext.default.mayRemove(URL(fileURLWithPath: "/D/Mossad"), documents: documents, environment: env))
        XCTAssertFalse(PhoneProfileContext.default.mayRemove(own, documents: documents, environment: env))
    }

    func testAProfileReadsASyncWordItDoesNotKnowAsNotKnown() throws {
        let unknown = try JSONDecoder().decode(PhoneProfile.self, from: Data(#"{"id":"1a2b3c4d","name":"Work","color":"blue","sync":"carrier-pigeon","source":"item"}"#.utf8))
        XCTAssertNil(unknown.sync)
        XCTAssertEqual(unknown.syncName, "carrier-pigeon")
        let server = try JSONDecoder().decode(PhoneProfile.self, from: Data(#"{"id":"1a2b3c4d","name":"Work","color":"blue","sync":"server","source":"item"}"#.utf8))
        XCTAssertEqual(server.sync, .server)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(server)) as! [String: Any]
        XCTAssertEqual(json["sync"] as? String, "server", "coded under the key sync")
        XCTAssertEqual(PhoneProfile.default, PhoneProfile(id: "default", name: "Mossad", color: .orange, sync: nil, source: .item))
        XCTAssertTrue(PhoneProfile.default.isDefault)
    }
}
