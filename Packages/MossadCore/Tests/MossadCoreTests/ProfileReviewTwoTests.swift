import CloudKit
import XCTest
@testable import MossadCore

/// The fixes from the second review of profiles.
final class ProfileReviewTwoTests: XCTestCase {
    private let main = AppIdentity.mainBundleID
    private var two: ProfileRegistry.Loaded {
        var r = ProfileRegistry()
        r.profiles.append(Profile(id: "1a2b3c4d", name: "Work", color: .blue, root: "~/Mossad Work"))
        return .init(registry: r, state: .read)
    }

    // MARK: 1. Which locks a copy holds, and when a second copy may offer the restart

    func testWhichLocksACopyHolds() {
        typealias L = LaunchLocks
        let table: [(L.Result?, L.Result?, L.Decision)] = [
            // No registry file: no Mac-wide lock is tried; the folder decides, as on main.
            (nil, .held, .init(secondCopy: false, keepsMacWide: false)),
            (nil, .taken, .init(secondCopy: true, keepsMacWide: false)),
            (nil, .failed, .init(secondCopy: false, keepsMacWide: false)),
            // With profiles: both locks, or a second copy that holds neither.
            (.held, .held, .init(secondCopy: false, keepsMacWide: true)),
            (.held, .taken, .init(secondCopy: true, keepsMacWide: false)),
            (.held, .failed, .init(secondCopy: false, keepsMacWide: true)),
            (.taken, nil, .init(secondCopy: true, keepsMacWide: false)),
            (.failed, .held, .init(secondCopy: false, keepsMacWide: false)),
            (.failed, .taken, .init(secondCopy: true, keepsMacWide: false)),
        ]
        for (macWide, folder, expected) in table {
            XCTAssertEqual(L.decide(macWide: macWide, folder: folder), expected, "\(String(describing: macWide)) \(String(describing: folder))")
        }
        XCTAssertFalse(L.triesFolder(macWide: .taken))
        XCTAssertTrue(L.triesFolder(macWide: .held)); XCTAssertTrue(L.triesFolder(macWide: nil)); XCTAssertTrue(L.triesFolder(macWide: .failed))
    }

    func testASecondCopyOffersTheRestartWhenEveryLockItNeedsIsFree() {
        XCTAssertTrue(LaunchLocks.mayRestart(folderFree: true, macWideFree: nil))
        XCTAssertFalse(LaunchLocks.mayRestart(folderFree: false, macWideFree: nil))
        XCTAssertTrue(LaunchLocks.mayRestart(folderFree: true, macWideFree: true))
        XCTAssertFalse(LaunchLocks.mayRestart(folderFree: true, macWideFree: false))
        XCTAssertFalse(LaunchLocks.mayRestart(folderFree: false, macWideFree: true))
    }

    // MARK: 3. Only a copy that takes profiles changes the registry

