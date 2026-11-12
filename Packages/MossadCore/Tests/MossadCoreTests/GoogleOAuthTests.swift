import Foundation
import XCTest
@testable import MossadCore

final class GoogleOAuthTests: XCTestCase {
    func testPKCEChallengeIsTheRFCExample() {
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAMadeVerifierHasTheAllowedLengthAndCharacters() {
        let v = PKCE.make().verifier
        XCTAssertEqual(v.count, 64)
        XCTAssertTrue(v.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
        XCTAssertNotEqual(PKCE.make().verifier, v)
    }

    func testTheConsentPageAsksOnlyForTheChosenScopesWithPKCEAndNoSecret() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = GoogleOAuth.authorizationURL(client: testClient, redirect: URL(string: "http://127.0.0.1:50123")!,
                                               scopes: [.docs, .calendar], pkce: pkce, state: "s1")
        let r = URLRequest(url: url)
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(r.query("client_id"), testClient.id)
        XCTAssertEqual(r.query("redirect_uri"), "http://127.0.0.1:50123")
        XCTAssertEqual(r.query("scope"), "https://www.googleapis.com/auth/calendar.events.readonly https://www.googleapis.com/auth/documents.readonly")
        XCTAssertEqual(r.query("code_challenge"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(r.query("code_challenge_method"), "S256")
        XCTAssertEqual(r.query("access_type"), "offline")
        XCTAssertEqual(r.query("state"), "s1")
        XCTAssertFalse(url.absoluteString.contains(testClient.secret))
        XCTAssertFalse(url.absoluteString.contains("gmail"))
        XCTAssertFalse(url.absoluteString.contains("drive"))
    }

    func testTheCodeTradeIsAFormPostWithTheVerifier() {
        let pkce = PKCE(verifier: "v-123")
        let r = GoogleOAuth.codeRequest(code: "4/abc", client: testClient, redirect: URL(string: "http://127.0.0.1:5")!, pkce: pkce)
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(r.form["code"], "4/abc")
        XCTAssertEqual(r.form["code_verifier"], "v-123")
        XCTAssertEqual(r.form["grant_type"], "authorization_code")
        XCTAssertEqual(r.form["client_secret"], testClient.secret)
        XCTAssertNil(r.url?.query)
    }

    func testTokensReadTheScopesAndARefreshKeepsTheRefreshToken() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let first = try GoogleOAuth.tokens(from: StubTransport.json([
            "access_token": "a1", "expires_in": 3599, "refresh_token": "r1",
            "scope": "https://www.googleapis.com/auth/calendar.events.readonly https://www.googleapis.com/auth/contacts.readonly",
            "token_type": "Bearer",
        ]), now: now)
        XCTAssertEqual(first.scopes, [.calendar, .contacts])
        XCTAssertEqual(first.expiry, now.addingTimeInterval(3599))
        var withAccount = first
        withAccount.account = "owner@example.com"
        let second = try GoogleOAuth.tokens(from: StubTransport.json(["access_token": "a2", "expires_in": 3599]), previous: withAccount, now: now)
        XCTAssertEqual(second.refreshToken, "r1")
        XCTAssertEqual(second.scopes, [.calendar, .contacts])
        XCTAssertEqual(second.account, "owner@example.com")
        XCTAssertThrowsError(try GoogleOAuth.tokens(from: Data("{}".utf8), now: now))
    }

    func testTheCallbackLine() {
        XCTAssertEqual(GoogleCallback.parse(requestLine: "GET /?state=xyz&code=4/0Ab-c HTTP/1.1"), .code("4/0Ab-c", state: "xyz"))
        XCTAssertEqual(GoogleCallback.parse(requestLine: "GET /?error=access_denied&state=xyz HTTP/1.1"), .error("access_denied", state: "xyz"))
        XCTAssertNil(GoogleCallback.parse(requestLine: "GET /favicon.ico HTTP/1.1"))
        XCTAssertNil(GoogleCallback.parse(requestLine: "POST /?code=1 HTTP/1.1"))
        XCTAssertNil(GoogleCallback.parse(requestLine: ""))
    }

    func testTheClientIDShape() {
        XCTAssertTrue(GoogleClient.looksLikeID("123-abc.apps.googleusercontent.com"))
        XCTAssertTrue(GoogleClient.looksLikeID("  123-abc.apps.googleusercontent.com\n"))
        XCTAssertFalse(GoogleClient.looksLikeID("GOCSPX-made-up"))
        XCTAssertFalse(GoogleClient.looksLikeID(".apps.googleusercontent.com"))
    }

    // MARK: Errors in plain words

    func testOAuthErrorsAreNamed() {
        func error(_ code: String, _ status: Int = 400) -> GoogleError { .from(status: status, body: StubTransport.json(["error": code])) }
        XCTAssertEqual(error("invalid_client", 401), .invalidClient)
        XCTAssertEqual(error("invalid_grant"), .expired)
        XCTAssertEqual(error("redirect_uri_mismatch"), .redirectMismatch)
        XCTAssertEqual(error("admin_policy_enforced"), .orgBlocked)
        XCTAssertEqual(GoogleError.oauth("access_denied"), .denied)
        XCTAssertNil(GoogleError.oauth("something_new"))
    }

    func testAnAPIThatIsOffNamesTheAPI() {
        let body = StubTransport.json(["error": [
            "code": 403, "status": "PERMISSION_DENIED", "message": "Google Docs API has not been used in project 1 before or it is disabled.",
            "details": [["@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "SERVICE_DISABLED",
                         "metadata": ["service": "docs.googleapis.com"]]],
        ]])
        let e = GoogleError.from(status: 403, body: body)
        XCTAssertEqual(e, .apiDisabled(.docs))
        XCTAssertEqual(e.title, "Google Docs API is off")
        XCTAssertFalse(e.logText.contains("project"), "the log has the code, never Google's words")
        let old = StubTransport.json(["error": ["code": 403, "errors": [["reason": "accessNotConfigured"]]]])
        XCTAssertEqual(GoogleError.from(status: 403, body: old, scope: .calendar), .apiDisabled(.calendar))
    }

    func testOtherAPIErrors() {
        let scope = StubTransport.json(["error": ["code": 403, "status": "PERMISSION_DENIED", "details": [["reason": "ACCESS_TOKEN_SCOPE_INSUFFICIENT"]]]])
        XCTAssertEqual(GoogleError.from(status: 403, body: scope, scope: .directory), .scopeMissing(.directory))
        XCTAssertEqual(GoogleError.from(status: 404, body: Data()), .notFound)
        XCTAssertEqual(GoogleError.from(status: 429, body: Data()), .rateLimited)
        XCTAssertEqual(GoogleError.from(status: 401, body: Data()), .expired)
        XCTAssertEqual(GoogleError.from(status: 503, body: Data()), .http(503))
        XCTAssertTrue(GoogleError.http(503).isTransient)
        XCTAssertFalse(GoogleError.invalidClient.isTransient)
        XCTAssertEqual(GoogleError.from(URLError(.notConnectedToInternet)), .offline)
    }

    func testEveryErrorHasWords() {
        let all: [GoogleError] = [.noClient, .notConnected, .denied, .stateMismatch, .invalidClient, .redirectMismatch, .expired, .orgBlocked,
                                  .apiDisabled(nil), .apiDisabled(.people), .scopeMissing(nil), .scopeMissing(.docs), .forbidden, .notFound,
                                  .rateLimited, .timedOut, .offline, .unexpectedAnswer, .http(500)]
        for e in all {
            XCTAssertFalse(e.title.isEmpty)
            XCTAssertFalse(e.advice.isEmpty)
            XCTAssertFalse(e.advice.contains("—"))
        }
    }
}

final class GoogleSessionTests: XCTestCase {
    private func connected(expiry: Date, scopes: Set<GoogleScope> = [.calendar]) throws -> MemorySecrets {
        let s = MemorySecrets()
        try s.setClient(testClient)
        try s.setTokens(GoogleTokens(accessToken: "old", refreshToken: "r1", expiry: expiry, scopes: scopes))
        return s
    }

    private let now = Date(timeIntervalSince1970: 100_000)
    private let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!

    func testAFreshTokenIsUsedAsItIs() async throws {
        let secrets = try connected(expiry: now.addingTimeInterval(600))
        let t = StubTransport { _ in (200, Data("{}".utf8)) }
        let session = GoogleSession(secrets: secrets, transport: t, now: { [now] in now })
        _ = try await session.get(url, scope: .calendar)
        XCTAssertEqual(t.sent.count, 1)
        XCTAssertEqual(t.sent[0].value(forHTTPHeaderField: "Authorization"), "Bearer old")
    }

    func testAnOldTokenIsRefreshedAndSavedFirst() async throws {
        let secrets = try connected(expiry: now.addingTimeInterval(30))
        let t = StubTransport { r in
            r.url?.host == "oauth2.googleapis.com" ? (200, StubTransport.json(["access_token": "new", "expires_in": 3600])) : (200, Data("{}".utf8))
        }
        let session = GoogleSession(secrets: secrets, transport: t, now: { [now] in now })
        _ = try await session.get(url, scope: .calendar)
        XCTAssertEqual(t.sent.count, 2)
        XCTAssertEqual(t.sent[0].form["grant_type"], "refresh_token")
        XCTAssertEqual(t.sent[0].form["refresh_token"], "r1")
        XCTAssertEqual(t.sent[1].value(forHTTPHeaderField: "Authorization"), "Bearer new")
        XCTAssertEqual(secrets.tokens?.accessToken, "new")
        XCTAssertEqual(secrets.tokens?.refreshToken, "r1")
    }

    func testAnEndedGrantSaysSignInAgainAndStopsAsking() async throws {
        let secrets = try connected(expiry: now.addingTimeInterval(-10))
        let t = StubTransport { _ in (400, StubTransport.json(["error": "invalid_grant"])) }
        let session = GoogleSession(secrets: secrets, transport: t, now: { [now] in now })
        do {
            _ = try await session.get(url, scope: .calendar)
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? GoogleError, .expired) }
        XCTAssertNil(secrets.tokens?.refreshToken)
        XCTAssertFalse(session.isConnected)
        do {
            _ = try await session.get(url, scope: .calendar)
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? GoogleError, .notConnected) }
        XCTAssertEqual(t.sent.count, 1)
    }

