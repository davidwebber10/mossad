import XCTest
@testable import MossadCore

final class KeychainTests: XCTestCase {
    let keychain = Keychain(service: "com.dwebber.mossad.tests")

    override func tearDown() {
        keychain.delete(.assemblyai)
        keychain.delete(.anthropic)
    }

    func testRoundTrip() throws {
        try keychain.set("secret-1", for: .assemblyai)
        XCTAssertEqual(keychain.get(.assemblyai), "secret-1")
        try keychain.set("secret-2", for: .assemblyai)
        XCTAssertEqual(keychain.get(.assemblyai), "secret-2")
        keychain.delete(.assemblyai)
        XCTAssertNil(keychain.get(.assemblyai))
    }

    func testImportKeysMapsDopplerNames() {
        let stored = importKeys(from: ["ASSEMBLYAI": "aai", "ANTHROPIC_API_KEY_POLYWOOD_ANALYTICS": "ant", "OTHER": "x"], into: keychain)
        XCTAssertEqual(stored, [.assemblyai, .anthropic])
        XCTAssertEqual(keychain.get(.assemblyai), "aai")
        XCTAssertEqual(keychain.get(.anthropic), "ant")
    }

    func testImportKeysWithEmptyEnvironmentStoresNothing() {
        XCTAssertEqual(importKeys(from: [:], into: keychain), [])
        XCTAssertNil(keychain.get(.assemblyai))
    }
}
