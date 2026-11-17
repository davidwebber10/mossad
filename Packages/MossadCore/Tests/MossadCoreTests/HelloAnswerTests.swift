import XCTest
@testable import MossadCore

/// The first request to the owner's server, read as one of four answers. "Blocked" only on the signs of a gateway.
final class HelloAnswerTests: XCTestCase {
    private let mossad = Data(#"{"mossad": true, "authorized": false}"#.utf8)
    private let blockPage = Data("<!DOCTYPE html><html><head><title>Access denied</title></head><body>Blocked by policy</body></html>".utf8)

    func testTable() {
        typealias Row = (status: Int?, type: String?, body: Data, error: URLError.Code?, final: String?, expected: HelloAnswer)
        let other = Data(#"{"status": "ok"}"#.utf8)
        let xml403 = Data(#"<?xml version="1.0" encoding="UTF-8"?><Error><Code>AccessDenied</Code></Error>"#.utf8)
        let rows: [Row] = [
            (200, "application/json", mossad, nil, nil, .mossad),
            // A gateway's page where the JSON should be.
            (403, "text/html; charset=utf-8", blockPage, nil, nil, .blocked(.page)),
            (200, "text/html", blockPage, nil, nil, .blocked(.page)),
            (403, nil, blockPage, nil, nil, .blocked(.page)),
            (200, "application/octet-stream", Data("  \n<html><body>Stop</body></html>".utf8), nil, nil, .blocked(.page)),
            // A certificate that is not the server's.
            (nil, nil, Data(), .serverCertificateUntrusted, nil, .blocked(.certificate)),
            (nil, nil, Data(), .serverCertificateHasUnknownRoot, nil, .blocked(.certificate)),
            // A redirect to another host.
            (200, "text/html", blockPage, nil, "gateway.example.net", .blocked(.redirect)),
            (200, "application/json", other, nil, "gateway.example.net", .blocked(.redirect)),
            // No answer at all.
            (nil, nil, Data(), .notConnectedToInternet, nil, .noAnswer),
            (nil, nil, Data(), .timedOut, nil, .noAnswer),
            (nil, nil, Data(), .cannotFindHost, nil, .noAnswer),
            (nil, nil, Data(), .dnsLookupFailed, nil, .noAnswer),
            (nil, nil, Data(), .cannotConnectToHost, nil, .noAnswer),
            // Unknown is not blocked: a TLS failure with no sign of another certificate, a clock problem, a redirect
            // to an http block page that App Transport Security stops.
            (nil, nil, Data(), .secureConnectionFailed, nil, .noAnswer),
            (nil, nil, Data(), .serverCertificateHasBadDate, nil, .noAnswer),
            (nil, nil, Data(), .appTransportSecurityRequiresSecureConnection, nil, .noAnswer),
            // A real server that is not Mossad.
            (200, "application/json", other, nil, nil, .notMossad),
            (404, "text/html", Data("<html><body>Not Found</body></html>".utf8), nil, nil, .notMossad),
            (404, "application/json", Data(#"{"error": "not found"}"#.utf8), nil, nil, .notMossad),
            (500, "text/html", blockPage, nil, nil, .notMossad),
            (200, "application/json", Data(#"{"mossad": false}"#.utf8), nil, nil, .notMossad),
            (403, "application/json", Data(#"{"error": "forbidden"}"#.utf8), nil, nil, .notMossad),
            // A storage host that refuses with XML is a server that is not Mossad, not a gateway.
            (403, "application/xml", xml403, nil, nil, .notMossad),
            (403, nil, xml403, nil, nil, .notMossad),
            // Block pages with other codes stay on the safe side.
            (503, "text/html", blockPage, nil, nil, .notMossad),
            (451, "text/html", blockPage, nil, nil, .notMossad),
            (407, "text/html", blockPage, nil, nil, .notMossad),
            // The same host after a redirect is no sign, and neither is its www form.
            (200, "application/json", mossad, nil, "notes.example.com", .mossad),
            (200, "application/json", mossad, nil, "www.notes.example.com", .mossad),
            (200, "application/json", other, nil, "WWW.Notes.Example.com", .notMossad),
        ]
        for (i, r) in rows.enumerated() {
            let answer = HelloAnswer(status: r.status, contentType: r.type, body: r.body, error: r.error,
                                     host: "notes.example.com", finalHost: r.final)
            XCTAssertEqual(answer, r.expected, "row \(i)")
        }
        // From www to the bare host is no redirect either.
        XCTAssertEqual(HelloAnswer(status: 200, contentType: "application/json", body: mossad, error: nil,
                                   host: "www.example.com", finalHost: "example.com"), .mossad)
    }

    /// The scenarios of a wrong address, read by the setup sheet, where the address is not yet known to be Mossad's.
    /// Only a certificate says "blocked" there, or the host of the server that is already connected.
    func testSetupSaysBlockedOnlyOnASureSign() {
        func shown(status: Int?, type: String?, body: Data, error: URLError.Code? = nil, host: String, final: String?,
                   connected: String? = nil) -> String {
            let answer = HelloAnswer(status: status, contentType: type, body: body, error: error, host: host, finalHost: final)
            let thrown: Error
            switch answer {
            case .mossad: return "mossad"
            case .blocked(let sign): thrown = ServerError.networkBlocked(host: host, sign: sign)
            case .noAnswer: thrown = URLError(error ?? .unknown)
            case .notMossad: thrown = ServerError.notMossad
            }
            switch HelloAnswer.setupError(thrown, typedHost: host, connectedHost: connected) {
            case ServerError.networkBlocked: return "blocked"
            case ServerError.notMossad: return "notMossad"
            default: return "noAnswer"
            }
        }
        let parked = Data("<html><body>This domain is for sale</body></html>".utf8)
        let app = Data("<!doctype html><html><body><div id=root></div></body></html>".utf8)
        let challenge = Data("<!DOCTYPE html><html><head><title>Just a moment...</title></head></html>".utf8)
        let xml403 = Data(#"<?xml version="1.0"?><Error><Code>AccessDenied</Code></Error>"#.utf8)
        // The owner typed example.com; it sends them to www.example.com, a web site.
        XCTAssertEqual(shown(status: 200, type: "text/html", body: app, host: "example.com", final: "www.example.com"), "notMossad")
        // A typing mistake that lands on a parked domain on another host.
        XCTAssertEqual(shown(status: 200, type: "text/html", body: parked, host: "notse.example.com", final: "parking.example.net"), "notMossad")
        // A single-page site that answers every path with its page.
        XCTAssertEqual(shown(status: 200, type: "text/html", body: app, host: "example.org", final: nil), "notMossad")
        // A storage host that refuses with XML.
        XCTAssertEqual(shown(status: 403, type: "application/xml", body: xml403, host: "files.example.com", final: nil), "notMossad")
        // The owner's own server behind a bot challenge, during setup.
        XCTAssertEqual(shown(status: 403, type: "text/html", body: challenge, host: "notes.example.com", final: nil), "notMossad")
        // The same page from the server that is already connected: that address worked, so the page is a block.
        XCTAssertEqual(shown(status: 403, type: "text/html", body: challenge, host: "notes.example.com", final: nil,
                             connected: "notes.example.com"), "blocked")
        // A certificate that is not the server's is a block at any address.
        XCTAssertEqual(shown(status: nil, type: nil, body: Data(), error: .serverCertificateUntrusted, host: "notes.example.com", final: nil),
                       "blocked")
        // No answer keeps its own words.
        XCTAssertEqual(shown(status: nil, type: nil, body: Data(), error: .cannotFindHost, host: "notse.example.com", final: nil), "noAnswer")
    }

    func testBlockedWords() {
        let e = FriendlyError(ServerError.networkBlocked(host: "notes.example.com", sign: .page), context: .connectingServer,
                              service: "your server")
        XCTAssertEqual(e.kind, .networkBlocked)
        XCTAssertEqual(e.title, "Your network blocks your server")
        XCTAssertEqual(e.message, "Try another network, or ask the network's administrator to allow notes.example.com.")
        XCTAssertTrue(e.canRetry, "after a change of network, Retry is the next step")
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
            XCTAssertEqual(error as? ServerError, .networkBlocked(host: "notes.example.com", sign: .page))
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
