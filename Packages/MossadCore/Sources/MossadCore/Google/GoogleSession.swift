import Foundation

/// Sends one request. The app uses URLSession; a test answers from a table, so no test reaches Google.
public protocol GoogleTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionTransport: GoogleTransport {
    let session: URLSession

    /// No disk cache and no cookies: Google's answers (events, the directory, documents) never stay on disk.
    public static let ephemeral = URLSession(configuration: .ephemeral)

    public init(session: URLSession = URLSessionTransport.ephemeral) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        var request = request
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Where the client and the tokens are kept: the Keychain in the app, a dictionary in a test.
public protocol GoogleSecrets: Sendable {
    func get(_ key: APIKey) -> String?
    func set(_ value: String, for key: APIKey) throws
    func delete(_ key: APIKey)
}

extension Keychain: GoogleSecrets {}

extension GoogleSecrets {
    public var client: GoogleClient? {
        guard let id = get(.googleClientID)?.nonBlank, let secret = get(.googleClientSecret)?.nonBlank else { return nil }
        return GoogleClient(id: id, secret: secret)
    }

    public func setClient(_ client: GoogleClient) throws {
        try set(client.id, for: .googleClientID)
        try set(client.secret, for: .googleClientSecret)
    }

    public var tokens: GoogleTokens? {
        guard let text = get(.googleTokens), let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GoogleTokens.self, from: data)
    }

    public func setTokens(_ tokens: GoogleTokens?) throws {
        guard let tokens else { return delete(.googleTokens) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try set(String(decoding: try encoder.encode(tokens), as: UTF8.self), for: .googleTokens)
    }
}

/// The tokens in memory, read by views and checks without the Keychain. Loaded once; written through.
final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private let secrets: GoogleSecrets
    private var loaded = false
    private var value: GoogleTokens?

    init(_ secrets: GoogleSecrets) { self.secrets = secrets }

    var tokens: GoogleTokens? {
        lock.withLock {
            if !loaded { value = secrets.tokens; loaded = true }
            return value
        }
    }

    func set(_ new: GoogleTokens?) throws {
        try lock.withLock {
            try secrets.setTokens(new)
            value = new
            loaded = true
        }
    }
}

