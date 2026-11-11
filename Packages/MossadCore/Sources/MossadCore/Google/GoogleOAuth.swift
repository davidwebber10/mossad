import CryptoKit
import Foundation

/// The owner's own Google app: a "Desktop app" OAuth client in their Google Cloud project. Both values live only in
/// the Keychain.
public struct GoogleClient: Equatable, Sendable {
    public var id: String
    public var secret: String

    public init(id: String, secret: String) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A desktop client's ID ends with this.
    public static let idSuffix = ".apps.googleusercontent.com"

    /// Whether the text looks like a client ID, to say so before a sign-in that cannot work.
    public static func looksLikeID(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasSuffix(idSuffix) && t.count > idSuffix.count && !t.contains(where: \.isWhitespace)
    }
}

/// What a sign-in gave: the tokens and what they can read. Saved as one JSON value in the Keychain.
public struct GoogleTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiry: Date
    public var scopes: Set<GoogleScope>
    /// The Google account, from the primary calendar's name; nil until a read gave it.
    public var account: String?

    public init(accessToken: String, refreshToken: String?, expiry: Date, scopes: Set<GoogleScope>, account: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiry = expiry
        self.scopes = scopes
        self.account = account
    }

    /// A token this close to its end is refreshed first, so a request never starts with one that runs out.
    static let margin: TimeInterval = 60

    public func isFresh(at now: Date) -> Bool { expiry.timeIntervalSince(now) > Self.margin }
}

/// The proof key of one sign-in (RFC 7636): only the app that started the sign-in can trade its code.
public struct PKCE: Equatable, Sendable {
    public let verifier: String
    public var challenge: String { Self.challenge(for: verifier) }

    public init(verifier: String) { self.verifier = verifier }

    /// 64 random characters from the allowed set.
    public static func make() -> PKCE {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var rng = SystemRandomNumberGenerator()
        return PKCE(verifier: String((0..<64).map { _ in chars[Int(rng.next() % UInt64(chars.count))] }))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A random value that the browser gives back, so a page that did not start from this sign-in is refused.
    public static func state() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return base64URL(Data(bytes))
    }
}

/// The requests of Google's OAuth for installed apps: the consent page in the browser, the trade of the code, the
/// refresh, and the revoke. Pure: each returns a request and sends nothing.
public enum GoogleOAuth {
    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    /// The consent page. `offline` with `consent` gives a refresh token each time, so a second sign-in with other
    /// scopes still has one.
    public static func authorizationURL(client: GoogleClient, redirect: URL, scopes: Set<GoogleScope>, pkce: PKCE, state: String,
                                        loginHint: String? = nil) -> URL {
        var c = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleScope.allCases.filter(scopes.contains).map(\.url).joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ] + (loginHint.map { [URLQueryItem(name: "login_hint", value: $0)] } ?? [])
        return c.url!
    }

    public static func codeRequest(code: String, client: GoogleClient, redirect: URL, pkce: PKCE) -> URLRequest {
        form(tokenEndpoint, ["code": code, "client_id": client.id, "client_secret": client.secret, "redirect_uri": redirect.absoluteString,
                             "grant_type": "authorization_code", "code_verifier": pkce.verifier])
    }

    public static func refreshRequest(refreshToken: String, client: GoogleClient) -> URLRequest {
        form(tokenEndpoint, ["refresh_token": refreshToken, "client_id": client.id, "client_secret": client.secret, "grant_type": "refresh_token"])
    }

    public static func revokeRequest(token: String) -> URLRequest {
        form(revokeEndpoint, ["token": token])
    }

    /// A form post: the secret and the code go in the body, never in the address.
    static func form(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        r.httpBody = Data(fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
        return r
    }

    /// The token endpoint's answer. A refresh gives no new refresh token: the old one stays.
    public static func tokens(from data: Data, previous: GoogleTokens? = nil, now: Date) throws -> GoogleTokens {
        struct Answer: Decodable {
            var access_token: String
            var expires_in: Double?
            var refresh_token: String?
            var scope: String?
        }
        guard let a = try? JSONDecoder().decode(Answer.self, from: data), !a.access_token.isEmpty else {
            throw GoogleError.unexpectedAnswer
        }
        return GoogleTokens(accessToken: a.access_token, refreshToken: a.refresh_token ?? previous?.refreshToken,
                            expiry: now.addingTimeInterval(a.expires_in ?? 3600),
                            scopes: a.scope.map(GoogleScope.granted) ?? previous?.scopes ?? [], account: previous?.account)
    }
}

/// What the browser brought back to the loopback address.
public enum GoogleCallback: Equatable, Sendable {
    case code(String, state: String)
    /// Google sent an error, such as `access_denied` when the owner pressed Cancel.
    case error(String)

    /// Reads the first line of the browser's request: `GET /?code=…&state=… HTTP/1.1`. Nil for anything else,
    /// such as the browser's request for an icon.
    public static func parse(requestLine: String) -> GoogleCallback? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let c = URLComponents(string: "http://127.0.0.1" + parts[1]) else { return nil }
        let items = c.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value?.nonBlank }
        if let error = value("error") { return .error(error) }
        guard let code = value("code") else { return nil }
        return .code(code, state: value("state") ?? "")
    }
}
