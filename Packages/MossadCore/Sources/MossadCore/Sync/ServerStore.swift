import CryptoKit
import Foundation

/// The owner's own server (the Worker in `server/`): its address and the secret that proves the owner.
public struct ServerConnection: Codable, Equatable, Sendable {
    public var address: URL
    public var secret: String

    public init(address: URL, secret: String) {
        self.address = address
        self.secret = secret
    }

    /// Reads what the owner typed: "notes.example.com", "https://notes.example.com/", and so on.
    public static func address(from text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard var c = URLComponents(string: s), let host = c.host, host.contains(".") || host == "localhost" else { return nil }
        c.path = ""
        c.query = nil
        c.fragment = nil
        // The secret goes in a header on every call, so plain http is only for a server on this machine.
        if c.scheme != "http" || !["localhost", "127.0.0.1"].contains(host) { c.scheme = "https" }
        return c.url
    }

    /// A new owner secret: 32 random bytes, base64url.
    public static func newSecret() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64URL
    }

    func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
        var c = URLComponents(url: address.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 60
        return r
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public enum ServerError: Error, LocalizedError, Equatable {
    case notMossad
    case wrongSecret
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .notMossad: "That address does not answer like a Mossad server."
        case .wrongSecret: "The server does not accept this secret."
        case .http(let code, let message): message.isEmpty ? "The server answered with HTTP \(code)." : message
        }
    }
}

/// Calls to the owner API. Every call sends the secret.
public struct ServerClient: Sendable {
    public let connection: ServerConnection
    let session: URLSession

    public init(_ connection: ServerConnection, session: URLSession = .shared) {
        self.connection = connection
        self.session = session
    }

    /// What a Mossad server says about itself.
    public struct Hello: Equatable, Sendable {
        public var authorized: Bool
        /// Where AI apps connect, such as https://mcp.example.com/mossad.
        public var mcp: URL?
        /// Whether share pages can have an AI chat (the server has an Anthropic key).
        public var chat: Bool
        /// The largest recording the server keeps as a backup, in bytes. Nil on a server from before it kept any.
        public var recordingLimit: Int64?
    }

    /// Whether the address is a Mossad server, and whether it takes the secret. The first call goes without the
    /// secret, so an address that is not a Mossad server (a typing mistake) never receives it.
    public func hello() async throws -> Hello {
        var open = connection.request("api/hello")
        open.setValue(nil, forHTTPHeaderField: "Authorization")
        let first = try await hello(open)
        guard !connection.secret.isEmpty else { return first }
        return try await hello(connection.request("api/hello"))
    }

    private func hello(_ request: URLRequest) async throws -> Hello {
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], body["mossad"] as? Bool == true else { throw ServerError.notMossad }
        let limit = ((body["recordings"] as? [String: Any])?["maxBytes"] as? NSNumber)?.int64Value
        return Hello(authorized: body["authorized"] as? Bool == true, mcp: (body["mcp"] as? String).flatMap(URL.init(string:)), chat: body["chat"] as? Bool == true,
                     recordingLimit: limit.flatMap { $0 > 0 ? $0 : nil })
    }

    @discardableResult
    func send(_ request: URLRequest, body: Data? = nil, file: URL? = nil) async throws -> Data {
        var r = request
        if body != nil, r.value(forHTTPHeaderField: "Content-Type") == nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response): (Data, URLResponse)
        if let file { (data, response) = try await session.upload(for: r, fromFile: file) }
        else if let body { (data, response) = try await session.upload(for: r, from: body) }
        else { (data, response) = try await session.data(for: r) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 401 { throw ServerError.wrongSecret }
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? ""
            throw ServerError.http(code, message)
        }
        return data
    }

    /// The owner's name and time zone, for the MCP's answers and dates.
    public func putConfig(owner: String, timeZone: String = TimeZone.current.identifier) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["owner": owner, "timeZone": timeZone])
        try await send(connection.request("api/config", method: "PUT"), body: body)
    }
}

