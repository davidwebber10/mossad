import Foundation

/// Keeps finished recordings in a backup (the owner's server, or a Cloudflare R2 or Amazon S3 bucket), and
/// removes the local copy after a keep period, so years of meetings do not fill the disk. Notes and transcripts
/// stay local.
///
/// New recordings go to the one place the owner chose (`target`). A recording that is already in another place
/// stays there: each record names its place, and every place that is set up can still be read and deleted from.
public final class CloudArchive: @unchecked Sendable {
    let target: (any ArchiveBackend)?
    let places: [ArchiveKind: any ArchiveBackend]
    let paths: Paths
    let session: URLSession
    /// The pause before the one retry of an upload that failed for a reason that passes.
    let retryPause: Duration

    /// `places` are all the places that are set up; `target` names the one for new recordings, nil for none.
    public init(target: ArchiveKind?, places: [any ArchiveBackend], paths: Paths, session: URLSession = .shared, retryPause: Duration = .seconds(2)) {
        self.places = Dictionary(places.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        self.target = target.flatMap { kind in places.first { $0.kind == kind } }
        self.paths = paths
        self.session = session
        self.retryPause = retryPause
    }

    /// One bucket, for new recordings and old ones.
    public convenience init(config: S3Config, paths: Paths, session: URLSession = .shared, retryPause: Duration = .seconds(2)) {
        self.init(target: .bucket, places: [BucketArchive(config: config, session: session)], paths: paths, session: session, retryPause: retryPause)
    }

    /// Whether new recordings go anywhere.
    public var hasTarget: Bool { target != nil }

    /// What one pass did.
    public struct Report: Equatable, Sendable {
        public var uploaded = 0
        /// Recordings larger than the place takes. They stay on this Mac.
        public var tooLarge: [String] = []
        /// Recordings whose upload failed. The next pass tries them again.
        public var failed: [String] = []
    }

    /// Uploads every finished recording that is not archived yet, then deletes local copies of archived
    /// recordings older than `keepLocalDays` (nil keeps them).
    ///
    /// A local recording counts as archived only when its size is the size that was uploaded: a merge makes a new,
    /// longer recording, and that one must go up before any local audio is removed. The key is saved through the
    /// pipeline, which is the one writer of `call.json`. `holdLeftovers` keeps older copies in place: during a
    /// move, they go only after the whole move is checked.
    @discardableResult
    public func sync(keepLocalDays: Int?, now: Date = Date(), pipeline: Pipeline, holdLeftovers: Bool = false) async -> Report {
        var report = Report()
        for r in ProcessingQueue(paths: paths).allRecords() where r.status == .written {
            let dir = paths.callDirectory(r.id)
            let local = Recording.url(in: dir)
            let size = Self.size(local)
            var archived = false
            var hasLeftovers = r.cloudLeftovers?.isEmpty == false
            if let size {
                let current = r.archived
                archived = current != nil && r.cloudSize == size
                if !archived, let current, r.cloudSize == nil, await place(of: current)?.presence(current.key).size == size {
                    // Uploaded before sizes were kept, and the place has this very file.
                    archived = await pipeline.setArchived(callID: r.id, current, size: size)
                }
                if !archived, let target {
                    if let max = target.maxBytes, size > max {
                        report.tooLarge.append(r.id)
                    } else {
                        let object = ArchivedObject(key: target.key(for: r.id), kind: target.kind)
                        guard await put(local, object, in: target) else {
                            report.failed.append(r.id)
                            continue
                        }
                        // The record may have changed during the upload (a merge, a new summary): only this size is archived.
                        guard Self.size(local) == size, await pipeline.setArchived(callID: r.id, object, size: size) else {
                            // Deleted or merged away during the upload: a meeting that is gone leaves nothing in the backup.
                            if !FileManager.default.fileExists(atPath: dir.path) {
                                await target.remove(object.key)
                                Log.info("Removed the upload of \(r.id), which was deleted during it")
                            }
                            continue
                        }
                        archived = true
                        // A copy in another place held the file as it was before; the record keeps it as a leftover.
                        if let current, current != object { hasLeftovers = true }
                        report.uploaded += 1
                        Log.info("Archived \(r.id) to \(target.kind.place)")
                    }
                }
            }
            if !holdLeftovers, hasLeftovers { await removeLeftovers(of: r.id, pipeline: pipeline) }
            if let days = keepLocalDays, archived, let size, r.end < now.addingTimeInterval(-Double(days) * 86_400), Self.size(local) == size {
                try? FileManager.default.removeItem(at: local)
                Log.info("Removed the local recording of \(r.id); it stays in the backup")
            }
        }
        return report
    }

    static func size(_ file: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value
    }

    func place(of object: ArchivedObject) -> (any ArchiveBackend)? {
        object.kind.flatMap { places[$0] }
    }

    /// A signed link the player can stream for a few hours, without the secret. Nil when the recording is not
    /// archived, or its place is not set up on this Mac any more.
    public func playbackURL(for r: CallRecord) -> URL? {
        r.archived.flatMap { place(of: $0)?.playbackURL($0.key, expires: 6 * 3600) }
    }

    /// Removes the archived recording and any older copies, for a deleted meeting.
    public func delete(_ r: CallRecord) async {
        for object in Set([r.archived].compactMap { $0 } + (r.cloudLeftovers ?? [])) {
            guard let place = place(of: object) else {
                Log.error("The backup copy of \(r.id) stays: its place is not set up on this Mac")
                continue
            }
            if await !place.remove(object.key) { Log.error("The backup copy of \(r.id) could not be removed from \(place.kind.place)") }
        }
    }

    /// Checks that the place for new recordings answers: uploads and removes a tiny test object.
    public func check() async -> Bool {
        await target?.check() ?? false
    }

    /// Checks one place, also when it is not the place for new recordings.
    public func check(_ kind: ArchiveKind) async -> Bool {
        await places[kind]?.check() ?? false
    }

    func put(_ file: URL, _ object: ArchivedObject, in place: any ArchiveBackend) async -> Bool {
        do {
            let hash = try FileHash.sha256(of: file)
            try await TransientRetry.run(pause: retryPause) { try await place.put(file, key: object.key, sha256: hash) }
            return true
        } catch {
            Log.error("Upload of \(object.key) to \(place.kind.place) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Removes the older copies of a record's recording, once the recording as it is now is safe: its archived
    /// copy is there with the right size, or it has no archived copy and is on this Mac. With `asking`, the place
    /// is asked even when the local file says the same. Returns false when a copy had to stay.
    @discardableResult
    func removeLeftovers(of callID: String, pipeline: Pipeline, asking: Bool = false) async -> Bool {
        let dir = paths.callDirectory(callID)
        guard let r = try? CallRecord.load(from: dir), let leftovers = r.cloudLeftovers, !leftovers.isEmpty else { return true }
        let local = Self.size(Recording.url(in: dir))
        let safe: Bool
        if let current = r.archived {
            if !asking, local != nil, local == r.cloudSize {
                safe = true
            } else if let size = r.cloudSize {
                safe = await place(of: current)?.presence(current.key).size == size
            } else {
                safe = false
            }
        } else {
            safe = local != nil
        }
        guard safe else { return false }
        var gone: [ArchivedObject] = []
        for object in leftovers {
            // The same key in the same place is the recording as it is now: a new upload replaced the old bytes.
            if object == r.archived { gone.append(object); continue }
            guard let place = place(of: object), await place.remove(object.key) else { continue }
            gone.append(object)
        }
        await pipeline.dropLeftovers(callID: callID, gone)
        return gone.count == leftovers.count
    }
}

extension ArchiveKind {
    /// The place in a log line.
    var place: String {
        switch self {
        case .bucket: "the bucket"
        case .server: "your server"
        }
    }
}

extension CallRecord {
    /// Where the recording is archived, when it is.
    public var archived: ArchivedObject? {
        guard let key = cloudKey else { return nil }
        if let cloudBackend { return ArchivedObject(key: key, backend: cloudBackend) }
        // A build from before places had names drops the name when it saves a record. A server key says where it is.
        return ArchivedObject(key: key, kind: ServerArchive.name(of: key) != nil ? .server : .bucket)
    }
}
