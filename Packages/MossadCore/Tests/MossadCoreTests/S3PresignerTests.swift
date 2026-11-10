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

    /// A list of a prefix. The signature is from an independent SigV4 implementation (Python, hmac and hashlib).
    func testSignsAListOfAPrefix() throws {
        let config = S3Config(endpoint: URL(string: "https://abc123.r2.cloudflarestorage.com")!, bucket: "mossad", region: "auto",
                              accessKeyID: "id", secret: "secret", pathStyle: true)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-10T12:00:00Z"))
        let url = S3Presigner.url(config, method: "GET", key: "", query: [("list-type", "2"), ("prefix", "calls/"), ("max-keys", "1000")], date: date, expires: 900)
        XCTAssertEqual(url.path, "/mossad")
        XCTAssertEqual(url.query, "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=id%2F20261110%2Fauto%2Fs3%2Faws4_request&X-Amz-Date=20261110T120000Z&X-Amz-Expires=900&X-Amz-SignedHeaders=host&list-type=2&max-keys=1000&prefix=calls%2F&X-Amz-Signature=8eddbb13800da486662f233638924fac678ea326a8a2b36539202566be5855db")
        let s3 = S3Config(endpoint: URL(string: "https://s3.eu-west-1.amazonaws.com")!, bucket: "mossad", region: "eu-west-1",
                          accessKeyID: "id", secret: "secret", pathStyle: false)
        let hosted = S3Presigner.url(s3, method: "GET", key: "", query: [("list-type", "2"), ("prefix", "calls/"), ("max-keys", "1000")], date: date, expires: 900)
        XCTAssertEqual(hosted.host, "mossad.s3.eu-west-1.amazonaws.com")
        XCTAssertEqual(hosted.path, "/")
        XCTAssertTrue(hosted.absoluteString.hasSuffix("X-Amz-Signature=4799ca84600382ddc72aa223dc0b24b115debd00d33532839720555585d58179"), hosted.absoluteString)
    }
}