/// The connection to the owner's Google account: a fresh token for each request, refreshed when it runs out, and
/// the sign-out. One for the app. A request for a part the owner did not give, or turned off, fails with
/// `scopeMissing` before it is sent.
public actor GoogleSession {
    private let secrets: GoogleSecrets
    private let box: TokenBox
    private let transport: GoogleTransport
    private let now: @Sendable () -> Date
    /// One refresh at a time: requests that find the token old wait for the same one.
    private var refreshing: Task<GoogleTokens, Error>?
    /// Counts sign-ins and sign-outs: a refresh that started before one never saves its result.
    private var generation = 0
    /// The parts the owner has on now. A part turned off stops at once, before the next sign-in drops it.
    private nonisolated let chosen: Mutexed<Set<GoogleScope>>

    public init(secrets: GoogleSecrets, transport: GoogleTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = Date.init,
                chosen: Set<GoogleScope> = Set(GoogleScope.allCases)) {
        self.secrets = secrets
        self.box = TokenBox(secrets)
        self.transport = transport
        self.now = now
        self.chosen = Mutexed(chosen)
    }

    /// Whether a sign-in is saved. It says nothing about whether it still works.
    public nonisolated var isConnected: Bool { box.tokens?.refreshToken != nil }
    /// The parts the sign-in gave.
    public nonisolated var scopes: Set<GoogleScope> { box.tokens?.scopes ?? [] }
    public nonisolated var account: String? { box.tokens?.account }
    /// Given by the sign-in and on in the Google step.
    public nonisolated func has(_ scope: GoogleScope) -> Bool { isConnected && scopes.contains(scope) && chosen.value.contains(scope) }
    public nonisolated func choose(_ scopes: Set<GoogleScope>) { chosen.set(scopes) }

    /// Saves what a sign-in gave.
    public func signedIn(_ tokens: GoogleTokens) throws {
        generation += 1
        refreshing?.cancel()
        refreshing = nil
        try box.set(tokens)
    }

    public func setAccount(_ account: String) {
        guard var t = box.tokens, t.account != account else { return }
        t.account = account
        try? box.set(t)
    }

    /// Tells Google to end the grant, then forgets the tokens. The tokens go also when Google cannot be reached:
    /// the owner asked to sign out. The client stays, so a new sign-in needs no paste.
    public func signOut() async {
        generation += 1
        refreshing?.cancel()
        refreshing = nil
        let old = box.tokens
        try? box.set(nil)
        if let t = old {
            let token = t.refreshToken ?? t.accessToken
            if (try? await transport.send(GoogleOAuth.revokeRequest(token: token))) == nil { Log.error("Google: the revoke did not reach Google") }
        }
    }

    /// A token that works for a minute at least.
    func accessToken() async throws -> String {
        guard let t = box.tokens else { throw GoogleError.notConnected }
        if t.isFresh(at: now()) { return t.accessToken }
        return try await refresh(t).accessToken
    }

    private func refresh(_ old: GoogleTokens) async throws -> GoogleTokens {
        if let refreshing { return try await refreshing.value }
        guard let refreshToken = old.refreshToken else { throw GoogleError.expired }
        guard let client = secrets.client else { throw GoogleError.noClient }
        let transport = transport, now = now, started = generation
        let task = Task<GoogleTokens, Error> {
            let (data, status) = try await transport.send(GoogleOAuth.refreshRequest(refreshToken: refreshToken, client: client))
            guard status == 200 else { throw GoogleError.from(status: status, body: data) }
            return try GoogleOAuth.tokens(from: data, previous: old, now: now())
        }
        refreshing = task
        defer { if generation == started { refreshing = nil } }
        do {
            let fresh = try await task.value
            // A sign-out or a new sign-in came meanwhile: this result belongs to a grant that is gone.
            guard generation == started else { throw GoogleError.notConnected }
            try box.set(fresh)
            return fresh
        } catch {
            let g = GoogleError.from(error)
            // A grant that Google ended stays ended: the step says to sign in again.
            if generation == started, g == .expired || g == .invalidClient {
                Log.error("Google: the sign-in ended (\(g.logText))")
                var gone = old
                gone.refreshToken = nil
                try? box.set(gone)
            }
            throw g
        }
    }

    /// A GET with the token. A 401 refreshes the token once and asks again.
    public func get(_ url: URL, scope: GoogleScope) async throws -> Data {
        guard isConnected else { throw GoogleError.notConnected }
        guard scopes.contains(scope), chosen.value.contains(scope) else { throw GoogleError.scopeMissing(scope) }
        for attempt in 0..<2 {
            let token = try await accessToken()
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let data: Data, status: Int
            do { (data, status) = try await transport.send(request) } catch { throw GoogleError.from(error) }
            if status == 200 { return data }
            if status == 401, attempt == 0, let t = box.tokens {
                // Google ended the token early: a new one, once.
                var stale = t
                stale.expiry = .distantPast
                _ = try await refresh(stale)
                continue
            }
            throw GoogleError.from(status: status, body: data, scope: scope)
        }
        throw GoogleError.expired
    }

    /// The answer of a GET as it came, for the Check's probe of an API: the status and the body.
    func probe(_ url: URL, scope: GoogleScope) async throws -> (Int, Data) {
        guard isConnected, scopes.contains(scope) else { throw GoogleError.scopeMissing(scope) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        do {
            let (data, status) = try await transport.send(request)
            return (status, data)
        } catch { throw GoogleError.from(error) }
    }
}

/// A value behind a lock, for the few that any thread reads.
final class Mutexed<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func set(_ new: T) { lock.withLock { stored = new } }
}