    func testAPartThatWasNotGivenIsNotAsked() async throws {
        let secrets = try connected(expiry: now.addingTimeInterval(600), scopes: [.calendar])
        let t = StubTransport { _ in (200, Data()) }
        let session = GoogleSession(secrets: secrets, transport: t, now: { [now] in now })
        do {
            _ = try await session.get(url, scope: .docs)
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? GoogleError, .scopeMissing(.docs)) }
        XCTAssertTrue(t.sent.isEmpty)
        XCTAssertFalse(session.has(.docs))
        XCTAssertTrue(session.has(.calendar))
    }

    func testA401RefreshesOnceAndAsksAgain() async throws {
        let secrets = try connected(expiry: now.addingTimeInterval(600))
        var calls = 0
        let t = StubTransport { r in
            if r.url?.host == "oauth2.googleapis.com" { return (200, StubTransport.json(["access_token": "new", "expires_in": 3600])) }
            calls += 1
            return calls == 1 ? (401, Data()) : (200, Data("{}".utf8))
        }
        let session = GoogleSession(secrets: secrets, transport: t, now: { [now] in now })
        _ = try await session.get(url, scope: .calendar)
        XCTAssertEqual(t.sent.map { $0.url?.host ?? "" }, ["www.googleapis.com", "oauth2.googleapis.com", "www.googleapis.com"])
    }

    func testSignOutRevokesAndForgetsTheTokensButKeepsTheClient() async throws {
        let secrets = try connected(expiry: now.addingTimeInterval(600))
        let t = StubTransport { _ in (200, Data()) }
        let session = GoogleSession(secrets: secrets, transport: t, now: { [now] in now })
        await session.signOut()
        XCTAssertEqual(t.sent.first?.url?.absoluteString, "https://oauth2.googleapis.com/revoke")
        XCTAssertEqual(t.sent.first?.form["token"], "r1")
        XCTAssertNil(secrets.tokens)
        XCTAssertEqual(secrets.client, testClient)
    }

    func testSignOutForgetsTheTokensWhenGoogleCannotBeReached() async throws {
        struct Down: Error {}
        final class Failing: GoogleTransport { func send(_ request: URLRequest) async throws -> (Data, Int) { throw Down() } }
        let secrets = try connected(expiry: now.addingTimeInterval(600))
        await GoogleSession(secrets: secrets, transport: Failing(), now: { [now] in now }).signOut()
        XCTAssertNil(secrets.tokens)
    }

    func testTheCheckReadsOneEventAndNamesEachPartThatFails() async throws {
        let secrets = try connected(expiry: now.addingTimeInterval(600), scopes: [.calendar, .docs, .directory])
        let t = StubTransport { r in
            if r.url?.host == "docs.googleapis.com" { return (404, Data()) }
            if r.url?.host == "www.googleapis.com" {
                return (200, StubTransport.json(["summary": "Owner@Example.com", "items": [
                    ["id": "e1", "summary": "Weekly sync", "start": ["dateTime": "2026-11-10T10:00:00Z"], "end": ["dateTime": "2026-11-10T10:30:00Z"]],
                ]]))
            }
            return (403, StubTransport.json(["error": ["code": 403, "details": [["reason": "SERVICE_DISABLED", "metadata": ["service": "people.googleapis.com"]]]]]))
        }
        let session = GoogleSession(secrets: secrets, transport: t, now: { [now] in now })
        let report = await GoogleCheck.run(session: session, scopes: [.calendar, .docs, .directory], now: now)
        XCTAssertEqual(report.account, "owner@example.com")
        XCTAssertEqual(report.event, "Weekly sync")
        XCTAssertEqual(report.parts[.calendar], .some(nil))
        XCTAssertEqual(report.parts[.docs], .some(nil))
        XCTAssertEqual(report.parts[.directory], .some(.apiDisabled(.people)))
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.firstError, .apiDisabled(.people))
        XCTAssertEqual(secrets.tokens?.account, "owner@example.com")
        XCTAssertEqual(t.sent.first?.query("maxResults"), "1")
    }

    func testTheLoopbackReceiverTakesTheCodeFromThisMacOnly() async throws {
        let receiver = try LoopbackReceiver()
        let address = try await receiver.start()
        XCTAssertEqual(address.host, "127.0.0.1")
        let waiting = Task { try await receiver.callback(timeout: .seconds(10)) }
        var c = URLComponents(url: address, resolvingAgainstBaseURL: false)!
        c.path = "/"
        c.queryItems = [URLQueryItem(name: "code", value: "4/made-up"), URLQueryItem(name: "state", value: "s1")]
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: c.url!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("close this tab"))
        let answer = try await waiting.value
        XCTAssertEqual(answer, .code("4/made-up", state: "s1"))
    }
}

