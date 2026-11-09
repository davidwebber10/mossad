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
