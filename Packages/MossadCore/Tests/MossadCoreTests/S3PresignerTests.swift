import XCTest
@testable import MossadCore

final class S3PresignerTests: XCTestCase {
    /// The example from AWS's "Authenticating Requests: Using Query Parameters" (Signature Version 4).
    func testMatchesTheAWSDocumentationExample() throws {
        let config = S3Config(endpoint: URL(string: "https://s3.amazonaws.com")!, bucket: "examplebucket", region: "us-east-1",
                              accessKeyID: "AKIAIOSFODNN7EXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", pathStyle: false)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z"))
        let url = S3Presigner.url(config, method: "GET", key: "test.txt", date: date, expires: 86_400)
        XCTAssertEqual(url.host, "examplebucket.s3.amazonaws.com")
        XCTAssertEqual(url.path, "/test.txt")
        XCTAssertTrue(url.absoluteString.hasSuffix("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"),
                      url.absoluteString)
    }

    func testPathStyleForCloudflareR2() {
        let config = S3Config(endpoint: URL(string: "https://abc123.r2.cloudflarestorage.com")!, bucket: "mossad", region: "auto",
                              accessKeyID: "id", secret: "secret", pathStyle: true)
        let url = S3Presigner.url(config, method: "PUT", key: "calls/20261021-150259/recording.m4a", date: Date(), expires: 600)
        XCTAssertEqual(url.host, "abc123.r2.cloudflarestorage.com")
        XCTAssertEqual(url.path, "/mossad/calls/20261021-150259/recording.m4a")
        XCTAssertTrue(url.query?.contains("X-Amz-Credential=id%2F") == true)
    }
}