/// Sync through the owner's server: records in D1, assets in R2, changes in order by a sequence number.
public struct ServerStore: RecordStore {
    public let client: ServerClient

    public init(_ connection: ServerConnection, session: URLSession = .shared) {
        client = ServerClient(connection, session: session)
    }

    /// One state file per server address: another server's change numbers and upload marks mean nothing here.
    public var stateFileName: String {
        let address = client.connection.address.absoluteString.lowercased()
        let hash = SHA256.hash(data: Data(address.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "state-server-\(hash).json"
    }
    public var wantsMeetingView: Bool { true }

    public func prepare() async throws {
        guard try await client.hello().authorized else { throw ServerError.wrongSecret }
    }

    public func save(_ records: [StoredRecord]) async throws -> Set<String> {
        var saved = Set<String>()
        for r in records {
            do {
                for (key, url) in r.files.sorted(by: { $0.key < $1.key }) {
                    var request = client.connection.request("api/assets/\(r.name)/\(key)", method: "PUT")
                    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                    try await client.send(request, file: url)
                }
                let body = try JSONSerialization.data(withJSONObject: ["type": r.type, "fields": Self.json(r.fields), "assets": r.files.keys.sorted()])
                try await client.send(client.connection.request("api/records/\(r.name)", method: "PUT"), body: body)
                saved.insert(r.name)
            } catch ServerError.wrongSecret {
                throw ServerError.wrongSecret
            } catch {
                Log.error("Server upload of \(r.name) failed: \(error.localizedDescription)")
            }
        }
        return saved
    }

    public func delete(_ names: [String]) async throws -> Set<String> {
        var gone = Set<String>()
        for name in names {
            try await client.send(client.connection.request("api/records/\(name)", method: "DELETE"))
            gone.insert(name)
        }
        return gone
    }

    public func changes(since token: Data?) async throws -> StoreChanges {
        let since = token.flatMap { String(data: $0, encoding: .utf8) } ?? "0"
        let data = try await client.send(client.connection.request("api/changes", query: [URLQueryItem(name: "since", value: since)]))
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any], let list = body["changes"] as? [[String: Any]] else {
            throw ServerError.http(200, "The server sent changes Mossad cannot read.")
        }
        var modified: [ChangedRecord] = []
        var deleted: [(name: String, type: String)] = []
        for c in list {
            guard let name = c["name"] as? String, let type = c["type"] as? String else { continue }
            if c["deleted"] as? Bool == true { deleted.append((name, type)); continue }
            modified.append(ChangedRecord(name: name, type: type, fields: Self.fields(c["fields"] as? [String: Any] ?? [:]),
                                          assetKeys: c["assets"] as? [String] ?? []))
        }
        let next = (body["token"] as? NSNumber).map { Data($0.stringValue.utf8) } ?? token
        return StoreChanges(modified: modified, deleted: deleted, token: next, more: body["more"] as? Bool == true)
    }

    public func data(_ record: ChangedRecord, _ key: String) async throws -> Data? {
        guard record.assetKeys.contains(key) else { return nil }
        return try await client.send(client.connection.request("api/assets/\(record.name)/\(key)"))
    }

    public func discard(_ names: [String]) async {
        _ = try? await delete(names)
    }

    // MARK: Fields as JSON

    static func json(_ fields: [String: StoredValue]) -> [String: Any] {
        fields.mapValues { value -> Any in
            switch value {
            case .string(let s): ["s": s]
            case .date(let d): ["d": d.timeIntervalSince1970]
            case .strings(let list): ["l": list]
            }
        }
    }

    static func fields(_ json: [String: Any]) -> [String: StoredValue] {
        json.compactMapValues { raw -> StoredValue? in
            guard let v = raw as? [String: Any] else { return nil }
            if let s = v["s"] as? String { return .string(s) }
            if let d = v["d"] as? Double { return .date(Date(timeIntervalSince1970: d)) }
            if let l = v["l"] as? [String] { return .strings(l) }
            return nil
        }
    }
}
