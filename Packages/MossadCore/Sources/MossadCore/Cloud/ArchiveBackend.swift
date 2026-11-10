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

    public init(key: String, kind: ArchiveKind) {
        self.init(key: key, backend: kind.rawValue)
    }

    public init(key: String, backend: String) {
        self.key = key
        self.backend = backend
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
}

extension ArchiveBackend {
    /// The object in a temporary file. The caller removes the file.
    func download(_ key: String, session: URLSession) async throws -> URL {
        guard let url = playbackURL(key, expires: 900) else { throw ArchiveError.http(404) }
        let (file, response) = try await session.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: file)
            throw ArchiveError.http(status)
        }
        return file
    }
}

public enum FileHash {
    /// The SHA-256 of a file as lowercase hex, read in pieces, so a long recording is never in memory at once.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
