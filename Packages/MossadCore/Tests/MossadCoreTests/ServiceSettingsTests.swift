import XCTest
@testable import MossadCore

/// What the window app builds its services from, pinned before the wiring moved into MossadCore: the same keys, the
/// same defaults, the same provider and model for each setting, the same Keychain key, and the same answer without it.
final class ServiceSettingsTests: XCTestCase {
    private var made: MadeUpSuite!
    private var defaults: UserDefaults { made.defaults }

    override func setUpWithError() throws {
        made = try MadeUpSuite(self)
    }

    /// The keys a factory asked the Keychain for, in order.
    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [APIKey] = []
        func add(_ k: APIKey) { lock.withLock { keys.append(k) } }
        var all: [APIKey] { lock.withLock { keys } }
    }

    private func keychain(_ value: String?, _ asked: Asked = Asked()) -> (APIKey) -> String? {
        { asked.add($0); return value }
    }

    func testAnEmptyProfileReadsTheAppsDefaults() {
        let s = ServiceSettings.read(defaults, fullUserName: "Avery Webb")
        // A name another test registered (the registration domain is the process's) is read, as `@AppStorage` reads it.
        let registered = (UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)["ownerName"] as? String)?
            .trimmingCharacters(in: .whitespaces).nonBlank
        XCTAssertEqual(s.ownerName, registered ?? "Avery Webb"); XCTAssertEqual(s.organization, "")
        XCTAssertEqual(s.transcriptionProvider, .assemblyai); XCTAssertEqual(s.transcriptionModel, "")
        XCTAssertEqual(s.aiProvider, .anthropic); XCTAssertEqual(s.aiModel, "")
        XCTAssertEqual(s.syncWith, .icloud); XCTAssertEqual(s.backup, BackupSettings(choice: "local", region: "us-east-1"))
        XCTAssertTrue(s.voiceFingerprints); XCTAssertFalse(s.coachEnabled); XCTAssertTrue(s.personaEnabled); XCTAssertTrue(s.personaInMCP)
        XCTAssertEqual(s.localServerURL, LocalServer.ollama.absoluteString); XCTAssertNil(s.calendarIDs)
        XCTAssertEqual(s.googleScopes, Set(GoogleScope.allCases)); XCTAssertFalse(s.setupDone)
        XCTAssertEqual(s.serverAddress, ""); XCTAssertEqual(s.serverID, ""); XCTAssertEqual(s.serverRecordingLimit, 0)
        XCTAssertEqual(s.coachSince, 0); XCTAssertEqual(s.personaSince, 0); XCTAssertEqual(s.commitmentsSince, 0)
        XCTAssertEqual(s.ownerEmail, ""); XCTAssertEqual(s.notDuplicates, [])
        XCTAssertTrue(s.personasInMCP == false, "the reads go to other AI apps only with the coach on")
    }

    func testEachKeyIsRead() throws {
        let values: [String: Any] = [
            "ownerName": "Sam Carter", "organization": "  Example Inc. ", "voiceFingerprints": false,
            "transcriptionProvider": "deepgram", "transcriptionModel": "nova-3", "aiProvider": "openai", "aiModel": "gpt-5",
            "localServerURL": "http://127.0.0.1:1234", "syncWith": "server", "serverAddress": "https://notes.example.com",
            "serverID": "srv-1", "serverRecordingLimit": 5_000_000.0, "storage": "r2", "cloudBucketKind": "r2",
            "cloudEndpoint": "https://abc.r2.cloudflarestorage.com", "cloudBucket": "mossad", "cloudRegion": "auto",
            "cloudAccessKeyID": "id", "coachEnabled": true, "coachSince": 100.0, "personaEnabled": false, "personaInMCP": false,
            "personaSince": 200.0, "commitmentsSince": 300.0, "calendarIDs": ["a", "b"], "googleScopes": ["calendar"],
            "ownerEmail": "sam@example.com", "peopleNotDuplicates": "Sam Carter|Sam C\nJo Lee|Joanne Lee", "welcomeDone": true,
        ]
        for (k, v) in values { defaults.set(v, forKey: k) }
        let s = ServiceSettings.read(defaults, fullUserName: "Avery Webb")
        XCTAssertEqual(s.ownerName, "Sam Carter"); XCTAssertEqual(s.organization, "Example Inc.")
        XCTAssertFalse(s.voiceFingerprints)
        XCTAssertEqual(s.transcriptionProvider, .deepgram); XCTAssertEqual(s.transcriptionModel, "nova-3")
        XCTAssertEqual(s.aiProvider, .openai); XCTAssertEqual(s.aiModel, "gpt-5"); XCTAssertEqual(s.localServerURL, "http://127.0.0.1:1234")
        XCTAssertEqual(s.syncWith, .server); XCTAssertEqual(s.serverAddress, "https://notes.example.com"); XCTAssertEqual(s.serverID, "srv-1")
        XCTAssertEqual(s.serverRecordingLimit, 5_000_000)
        XCTAssertEqual(s.backup, BackupSettings(choice: "r2", bucketKind: "r2", endpoint: "https://abc.r2.cloudflarestorage.com", bucket: "mossad",
                                                region: "auto", accessKeyID: "id"))
        XCTAssertTrue(s.coachEnabled); XCTAssertEqual(s.coachSince, 100); XCTAssertFalse(s.personaEnabled); XCTAssertFalse(s.personaInMCP)
        XCTAssertEqual(s.personaSince, 200); XCTAssertEqual(s.commitmentsSince, 300)
        XCTAssertEqual(s.calendarIDs, ["a", "b"]); XCTAssertEqual(s.googleScopes, [.calendar])
        XCTAssertEqual(s.ownerEmail, "sam@example.com"); XCTAssertEqual(s.notDuplicates, ["Sam Carter|Sam C", "Jo Lee|Joanne Lee"])
        XCTAssertTrue(s.setupDone)
    }

    func testTheOlderSwitchOfICloudSyncAndABlankName() {
        defaults.set(false, forKey: "iCloudSync")
        defaults.set("   ", forKey: "ownerName")
        let s = ServiceSettings.read(defaults, fullUserName: "Avery Webb")
        XCTAssertEqual(s.syncWith, .off)
        XCTAssertEqual(s.ownerName, "Avery Webb")
        // A choice made later wins over the older switch.
        defaults.set("icloud", forKey: "syncWith")
        XCTAssertEqual(ServiceSettings.read(defaults, fullUserName: "Avery Webb").syncWith, .icloud)
        // A value this build does not know is the default, as `@AppStorage` reads it.
        defaults.set("carrier pigeon", forKey: "syncWith")
        defaults.set("someone", forKey: "transcriptionProvider")
        XCTAssertEqual(ServiceSettings.read(defaults, fullUserName: "Avery Webb").syncWith, .icloud)
        XCTAssertEqual(ServiceSettings.read(defaults, fullUserName: "Avery Webb").transcriptionProvider, .assemblyai)
    }

    func testSetupIsDoneByTheProgressToo() throws {
        var progress = OnboardingProgress()
        progress.finish()
        defaults.set(try JSONEncoder().encode(progress), forKey: "onboardingProgress")
        XCTAssertTrue(ServiceSettings.read(defaults, fullUserName: "Avery Webb").setupDone)
        XCTAssertEqual(ServiceSettings.read(defaults, fullUserName: "Avery Webb").setupDone,
                       OnboardingProgress.resume(from: defaults.data(forKey: "onboardingProgress")).completed)
    }

    func testWithNoKeyTheTranscriberWaitsForAKey() async {
        let s = ServiceSettings.read(defaults, fullUserName: "Avery Webb")
        let asked = Asked()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("none.m4a")
        do {
            _ = try await s.transcriber(key: keychain(nil, asked), usage: nil).transcribe(file: file, track: .me, progress: { _ in })
            XCTFail("no key")
        } catch {
            XCTAssertTrue(error is MissingAPIKey)
            XCTAssertEqual((error as? MissingAPIKey)?.service, TranscriptionProvider.assemblyai.displayName)
        }
        XCTAssertEqual(asked.all, [.assemblyai])
        XCTAssertNil(s.languageModel(key: { _ in nil }, usage: nil))
        XCTAssertNil(s.summarizer(key: { _ in nil }, usage: nil))
        XCTAssertEqual(s.missingKeys(key: { _ in nil }), [.transcription, .notes])
        XCTAssertEqual(s.missingKeys(key: { _ in "k" }), [])
    }

    func testEachProviderIsTheOneChosenWithItsOwnKey() {
        for provider in TranscriptionProvider.allCases {
            defaults.set(provider.rawValue, forKey: "transcriptionProvider")
            defaults.set("m", forKey: "transcriptionModel")
            let s = ServiceSettings.read(defaults, fullUserName: "Avery Webb")
            let asked = Asked()
            let t = s.transcriber(key: keychain("k", asked), usage: nil)
            XCTAssertEqual(asked.all, provider.key.map { [$0] } ?? [], "\(provider)")
            XCTAssertTrue(type(of: t) == type(of: provider.transcriber(model: "m", apiKey: "k", usage: nil)), "\(provider)")
        }
        for provider in AIProvider.allCases {
            defaults.set(provider.rawValue, forKey: "aiProvider")
            defaults.set("some-model", forKey: "aiModel")
            let s = ServiceSettings.read(defaults, fullUserName: "Avery Webb")
            let asked = Asked()
            let model = s.languageModel(key: keychain("k", asked), usage: nil)
            XCTAssertEqual(asked.all, provider.key.map { [$0] } ?? [], "\(provider)")
            let expected = provider.model("some-model", apiKey: "k", usage: nil, serverURL: LocalServer.ollama)
            XCTAssertEqual(model.map { String(describing: type(of: $0)) }, String(describing: type(of: expected)), "\(provider)")
        }
    }

    func testAModelNeedsItsKeyAndAName() {
        defaults.set("anthropic", forKey: "aiProvider")
        let s = ServiceSettings.read(defaults, fullUserName: "Avery Webb")
        XCTAssertNotNil(s.languageModel(key: { _ in "k" }, usage: nil), "the provider's default model")
        XCTAssertNil(s.languageModel(key: { _ in nil }, usage: nil))
        XCTAssertNotNil(s.summarizer(key: { _ in "k" }, usage: nil))
        for provider in AIProvider.allCases where !provider.requiresKey {
            defaults.set(provider.rawValue, forKey: "aiProvider")
            defaults.set("", forKey: "aiModel")
            let local = ServiceSettings.read(defaults, fullUserName: "Avery Webb")
            XCTAssertEqual(local.languageModel(key: { _ in nil }, usage: nil) == nil, provider.defaultModel.isEmpty, "\(provider)")
        }
    }

    func testTheConfigurationOfThePipeline() {
        defaults.set("  ", forKey: "ownerName")
        defaults.set(false, forKey: "voiceFingerprints")
        let c = ServiceSettings.read(defaults, fullUserName: "Avery Webb").configuration(key: { _ in "k" }, usage: nil)
        XCTAssertEqual(c.ownerName, "Avery Webb"); XCTAssertFalse(c.voiceFingerprints); XCTAssertNotNil(c.summarizer)
    }

    func testTheServerNeedsAnAddressAndItsSecret() {
        defaults.set("https://notes.example.com", forKey: "serverAddress")
        let s = ServiceSettings.read(defaults, fullUserName: "Avery Webb")
        let asked = Asked()
        XCTAssertEqual(s.serverConnection(key: keychain("secret", asked))?.address.absoluteString, "https://notes.example.com")
        XCTAssertEqual(asked.all, [.serverSecret])
        XCTAssertNil(s.serverConnection(key: { _ in nil }))
        defaults.set("not an address", forKey: "serverAddress")
        XCTAssertNil(ServiceSettings.read(defaults, fullUserName: "Avery Webb").serverConnection(key: { _ in "secret" }))
    }

    func testTheStoresFollowTheSyncChoice() {
        let server = ServerConnection(address: URL(string: "https://notes.example.com")!, secret: "s")
        var s = ServiceSettings.read(defaults, fullUserName: "Avery Webb")
        var stores = s.syncStores(server: nil, hasICloud: true, iCloud: { MemoryStore() })
        XCTAssertEqual(stores.main?.key, "icloud"); XCTAssertNil(stores.mirror); XCTAssertEqual(stores.place, "iCloud"); XCTAssertFalse(stores.serverIsMain)
        stores = s.syncStores(server: server, hasICloud: true, iCloud: { MemoryStore() })
        XCTAssertEqual(stores.main?.key, "icloud"); XCTAssertEqual(stores.mirror?.key, "https://notes.example.com")
        stores = s.syncStores(server: nil, hasICloud: false)
        XCTAssertNil(stores.main); XCTAssertEqual(stores.mainKey, "icloud")
        defaults.set("server", forKey: "syncWith")
        s = ServiceSettings.read(defaults, fullUserName: "Avery Webb")
        stores = s.syncStores(server: server, hasICloud: true, iCloud: { MemoryStore() })
        XCTAssertEqual(stores.main?.key, "server:https://notes.example.com"); XCTAssertTrue(stores.serverIsMain)
        XCTAssertEqual(stores.place, "your server"); XCTAssertNil(stores.mirror)
        stores = s.syncStores(server: nil, hasICloud: true, iCloud: { MemoryStore() })
        XCTAssertNil(stores.main); XCTAssertEqual(stores.mainKey, "server:")
        defaults.set("off", forKey: "syncWith")
        stores = ServiceSettings.read(defaults, fullUserName: "Avery Webb").syncStores(server: server, hasICloud: true, iCloud: { MemoryStore() })
        XCTAssertNil(stores.main); XCTAssertNil(stores.mirror); XCTAssertNil(stores.mainKey)
    }

    func testTheBackupPlacesAndTheTarget() throws {
        let paths = Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("svc-\(UUID().uuidString)"))
        let server = ServerConnection(address: URL(string: "https://notes.example.com")!, secret: "s")
        var s = ServiceSettings.read(defaults, fullUserName: "Avery Webb")
        XCTAssertNil(s.archive(key: { _ in nil }, paths: paths, server: nil), "no place is set up")
        XCTAssertNotNil(s.archive(key: { _ in nil }, paths: paths, server: server))
        XCTAssertFalse(s.serverKeepsRecordings(server: server), "no limit and no id")
        defaults.set(5_000_000.0, forKey: "serverRecordingLimit")
        defaults.set("srv-1", forKey: "serverID")
        defaults.set("server", forKey: "storage")
        s = ServiceSettings.read(defaults, fullUserName: "Avery Webb")
        XCTAssertTrue(s.serverKeepsRecordings(server: server))
        XCTAssertFalse(s.serverKeepsRecordings(server: nil))
        defaults.set("r2", forKey: "storage")
        defaults.set("https://abc.r2.cloudflarestorage.com", forKey: "cloudEndpoint")
        defaults.set("mossad", forKey: "cloudBucket")
        defaults.set("id", forKey: "cloudAccessKeyID")
        s = ServiceSettings.read(defaults, fullUserName: "Avery Webb")
        let asked = Asked()
        XCTAssertNotNil(s.archive(key: keychain("secret", asked), paths: paths, server: nil))
        XCTAssertEqual(asked.all, [.cloudSecret])
    }
}
