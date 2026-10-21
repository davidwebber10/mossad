import Foundation

/// Keeps finished recordings in an S3-compatible bucket (Cloudflare R2 or Amazon S3), and removes the local
/// copy after a keep period, so years of meetings do not fill the disk. Notes and transcripts stay local.
public final class CloudArchive: @unchecked Sendable {
    private let config: S3Config
    private let paths: Paths
    private let session: URLSession

    public init(config: S3Config, paths: Paths, session: URLSession = .shared) {
        self.config = config
        self.paths = paths
        self.session = session
    }

    static func key(for id: String) -> String { "calls/\(id)/\(Recording.fileName)" }

    /// Uploads every finished recording that is not archived yet, then deletes local copies of archived
    /// recordings older than `keepLocalDays` (nil keeps them). Returns the number uploaded.
    @discardableResult
    public func sync(keepLocalDays: Int?, now: Date = Date()) async -> Int {
        var uploaded = 0
        for var r in ProcessingQueue(paths: paths).allRecords() where r.status == .written {
            let dir = paths.callDirectory(r.id)
            let local = Recording.url(in: dir)
            let hasLocal = FileManager.default.fileExists(atPath: local.path)
            if r.cloudKey == nil, hasLocal {
                let key = Self.key(for: r.id)
                guard await put(local, key: key) else { continue }
                r.cloudKey = key
                do { try r.save(to: dir) } catch { Log.error("Saving \(r.id) failed: \(error)"); continue }
                uploaded += 1
                Log.info("Archived \(r.id) to the cloud")
            }
            if let days = keepLocalDays, r.cloudKey != nil, hasLocal, r.end < now.addingTimeInterval(-Double(days) * 86_400) {
                try? FileManager.default.removeItem(at: local)
                Log.info("Removed the local recording of \(r.id); it stays in the cloud")
            }
        }
        return uploaded
    }

    /// A signed link the player can stream for a few hours, without the secret.
    public func playbackURL(for r: CallRecord) -> URL? {
        r.cloudKey.map { S3Presigner.url(config, method: "GET", key: $0, expires: 6 * 3600) }
    }

    /// Removes the archived recording, for a deleted meeting.
    public func delete(_ r: CallRecord) async {
        guard let key = r.cloudKey else { return }
        var request = URLRequest(url: S3Presigner.url(config, method: "DELETE", key: key))
        request.httpMethod = "DELETE"
        _ = try? await session.data(for: request)
    }

    /// Checks that the bucket answers with these keys: uploads and removes a tiny test object.
    public func check() async -> Bool {
        let key = "mossad-check-\(UUID().uuidString)"
        var request = URLRequest(url: S3Presigner.url(config, method: "PUT", key: key))
        request.httpMethod = "PUT"
        guard let (_, response) = try? await session.upload(for: request, from: Data("ok".utf8)),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return false }
        await delete(CallRecord.withKey(key))
        return true
    }

    private func put(_ file: URL, key: String) async -> Bool {
        var request = URLRequest(url: S3Presigner.url(config, method: "PUT", key: key))
        request.httpMethod = "PUT"
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        do {
            let (_, response) = try await session.upload(for: request, fromFile: file)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return true }
            Log.error("Cloud upload of \(key) failed with HTTP \(status)")
        } catch {
            Log.error("Cloud upload of \(key) failed: \(error.localizedDescription)")
        }
        return false
    }
}

private extension CallRecord {
    static func withKey(_ key: String) -> CallRecord {
        var r = CallRecord(id: key, platform: .meet, bundleID: "", start: Date(), end: Date(), status: .written)
        r.cloudKey = key
        return r
    }
}
