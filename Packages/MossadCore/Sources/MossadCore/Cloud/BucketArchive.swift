import Foundation

/// Recordings in an S3-compatible bucket (Cloudflare R2 or Amazon S3), through signed links.
public struct BucketArchive: ArchiveBackend {
    let config: S3Config
    let session: URLSession

    public init(config: S3Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public var kind: ArchiveKind { .bucket }
    public var maxBytes: Int64? { nil }
    static let prefix = "calls/"
    public func key(for callID: String) -> String { "\(Self.prefix)\(callID)/\(Recording.fileName)" }

    /// The objects under `calls/`, from one list of at most 1000. Enough to tell "none" from "some". Nil when the
    /// bucket did not answer, or the key may not list.
    public func recordingCount() async -> Int? {
        let url = S3Presigner.url(config, method: "GET", key: "", query: [("list-type", "2"), ("prefix", Self.prefix), ("max-keys", "1000")])
        guard let (data, response) = try? await session.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8), text.contains("<ListBucketResult") else { return nil }
        return text.components(separatedBy: "<Key>").count - 1
    }

    public func put(_ file: URL, key: String, sha256: String) async throws {
        var request = URLRequest(url: S3Presigner.url(config, method: "PUT", key: key))
        request.httpMethod = "PUT"
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, fromFile: file)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ArchiveError.http(status) }
    }

    public func presence(_ key: String) async -> ArchivePresence {
        var request = URLRequest(url: S3Presigner.url(config, method: "HEAD", key: key))
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return .unknown }
        if http.statusCode == 404 { return .absent }
        guard http.statusCode == 200, let size = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) else { return .unknown }
        return .present(size: size, sha256: nil)
    }

    public func remove(_ key: String) async -> Bool {
        var request = URLRequest(url: S3Presigner.url(config, method: "DELETE", key: key))
        request.httpMethod = "DELETE"
        guard let (_, response) = try? await session.data(for: request), let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        return (200..<300).contains(status) || status == 404
    }

    public func playbackURL(_ key: String, expires: Int) -> URL? {
        S3Presigner.url(config, method: "GET", key: key, expires: expires)
    }

    public func check() async -> Bool {
        let key = "mossad-check-\(UUID().uuidString)"
        var request = URLRequest(url: S3Presigner.url(config, method: "PUT", key: key))
        request.httpMethod = "PUT"
        guard let (_, response) = try? await session.upload(for: request, from: Data("ok".utf8)),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return false }
        await remove(key)
        return true
    }
}
