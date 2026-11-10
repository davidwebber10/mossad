import CryptoKit
import Foundation

/// A place that keeps recordings. Each record names the place of its recording, so a recording stays readable
/// and deletable where it is after the owner chooses another place for new ones.
public enum ArchiveKind: String, Sendable, CaseIterable {
    /// An S3-compatible bucket: Cloudflare R2 or Amazon S3.
    case bucket
    /// The owner's own Mossad server.
    case server
}

/// One archived file: its key, and the place it is in.
public struct ArchivedObject: Codable, Equatable, Hashable, Sendable {
    public var key: String
    /// An `ArchiveKind`, as text: a place that a newer build adds must not make this record unreadable.
    public var backend: String
    /// Which server, for a file on a server: the id that the server gave itself. A recording on another server
    /// than the connected one is not "in the backup": it cannot be read, and its local copy must stay.
    public var server: String?

    public init(key: String, kind: ArchiveKind, server: String? = nil) {
        self.init(key: key, backend: kind.rawValue, server: server)
    }

    public init(key: String, backend: String, server: String? = nil) {
        self.key = key
        self.backend = backend
        self.server = server
    }

    public var kind: ArchiveKind? { ArchiveKind(rawValue: backend) }
}

/// What a place says about one key. Unknown (no network, a refused key) is not absent.
public enum ArchivePresence: Equatable, Sendable {
    case present(size: Int64, sha256: String?)
    case absent
    case unknown

    public var size: Int64? {
        if case .present(let size, _) = self { return size }
        return nil
    }
}

public enum ArchiveError: Error, Equatable, LocalizedError {
    case http(Int)
    /// The file that came back is not the file that was asked for.
    case notWhole

    public var errorDescription: String? {
        switch self {
        case .http(let code): "The backup answered with HTTP \(code)."
        case .notWhole: "The recording did not arrive whole."
        }
    }
}

/// One place for recordings, behind the calls `CloudArchive` needs. The bookkeeping (which record is archived,
/// with which size) is the same for every place and lives in `CloudArchive`.
public protocol ArchiveBackend: Sendable {
    var kind: ArchiveKind { get }
    /// Which one of its kind this is, when the kind has more than one: the id of a server. Nil for the bucket.
    var id: String? { get }
    /// The largest file this place takes, when it has a limit.
    var maxBytes: Int64? { get }
    func key(for callID: String) -> String
    /// Uploads the file from disk, without reading it into memory. Throws when the place did not take it.
    func put(_ file: URL, key: String, sha256: String) async throws
    func presence(_ key: String) async -> ArchivePresence
    /// True when the object is gone, also when it was not there.
    @discardableResult func remove(_ key: String) async -> Bool
    /// A link the player can stream for a while, without the secret.
    func playbackURL(_ key: String, expires: Int) -> URL?
    /// Checks that the place answers with these keys: uploads and removes a tiny test object.
    func check() async -> Bool
    /// How many recordings the place holds, when it can say. Nil when it cannot, or did not answer.
    func recordingCount() async -> Int?
}

extension ArchiveBackend {
    public var id: String? { nil }
    public func recordingCount() async -> Int? { nil }

    func object(for callID: String) -> ArchivedObject { ArchivedObject(key: key(for: callID), kind: kind, server: id) }

    /// The object in a temporary file. The caller removes the file. When the place sends the MD5 of the object
    /// (an S3 ETag of a one-part upload), the file must have it.
    func download(_ key: String, session: URLSession) async throws -> URL {
        guard let url = playbackURL(key, expires: 900) else { throw ArchiveError.http(404) }
        let (file, response) = try await session.download(from: url)
        let http = response as? HTTPURLResponse
        do {
            guard let status = http?.statusCode, (200..<300).contains(status) else { throw ArchiveError.http(http?.statusCode ?? 0) }
            if let tag = http?.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased(),
               tag.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil, try FileHash.md5(of: file) != tag {
                throw ArchiveError.notWhole
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return file
    }
}

public enum FileHash {
    /// The SHA-256 of a file as lowercase hex, read in pieces, so a long recording is never in memory at once.
    public static func sha256(of file: URL) throws -> String { try digest(SHA256.self, of: file) }

    /// Only to compare with the MD5 that an S3 bucket reports for an object. Not for anything secret.
    static func md5(of file: URL) throws -> String { try digest(Insecure.MD5.self, of: file) }

    private static func digest<H: HashFunction>(_: H.Type, of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = H()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
