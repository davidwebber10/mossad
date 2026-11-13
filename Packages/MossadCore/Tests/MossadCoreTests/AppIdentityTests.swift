import XCTest
@testable import MossadCore

final class AppIdentityTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone")

    func testTheRealAppKeepsItsFolderAndKeychain() {
        let id = AppIdentity(bundleID: "com.dwebber.mossad")
        XCTAssertFalse(id.isRehearsal)
        XCTAssertEqual(id.keychainService, "com.dwebber.mossad")
        XCTAssertEqual(id.dataRoot(home: home, environment: [:]).path, "/Users/someone/Mossad")
    }

    func testRehearsalHasItsOwnFolderAndKeychain() {
        let id = AppIdentity(bundleID: "com.dwebber.mossad.rehearsal")
        XCTAssertTrue(id.isRehearsal)
        XCTAssertEqual(id.keychainService, "com.dwebber.mossad.rehearsal")
        XCTAssertEqual(id.dataRoot(home: home, environment: [:]).path, "/Users/someone/Mossad Rehearsal")
    }

    func testMossadRootWinsForTryingTheAppOnAnotherFolder() {
        let id = AppIdentity(bundleID: "com.dwebber.mossad.rehearsal")
        XCTAssertEqual(id.dataRoot(home: home, environment: ["MOSSAD_ROOT": "/tmp/demo"]).path, "/tmp/demo")
    }

    func testOtherBundlesUseTheRealKeychainService() {
        // The iPhone app and the test runner share the Mac's service name.
        XCTAssertEqual(AppIdentity(bundleID: "com.dwebber.mossad.phone").keychainService, "com.dwebber.mossad")
        XCTAssertEqual(AppIdentity(bundleID: nil).keychainService, "com.dwebber.mossad")
    }

    func testNotificationsPaneNamesTheRunningApp() {
        XCTAssertTrue(PermissionKind.notifications.settingsURL(bundleID: "com.dwebber.mossad.rehearsal").absoluteString
            .hasSuffix("id=com.dwebber.mossad.rehearsal"))
    }
}

final class KeyCheckTests: XCTestCase {
    func testEachProviderIsCheckedWithAFreeReadOnlyRequest() throws {
        let cases: [(KeyCheck.Service, String, String, String)] = [
            (.assemblyai, "https://api.assemblyai.com/v2/transcript?limit=1", "Authorization", "k"),
            (.deepgram, "https://api.deepgram.com/v1/projects", "Authorization", "Token k"),
            (.elevenlabs, "https://api.elevenlabs.io/v1/user", "xi-api-key", "k"),
            (.openai, "https://api.openai.com/v1/models", "Authorization", "Bearer k"),
            (.anthropic, "https://api.anthropic.com/v1/models?limit=1", "x-api-key", "k"),
            (.openrouter, "https://openrouter.ai/api/v1/key", "Authorization", "Bearer k"),
        ]
        for (service, url, header, value) in cases {
            let r = KeyCheck.request(service, key: "k")
            XCTAssertEqual(r.url?.absoluteString, url, "\(service)")
            XCTAssertEqual(r.httpMethod, "GET")
            XCTAssertEqual(r.value(forHTTPHeaderField: header), value, "\(service)")
        }
    }

    func testProvidersMapToTheirService() {
        XCTAssertEqual(KeyCheck.Service(TranscriptionProvider.assemblyai), .assemblyai)
        XCTAssertNil(KeyCheck.Service(TranscriptionProvider.local))
        XCTAssertEqual(KeyCheck.Service(AIProvider.openrouter), .openrouter)
    }

