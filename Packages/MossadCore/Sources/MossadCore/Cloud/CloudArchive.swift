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
    ///
    /// A local recording counts as archived only when its size is the size that was uploaded: a merge makes a new,
    /// longer recording, and that one must go up before any local audio is removed. The key is saved through the
    /// pipeline, which is the one writer of `call.json`.
    @discardableResult
    public func sync(keepLocalDays: Int?, now: Date = Date(), pipeline: Pipeline) async -> Int {
        var uploaded = 0
        for r in ProcessingQueue(paths: paths).allRecords() where r.status == .written {
            let dir = paths.callDirectory(r.id)
            let local = Recording.url(in: dir)
            guard let size = Self.size(local) else { continue }
            var archived = r.cloudKey != nil && r.cloudSize == size
            if !archived, let key = r.cloudKey, r.cloudSize == nil, await remoteSize(key) == size {
                // Uploaded before sizes were kept, and the bucket has this very file.
                archived = await pipeline.setCloudKey(callID: r.id, key: key, size: size)
            }
            if !archived {
                let key = Self.key(for: r.id)
                guard await put(local, key: key) else { continue }
                // The record may have changed during the upload (a merge, a new summary): only this size is archived.
                guard Self.size(local) == size, await pipeline.setCloudKey(callID: r.id, key: key, size: size) else {
                    // Deleted or merged away during the upload: a meeting that is gone leaves nothing in the bucket.
                    if !FileManager.default.fileExists(atPath: dir.path) {
                        await delete(key: key)
                        Log.info("Removed the upload of \(r.id), which was deleted during it")
                    }
                    continue
                }
                archived = true
                uploaded += 1
                Log.info("Archived \(r.id) to the cloud")
            }
            if let days = keepLocalDays, archived, r.end < now.addingTimeInterval(-Double(days) * 86_400), Self.size(local) == size {
                try? FileManager.default.removeItem(at: local)
                Log.info("Removed the local recording of \(r.id); it stays in the cloud")
            }
        }
        return uploaded
    }

    static func size(_ file: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value
    }

    /// The size of an object in the bucket, or nil when it is not there or the bucket did not answer.
    private func remoteSize(_ key: String) async -> Int64? {
        var request = URLRequest(url: S3Presigner.url(config, method: "HEAD", key: key))
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return nil }
        return http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
    }

    /// A signed link the player can stream for a few hours, without the secret.
    public func playbackURL(for r: CallRecord) -> URL? {
        r.cloudKey.map { S3Presigner.url(config, method: "GET", key: $0, expires: 6 * 3600) }
    }

    /// Removes the archived recording, for a deleted meeting.
    public func delete(_ r: CallRecord) async {
        guard let key = r.cloudKey else { return }
        await delete(key: key)
    }

    private func delete(key: String) async {
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
