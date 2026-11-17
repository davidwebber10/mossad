import XCTest
@testable import MossadCore

/// The first request to the owner's server, read as one of four answers. "Blocked" only on the signs of a gateway.
final class HelloAnswerTests: XCTestCase {
    private let mossad = Data(#"{"mossad": true, "authorized": false}"#.utf8)
    private let blockPage = Data("<!DOCTYPE html><html><head><title>Access denied</title></head><body>Blocked by policy</body></html>".utf8)

    func testTable() {
        typealias Row = (status: Int?, type: String?, body: Data, error: URLError.Code?, final: String?, expected: HelloAnswer)
        let other = Data(#"{"status": "ok"}"#.utf8)
        let rows: [Row] = [
            (200, "application/json", mossad, nil, nil, .mossad),
            // A gateway's page where the JSON should be.
            (403, "text/html; charset=utf-8", blockPage, nil, nil, .blocked),
            (200, "text/html", blockPage, nil, nil, .blocked),
            (403, nil, blockPage, nil, nil, .blocked),
            (200, "application/octet-stream", Data("  \n<html><body>Stop</body></html>".utf8), nil, nil, .blocked),
            // A certificate that is not the server's.
            (nil, nil, Data(), .serverCertificateUntrusted, nil, .blocked),
            (nil, nil, Data(), .serverCertificateHasUnknownRoot, nil, .blocked),
            // A redirect to another host.
            (200, "text/html", blockPage, nil, "gateway.example.net", .blocked),
            (200, "application/json", other, nil, "gateway.example.net", .blocked),
            // No answer at all.
            (nil, nil, Data(), .notConnectedToInternet, nil, .noAnswer),
            (nil, nil, Data(), .timedOut, nil, .noAnswer),
            (nil, nil, Data(), .cannotFindHost, nil, .noAnswer),
            (nil, nil, Data(), .dnsLookupFailed, nil, .noAnswer),
            (nil, nil, Data(), .cannotConnectToHost, nil, .noAnswer),
            // Unknown is not blocked: a TLS failure with no sign of another certificate, a clock problem.
            (nil, nil, Data(), .secureConnectionFailed, nil, .noAnswer),
            (nil, nil, Data(), .serverCertificateHasBadDate, nil, .noAnswer),
            // A real server that is not Mossad.
            (200, "application/json", other, nil, nil, .notMossad),
            (404, "text/html", Data("<html><body>Not Found</body></html>".utf8), nil, nil, .notMossad),
            (404, "application/json", Data(#"{"error": "not found"}"#.utf8), nil, nil, .notMossad),
            (500, "text/html", blockPage, nil, nil, .notMossad),
            (200, "application/json", Data(#"{"mossad": false}"#.utf8), nil, nil, .notMossad),
            (403, "application/json", Data(#"{"error": "forbidden"}"#.utf8), nil, nil, .notMossad),
            // The same host after a redirect is no sign.
            (200, "application/json", mossad, nil, "notes.example.com", .mossad),
        ]
        for (i, r) in rows.enumerated() {
            let answer = HelloAnswer(status: r.status, contentType: r.type, body: r.body, error: r.error,
                                     host: "notes.example.com", finalHost: r.final)
            XCTAssertEqual(answer, r.expected, "row \(i)")
        }
    }

    func testBlockedWords() {
        let e = FriendlyError(ServerError.networkBlocked(host: "notes.example.com"), context: .connectingServer, service: "your server")
        XCTAssertEqual(e.kind, .networkBlocked)
        XCTAssertEqual(e.title, "Your network blocks your server")
        XCTAssertEqual(e.message, "Try another network, or ask the network's administrator to allow notes.example.com.")
        XCTAssertFalse(e.canRetry)
    }

    /// The hello through a stub: a gateway's page is "blocked", and the secret never goes out.
    func testHelloSaysBlockedForAGatewayPage() async {
        StubURLProtocol.handler = { _ in (403, Data("<html><body>Access denied</body></html>".utf8)) }
        let session = StubURLProtocol.session()
        StubURLProtocol.responseHeaders = { _ in ["Content-Type": "text/html"] }
        let client = ServerClient(ServerConnection(address: URL(string: "https://notes.example.com")!, secret: "owner-secret"), session: session)
        do {
            _ = try await client.hello()
            XCTFail("blocked")
        } catch {
            XCTAssertEqual(error as? ServerError, .networkBlocked(host: "notes.example.com"))
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertNil(StubURLProtocol.requests[0].headers["Authorization"])
    }

    func testHelloStillSaysNotMossadForAnotherServer() async {
        StubURLProtocol.handler = { _ in (404, Data("<html><body>Not Found</body></html>".utf8)) }
        let session = StubURLProtocol.session()
        StubURLProtocol.responseHeaders = { _ in ["Content-Type": "text/html"] }
        let client = ServerClient(ServerConnection(address: URL(string: "https://notes.example.com")!, secret: "owner-secret"), session: session)
        do {
            _ = try await client.hello()
            XCTFail("not Mossad")
        } catch {
            XCTAssertEqual(error as? ServerError, .notMossad)
        }
    }
}