    func testOnlyACopyWithProfilesChangesTheRegistry() {
        XCTAssertTrue(AppIdentity(bundleID: main, registry: two).mayChangeRegistry)
        XCTAssertTrue(AppIdentity(bundleID: main).mayChangeRegistry)
        XCTAssertFalse(AppIdentity(bundleID: main, environment: ["MOSSAD_ROOT": "/tmp/demo"], registry: two).mayChangeRegistry)
        XCTAssertFalse(AppIdentity(bundleID: main, arguments: ["--ui-preview"], environment: ["MOSSAD_ROOT": "/tmp/demo"], registry: two).mayChangeRegistry)
        XCTAssertFalse(AppIdentity(bundleID: AppIdentity.rehearsalBundleID, registry: two).mayChangeRegistry)
        XCTAssertFalse(AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "1a2b3c4d"], registry: two, madeUpRegistry: true).mayChangeRegistry)
    }

    // MARK: 4. One server, one hash, however its address is written

    func testOneServerHasOneHash() {
        let plain = ProfileRules.serverHash(URL(string: "https://notes.example.com")!)
        for same in ["https://notes.example.com:443", "https://user:pass@notes.example.com", "https://notes.example.com.",
                     "https://NOTES.example.com", "https://user@NOTES.example.com.:443"] {
            XCTAssertEqual(ProfileRules.serverHash(URL(string: same)!), plain, same)
        }
        XCTAssertEqual(ProfileRules.serverHash(URL(string: "http://localhost:80")!), ProfileRules.serverHash(URL(string: "http://localhost")!))
        XCTAssertNotEqual(ProfileRules.serverHash(URL(string: "https://notes.example.com:8443")!), plain)
        XCTAssertNotEqual(ProfileRules.serverHash(URL(string: "http://notes.example.com:443")!), ProfileRules.serverHash(URL(string: "http://notes.example.com")!))
        XCTAssertNotEqual(ProfileRules.serverHash(URL(string: "https://other.example.com")!), plain)
    }

    // MARK: 5. A zone is deleted only when iCloud says so

    func testAZoneCountsAsDeletedOnlyOnSuccessOrWhenNotThere() {
        XCTAssertEqual(CloudKitStore.zoneDeletion(.success(())), .deleted)
        XCTAssertEqual(CloudKitStore.zoneDeletion(.failure(CKError(.zoneNotFound))), .deleted)
        XCTAssertEqual(CloudKitStore.zoneDeletion(.failure(CKError(.networkFailure))), .tryAgain)
        XCTAssertEqual(CloudKitStore.zoneDeletion(.failure(CKError(.quotaExceeded))), .tryAgain)
        XCTAssertEqual(CloudKitStore.zoneDeletion(.failure(URLError(.notConnectedToInternet))), .tryAgain)
        XCTAssertEqual(CloudKitStore.zoneDeletion(nil), .tryAgain)
    }

    // MARK: 8. A profile left out of the file is named

    func testAProfileLeftOutIsNamed() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("left-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Mossad Work"), withDestinationURL: home)
        let file = home.appendingPathComponent("profiles.json")
        try Data(#"{"version":1,"active":"1a2b3c4d","profiles":[{"id":"default","name":"Mossad","color":"orange","root":"~/Mossad"},{"id":"1a2b3c4d","name":"Work","color":"blue","root":"~/Mossad Work"}]}"#.utf8).write(to: file)
        let read = ProfileRegistry.load(from: file, home: home)
        XCTAssertEqual(read.state, .partial)
        XCTAssertEqual(read.leftOut, ["Work"])
        XCTAssertEqual(read.registry.live.map(\.id), ["default"])
        XCTAssertEqual(ProfileSettingsWords.footer(read), "Mossad left out a profile whose folder it cannot use: Work. It did not change the file.")
        XCTAssertNil(ProfileMenu(read.registry, active: "default", recording: false))
    }

    // MARK: 9. A server that another profile owns, and a switch during a call

    func testTheQuitOfASwitchWaitsForNoCall() {
        XCTAssertEqual(ProfileSwitch.atQuit(recording: false), .quit)
        XCTAssertEqual(ProfileSwitch.atQuit(recording: true), .refused(ProfileSwitch.refusal))
    }

    // MARK: 10. The guards of the iCloud Keychain items

    func testOnlyACopyThatMayWriteTouchesTheSharedItems() throws {
        let madeUp = AppIdentity(bundleID: main, arguments: ["Mossad", "--profile", "1a2b3c4d"], registry: two, madeUpRegistry: true)
        let preview = AppIdentity(bundleID: main, arguments: ["--ui-preview"], environment: ["MOSSAD_ROOT": "/tmp/demo"])
        for identity in [madeUp, preview] {
            try SharedItemsGate.perform(identity) { XCTFail("must not write") }
        }
        var ran = false
        try SharedItemsGate.perform(AppIdentity(bundleID: main)) { ran = true }
        XCTAssertTrue(ran)
        XCTAssertTrue(SharedItemsGate.appMayWrite(iCloud: true, launchDecided: true, inert: false))
        XCTAssertFalse(SharedItemsGate.appMayWrite(iCloud: true, launchDecided: false, inert: false))
        XCTAssertFalse(SharedItemsGate.appMayWrite(iCloud: true, launchDecided: true, inert: true))
        XCTAssertFalse(SharedItemsGate.appMayWrite(iCloud: false, launchDecided: true, inert: false))
    }

    func testABucketListsOnlyTheProfilesOwnRecordings() async throws {
        StubURLProtocol.handler = { _ in (200, Data("<ListBucketResult><Key>a</Key></ListBucketResult>".utf8)) }
        let config = S3Config(endpoint: URL(string: "https://abc.r2.cloudflarestorage.com")!, bucket: "mossad", region: "auto",
                              accessKeyID: "id", secret: "secret", pathStyle: true)
        let archive = BucketArchive(config: config, session: StubURLProtocol.session(), root: "profiles/1a2b3c4d/")
        let count = await archive.recordingCount()
        XCTAssertEqual(count, 1)
        let url = try XCTUnwrap(StubURLProtocol.requests.last?.url)
        let prefix = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "prefix" }?.value
        XCTAssertEqual(prefix, "profiles/1a2b3c4d/calls/")
        let first = BucketArchive(config: config, session: StubURLProtocol.session(), root: "")
        _ = await first.recordingCount()
        let firstURL = try XCTUnwrap(StubURLProtocol.requests.last?.url)
        XCTAssertEqual(URLComponents(url: firstURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "prefix" }?.value, "calls/")
    }
}
