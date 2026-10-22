import XCTest
@testable import MossadCore

final class MailerTests: XCTestCase {
    private func request(_ provider: MailProvider, _ settings: MailSettings = MailSettings(from: "coach@example.com", domain: "mg.example.com",
                                                                                          accessKeyID: "AKID")) throws -> URLRequest {
        let mailer = settings.mailer(provider, secret: "secret")
        if let http = mailer as? HTTPMailer { return try http.request(to: "me@example.com", subject: "S", html: "<p>H</p>", text: "T") }
        return try (mailer as! ResendMailer).request(to: "me@example.com", subject: "S", html: "<p>H</p>", text: "T")
    }

    private func body(_ r: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    func testPostmark() throws {
        let r = try request(.postmark)
        XCTAssertEqual(r.url?.absoluteString, "https://api.postmarkapp.com/email")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Postmark-Server-Token"), "secret")
        XCTAssertEqual(body(r)["To"] as? String, "me@example.com")
        XCTAssertEqual(body(r)["TextBody"] as? String, "T")
    }

    func testSendGridWithOneRecipientAndTheEUHost() throws {
        let r = try request(.sendgrid)
        XCTAssertEqual(r.url?.absoluteString, "https://api.sendgrid.com/v3/mail/send")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let to = ((body(r)["personalizations"] as? [[String: Any]])?.first?["to"] as? [[String: Any]])
        XCTAssertEqual(to?.count, 1)
        XCTAssertEqual(to?.first?["email"] as? String, "me@example.com")
        XCTAssertEqual(try request(.sendgrid, MailSettings(from: "a@b.c", europe: true)).url?.host, "api.eu.sendgrid.com")
    }

    func testMailgunIsFormEncodedWithBasicAuth() throws {
        let r = try request(.mailgun)
        XCTAssertEqual(r.url?.absoluteString, "https://api.mailgun.net/v3/mg.example.com/messages")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Basic \(Data("api:secret".utf8).base64EncodedString())")
        let form = String(decoding: r.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(form.contains("to=me@example.com"), form)
        XCTAssertTrue(form.contains("html=%3Cp%3EH%3C/p%3E"), form)
    }

    func testBrevo() throws {
        let r = try request(.brevo)
        XCTAssertEqual(r.url?.absoluteString, "https://api.brevo.com/v3/smtp/email")
        XCTAssertEqual(r.value(forHTTPHeaderField: "api-key"), "secret")
        XCTAssertEqual((body(r)["to"] as? [[String: Any]])?.map { $0["email"] as? String }, ["me@example.com"])
    }

    func testSESIsSignedForTheRegion() throws {
        let r = try request(.ses)
        XCTAssertEqual(r.url?.absoluteString, "https://email.us-east-1.amazonaws.com/v2/email/outbound-emails")
        XCTAssertEqual(((body(r)["Destination"] as? [String: Any])?["ToAddresses"] as? [String]), ["me@example.com"])
        let auth = try XCTUnwrap(r.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKID/"), auth)
        XCTAssertTrue(auth.contains("/us-east-1/ses/aws4_request"), auth)
        XCTAssertTrue(auth.contains("SignedHeaders=content-type;host;x-amz-date"), auth)
    }

    /// The "get-vanilla" case of the AWS Signature Version 4 test suite.
    func testSigV4MatchesTheAWSTestSuite() {
        var r = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
        r.httpMethod = "GET"
        let date = ISO8601DateFormatter().date(from: "2015-08-30T12:36:00Z")!
        SigV4.sign(&r, service: "service", region: "us-east-1", accessKeyID: "AKIDEXAMPLE",
                   secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", date: date)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"),
                       "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    func testAMailerErrorNamesTheProvider() async {
        StubURLProtocol.handler = { _ in (422, Data(#"{"ErrorCode":400}"#.utf8)) }
        let mailer = MailSettings(from: "a@b.c").mailer(.postmark, secret: "k", session: StubURLProtocol.session())
        do {
            try await mailer.send(to: "me@example.com", subject: "S", html: "H", text: "T")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue("\(error)".contains("Postmark HTTP 422"), "\(error)")
        }
    }
}
