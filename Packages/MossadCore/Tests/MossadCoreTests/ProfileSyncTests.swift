import Security
import XCTest
@testable import MossadCore

final class ProfileSyncTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone")
    private let main = AppIdentity.mainBundleID
    private let config = S3Config(endpoint: URL(string: "https://abc.r2.cloudflarestorage.com")!, bucket: "mossad", region: "auto",
                                  accessKeyID: "id", secret: "secret", pathStyle: true)
    private var two: ProfileRegistry.Loaded {
        var r = ProfileRegistry()
        r.profiles.append(Profile(id: "1a2b3c4d", name: "Work", color: .blue, root: "~/Mossad Work"))
        return .init(registry: r, state: .read)
    }

    private var work: AppIdentity { AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "1a2b3c4d"], registry: two) }

    func testTheDefaultProfileKeepsTodaysZoneAccountsAndKeys() {
        let d = AppIdentity(bundleID: main)
        XCTAssertEqual(d.cloudZone, "Mossad"); XCTAssertEqual(d.backupPrefix, "")
        XCTAssertEqual(SharedAIKey.account(profile: "default"), "ai"); XCTAssertEqual(ServerPairing.account(profile: "default"), "server")
        XCTAssertEqual(BucketArchive(config: config, root: "").key(for: "20261116-090000"), "calls/20261116-090000/recording.m4a")
        XCTAssertEqual(BucketArchive(config: config).key(for: "20261116-090000"), "calls/20261116-090000/recording.m4a")
        XCTAssertEqual(CloudKitStore.zoneID(named: d.cloudZone).zoneName, "Mossad")
        // The tests run as no profile: every default is the first profile's, as today.
        XCTAssertEqual(AppIdentity.current.cloudZone, "Mossad")
        XCTAssertEqual(SharedAIKey.account(), "ai"); XCTAssertEqual(ServerPairing.account(), "server")
    }

    func testTwoProfilesNeverShareAZoneOrASyncState() {
        XCTAssertEqual(work.cloudZone, "Mossad-1a2b3c4d")
        XCTAssertEqual(CloudKitStore.zoneID(named: work.cloudZone).zoneName, "Mossad-1a2b3c4d")
        XCTAssertEqual(Paths(root: work.dataRoot(home: home, environment: [:])).sync.path, "/Users/someone/Mossad Work/Sync")
        XCTAssertEqual(Paths(root: AppIdentity(bundleID: main).dataRoot(home: home, environment: [:])).sync.path, "/Users/someone/Mossad/Sync")
    }

    func testTheFirstProfilesZoneCanNeverBeDeleted() async {
        for zone in ["Mossad", "", "Mossad-", "Mossad-default", "mossad-1a2b3c4d", "Mossad-1A2B3C4D", "Mossad-1a2b3c4d5"] {
            XCTAssertFalse(CloudKitStore.mayDelete(zone: zone), zone)
        }
        XCTAssertTrue(CloudKitStore.mayDelete(zone: "Mossad-1a2b3c4d"))
        do {
            try await CloudKitStore.deleteZone(named: "Mossad")
            XCTFail("the first profile's zone must never be deleted")
        } catch {}
    }

    func testAProfileNeverNamesTheDefaultSharedItems() {
        XCTAssertEqual(SharedAIKey.query(profile: "1a2b3c4d")[kSecAttrAccount as String] as? String, "ai.1a2b3c4d")
        XCTAssertEqual(ServerPairing.query(profile: "1a2b3c4d")[kSecAttrAccount as String] as? String, "server.1a2b3c4d")
        XCTAssertEqual(SharedAIKey.query(profile: "default")[kSecAttrAccount as String] as? String, "ai")
        XCTAssertEqual(ServerPairing.query(profile: "default")[kSecAttrAccount as String] as? String, "server")
        XCTAssertEqual(SharedAIKey.query(profile: "1a2b3c4d")[kSecAttrAccessGroup as String] as? String, SharedAIKey.accessGroup)
        XCTAssertEqual(ServerPairing.query(profile: "1a2b3c4d")[kSecAttrService as String] as? String, "com.dwebber.mossad.shared")
    }

    func testAProfilesBackupIsUnderItsOwnPrefix() {
        XCTAssertEqual(work.backupPrefix, "profiles/1a2b3c4d/")
        XCTAssertEqual(BucketArchive(config: config, root: work.backupPrefix).key(for: "20261116-090000"),
                       "profiles/1a2b3c4d/calls/20261116-090000/recording.m4a")
    }

    func testOnlyARealCopyWritesTheSharedItems() {
        XCTAssertTrue(AppIdentity(bundleID: main).writesSharedItems)
        XCTAssertTrue(work.writesSharedItems)
        XCTAssertFalse(AppIdentity(bundleID: main, arguments: ["Mossad", "--ui-preview"], environment: ["MOSSAD_ROOT": "/tmp/demo"]).writesSharedItems)
        XCTAssertFalse(AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "1a2b3c4d"], registry: two, madeUpRegistry: true).writesSharedItems)
    }
}