final class GoogleSetupGuideTests: XCTestCase {
    func testEachStepHasADirectConsoleLink() {
        for audience in GoogleSetupGuide.Audience.allCases {
            let steps = GoogleSetupGuide.steps(audience: audience)
            XCTAssertEqual(steps.map(\.number), [1, 2, 3, 4, 5])
            for step in steps {
                XCTAssertFalse(step.links.isEmpty, "step \(step.number)")
                for link in step.links { XCTAssertEqual(link.url.host, "console.cloud.google.com") }
                XCTAssertFalse(step.detail.contains("—"))
            }
        }
    }

    func testTheAPIsAndScopesFollowTheChosenParts() {
        let all = GoogleSetupGuide.steps(audience: .internal)
        XCTAssertEqual(all[1].links.map(\.title), ["Google Calendar API", "Google Docs API", "People API"])
        XCTAssertEqual(all[3].copies.map(\.value), GoogleScope.allCases.map(\.url))
        let calendarOnly = GoogleSetupGuide.steps(audience: .internal, scopes: [.calendar])
        XCTAssertEqual(calendarOnly[1].links.map(\.title), ["Google Calendar API"])
        XCTAssertEqual(calendarOnly[3].copies.map(\.value), ["https://www.googleapis.com/auth/calendar.events.readonly"])
        XCTAssertTrue(all[4].copies.contains { $0.value == "Desktop app" })
    }

    func testInternalAndExternalSayDifferentThings() {
        XCTAssertTrue(GoogleSetupGuide.steps(audience: .internal)[2].detail.contains("Internal"))
        let external = GoogleSetupGuide.steps(audience: .external)[2].detail
        XCTAssertTrue(external.contains("Publish app"))
        XCTAssertTrue(external.contains("In production"))
    }

    func testTheScopesAreReadOnlyAndNoneIsGmailOrDrive() {
        for s in GoogleScope.allCases {
            XCTAssertTrue(s.url.hasSuffix(".readonly"), s.url)
            XCTAssertFalse(s.url.contains("gmail") || s.url.contains("drive"))
        }
    }
}
