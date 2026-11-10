import CryptoKit
import Foundation

/// Recordings on the owner's own server, in its file bucket under `recordings/`. Every call carries the owner
/// secret, except a playback link, which carries a signature made from it and names one recording.
public struct ServerArchive: ArchiveBackend {
    let client: ServerClient
    public let maxBytes: Int64?

    /// `maxBytes` is what the server said in its hello: the largest recording it takes.
    public init(_ connection: ServerConnection, maxBytes: Int64?, session: URLSession = .shared) {
        client = ServerClient(connection, session: session)
        self.maxBytes = maxBytes
    }

    public var kind: ArchiveKind { .server }
    public func key(for callID: String) -> String { "recordings/\(callID)/\(Recording.fileName)" }

    /// The call a key belongs to. The server's addresses name the call; the key is where the server keeps the file.
    static func name(of key: String) -> String? {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "recordings", parts[2] == Recording.fileName,
              parts[1].range(of: "^[A-Za-z0-9._-]{1,200}$", options: .regularExpression) != nil else { return nil }
        return parts[1]
    }

    private func request(_ key: String, method: String) -> URLRequest? {
        Self.name(of: key).map { client.connection.request("api/recordings/\($0)", method: method) }
    }

    public func put(_ file: URL, key: String, sha256: String) async throws {
        guard var request = request(key, method: "PUT") else { throw ArchiveError.http(400) }
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(sha256, forHTTPHeaderField: "X-Recording-SHA256")
        // From the file: URLSession streams it and sends its length, which the server needs.
        let data = try await client.send(request, file: file)
        let stored = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["size"] as? NSNumber
        guard let stored, stored.int64Value == CloudArchive.size(file) else { throw ArchiveError.notWhole }
    }

    public func presence(_ key: String) async -> ArchivePresence {
        guard let request = request(key, method: "HEAD") else { return .absent }
        guard let (_, response) = try? await client.session.data(for: request), let http = response as? HTTPURLResponse else { return .unknown }
        if http.statusCode == 404 { return .absent }
        let length = http.value(forHTTPHeaderField: "X-Recording-Size") ?? http.value(forHTTPHeaderField: "Content-Length")
        guard http.statusCode == 200, let size = length.flatMap(Int64.init) else { return .unknown }
        return .present(size: size, sha256: http.value(forHTTPHeaderField: "X-Recording-SHA256")?.lowercased())
    }

    public func remove(_ key: String) async -> Bool {
        guard let request = request(key, method: "DELETE") else { return true }
        guard let (_, response) = try? await client.session.data(for: request), let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        return (200..<300).contains(status) || status == 404
    }

    public func playbackURL(_ key: String, expires: Int) -> URL? {
        guard let name = Self.name(of: key) else { return nil }
        return Self.link(client.connection, name: name, expires: Date().addingTimeInterval(Double(expires)))
    }

    /// A link to one recording that works until `expires`, without the secret in it. The server makes the same
    /// signature from its copy of the secret (`linkSignature` in server/src/recordings.ts).
    static func link(_ connection: ServerConnection, name: String, expires: Date) -> URL? {
        let until = Int(expires.timeIntervalSince1970)
        var c = URLComponents(url: connection.address.appendingPathComponent("api/recordings/\(name)"), resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "expires", value: String(until)),
                         URLQueryItem(name: "signature", value: signature(secret: connection.secret, name: name, expires: until))]
        return c?.url
    }

    static func signature(secret: String, name: String, expires: Int) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("mossad-recording\n\(name)\n\(expires)".utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    public func check() async -> Bool {
        let key = key(for: "mossad-check-\(UUID().uuidString)")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? Data("ok".utf8).write(to: file)) != nil, let hash = try? FileHash.sha256(of: file),
              (try? await put(file, key: key, sha256: hash)) != nil else { return false }
        let found = await presence(key)
        await remove(key)
        return found == .present(size: 2, sha256: hash)
    }
}