    func testARejectedKeyIsAFriendlyError() async {
        StubURLProtocol.handler = { _ in (401, Data(#"{"error":"Invalid API key"}"#.utf8)) }
        do {
            try await KeyCheck.run(.assemblyai, key: "bad", session: StubURLProtocol.session())
            XCTFail("expected an error")
        } catch {
            let friendly = FriendlyError(error, context: .checkingKey)
            XCTAssertEqual(friendly.kind, .unauthorized)
            XCTAssertEqual(friendly.title, "AssemblyAI didn't accept the API key")
            XCTAssertFalse(friendly.message.contains("Settings"), friendly.message)
        }
    }

    func testAnAcceptedKeyPasses() async throws {
        StubURLProtocol.handler = { _ in (200, Data("{}".utf8)) }
        try await KeyCheck.run(.anthropic, key: "good", session: StubURLProtocol.session())
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }
}

final class AppIdentityBuildTests: XCTestCase {
    func testTheBundleAgreesWithTheBuild() {
        XCTAssertNil(AppIdentity(bundleID: AppIdentity.mainBundleID).mismatch(rehearsalBuild: false))
        XCTAssertNil(AppIdentity(bundleID: AppIdentity.rehearsalBundleID).mismatch(rehearsalBuild: true))
    }

    func testARehearsalBuildWithTheRealBundleIDIsCaught() {
        // It would use the real folder and the real keys.
        XCTAssertNotNil(AppIdentity(bundleID: AppIdentity.mainBundleID).mismatch(rehearsalBuild: true))
    }

    func testARealBuildWithRehearsalsBundleIDIsCaught() {
        XCTAssertNotNil(AppIdentity(bundleID: AppIdentity.rehearsalBundleID).mismatch(rehearsalBuild: false))
    }
}

final class AppIdentityPreviewTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone")
    private let main = AppIdentity.mainBundleID

    private func id(_ arguments: [String], _ environment: [String: String] = [:]) -> AppIdentity {
        AppIdentity(bundleID: main, arguments: ["Mossad"] + arguments, environment: environment)
    }

    func testAPlainLaunchAndTheLoginItemAreTheRealApp() {
        for launch in [id([]), id(["-psn_0_12345"])] {
            XCTAssertFalse(launch.isPreview)
            XCTAssertNil(launch.defaultsSuite)
            XCTAssertEqual(launch.keychainService, main)
            XCTAssertNil(launch.refusal(home: home, environment: [:]))
        }
    }

    func testOnlyTheUIPreviewArgumentMakesAPreview() {
        let preview = id(["--ui-preview"], ["MOSSAD_ROOT": "/tmp/demo"])
        XCTAssertTrue(preview.isPreview)
        XCTAssertEqual(preview.keychainService, "com.dwebber.mossad.preview")
        XCTAssertNotNil(preview.defaultsSuite)
        XCTAssertNil(preview.refusal(home: home, environment: ["MOSSAD_ROOT": "/tmp/demo"]))
    }

    func testAHandRunOnAnotherFolderKeepsTheRealSettings() {
        let run = id([], ["MOSSAD_ROOT": "/tmp/demo"])
        XCTAssertFalse(run.isPreview)
        XCTAssertNil(run.defaultsSuite)
        XCTAssertEqual(run.keychainService, main)
        XCTAssertEqual(run.dataRoot(home: home, environment: ["MOSSAD_ROOT": "/tmp/demo"]).path, "/tmp/demo")
    }

    func testAPreviewWithoutAMadeUpFolderRefusesToStart() {
        XCTAssertNotNil(id(["--ui-preview"]).refusal(home: home, environment: [:]))
        XCTAssertNotNil(id(["--ui-preview"]).refusal(home: home, environment: ["MOSSAD_ROOT": ""]))
        XCTAssertNotNil(id(["--ui-preview"]).refusal(home: home, environment: ["MOSSAD_ROOT": "/Users/someone/Mossad"]))
        XCTAssertNotNil(id(["--ui-preview"]).refusal(home: home, environment: ["MOSSAD_ROOT": "/Users/someone/Mossad/"]))
        XCTAssertNotNil(id(["--ui-preview"]).refusal(home: home, environment: ["MOSSAD_ROOT": "/Users/someone/./Mossad"]))
    }

    func testACommandNeverTakesThePreviewIdentity() {
        for flag in ["--mcp", "--people-migration", "--persona-fill", "--persona-eval", "--import-keys"] {
            for env in [[:], ["MOSSAD_ROOT": "/tmp/demo"]] {
                XCTAssertFalse(id([flag], env).isPreview, flag)
                XCTAssertFalse(id(["--ui-preview", flag], env).isPreview, flag)
                XCTAssertEqual(id(["--ui-preview", flag], env).keychainService, main, flag)
            }
        }
    }

    func testEachMadeUpFolderHasItsOwnSettings() {
        let a = id(["--ui-preview"], ["MOSSAD_ROOT": "/tmp/a"]).defaultsSuite
        let b = id(["--ui-preview"], ["MOSSAD_ROOT": "/tmp/b"]).defaultsSuite
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, id(["--ui-preview"], ["MOSSAD_ROOT": "/tmp/a"]).defaultsSuite)
    }

    func testARehearsalPreviewNeverReadsRehearsalsKeys() {
        let preview = AppIdentity(bundleID: AppIdentity.rehearsalBundleID, arguments: ["--ui-preview"], environment: ["MOSSAD_ROOT": "/tmp/demo"])
        XCTAssertEqual(preview.keychainService, "com.dwebber.mossad.rehearsal.preview")
        XCTAssertNotNil(preview.refusal(home: home, environment: ["MOSSAD_ROOT": "/Users/someone/Mossad Rehearsal"]))
    }

    func testTheRealIdentityLeavesTheSettingsAlone() {
        XCTAssertNil(id([]).previewSettings())
        XCTAssertNil(id([], ["MOSSAD_ROOT": "/tmp/demo"]).previewSettings())
    }

    func testAPreviewEmptiesOnlyItsOwnSuite() throws {
        let preview = id(["--ui-preview"], ["MOSSAD_ROOT": "/tmp/br-isolate-test"])
        let suite = try XCTUnwrap(preview.defaultsSuite)
        let other = "com.dwebber.mossad.test-untouched"
        UserDefaults(suiteName: suite)?.set("old", forKey: "ownerName")
        UserDefaults(suiteName: other)?.set("kept", forKey: "ownerName")
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            UserDefaults(suiteName: other)?.removePersistentDomain(forName: other)
        }
        let settings = try XCTUnwrap(preview.previewSettings(arguments: [:]))
        XCTAssertEqual(settings.string(forKey: "ownerName"), "Avery Webb")
        XCTAssertNil(settings.persistentDomain(forName: suite)?["ownerName"])
        XCTAssertEqual(UserDefaults(suiteName: other)?.string(forKey: "ownerName"), "kept")
        XCTAssertEqual(try XCTUnwrap(preview.previewSettings(arguments: ["ownerName": "Sam Carter"])).string(forKey: "ownerName"), "Sam Carter")
    }
}
