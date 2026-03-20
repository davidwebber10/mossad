import XCTest
@testable import MossadShared

final class KeychainManagerTests: XCTestCase {
    let testService = "com.mossad.test"

    override func tearDown() {
        try? KeychainManager.delete(service: testService, account: "apiKey")
    }

    func testSaveAndRetrieveAPIKey() throws {
        try KeychainManager.save(service: testService, account: "apiKey", data: "test-api-key-123")
        let retrieved = try KeychainManager.retrieve(service: testService, account: "apiKey")
        XCTAssertEqual(retrieved, "test-api-key-123")
    }

    func testRetrieveNonExistentKeyReturnsNil() throws {
        let result = try KeychainManager.retrieve(service: testService, account: "nonexistent")
        XCTAssertNil(result)
    }

    func testUpdateExistingKey() throws {
        try KeychainManager.save(service: testService, account: "apiKey", data: "old-key")
        try KeychainManager.save(service: testService, account: "apiKey", data: "new-key")
        let retrieved = try KeychainManager.retrieve(service: testService, account: "apiKey")
        XCTAssertEqual(retrieved, "new-key")
    }
}
