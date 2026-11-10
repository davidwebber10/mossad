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

        public init() {}
    }

    /// Uploads every finished recording that is not archived yet, then deletes local copies of archived
    /// recordings older than `keepLocalDays` (nil keeps them).
    ///
    /// A local recording counts as archived only when its size is the size that was uploaded, and the place that
    /// its record names is one that is set up here: a merge makes a new, longer recording, and a recording on
    /// another server than the connected one cannot be read. Both go up (again) before any local audio is removed.
    /// The key is saved through the pipeline, which is the one writer of `call.json`. `holdLeftovers` keeps older
    /// copies in place: during a move, they go only after the whole move is checked.
    @discardableResult
    public func sync(keepLocalDays: Int?, now: Date = Date(), pipeline: Pipeline, holdLeftovers: Bool = false) async -> Report {
        var report = Report()
        await retryDeletes()
        for r in ProcessingQueue(paths: paths).allRecords() where r.status == .written {
            let dir = paths.callDirectory(r.id)
            let local = Recording.url(in: dir)
            let size = Self.size(local)
            // The copy that this pass trusts, with its hash when the place checked it.
            var copy: (object: ArchivedObject, hash: String?)?
            var hasLeftovers = r.cloudLeftovers?.isEmpty == false
            if let size {
                let current = r.archived
                let held = current.flatMap { place(of: $0) }
                if let current, held != nil, r.cloudSize == size { copy = (current, r.cloudHash) }
                if copy == nil, let current, let held, r.cloudSize == nil, await held.presence(current.key).size == size,
                   await pipeline.setArchived(callID: r.id, current, size: size) {
                    // Uploaded before sizes were kept, and the place has this very file.
                    copy = (current, nil)
                }
                if copy == nil, let target {
                    if let max = target.maxBytes, size > max {
                        report.tooLarge.append(r.id)
                    } else {
                        let object = target.object(for: r.id)
                        guard let hash = await put(local, object, in: target) else {
                            report.failed.append(r.id)
                            continue
                        }
                        // The record may have changed during the upload (a merge, a new summary): only this size is archived.
                        guard Self.size(local) == size, await pipeline.setArchived(callID: r.id, object, size: size, sha256: hash) else {
                            // Deleted or merged away during the upload: a meeting that is gone leaves nothing in the backup.
                            if !FileManager.default.fileExists(atPath: dir.path) {
                                await target.remove(object.key)
                                Log.info("Removed the upload of \(r.id), which was deleted during it")
                            }
                            continue
                        }
                        copy = (object, hash)
                        // A copy in another place held the file as it was before; the record keeps it as a leftover.
                        if let current, current != object { hasLeftovers = true }
                        report.uploaded += 1
                        Log.info("Archived \(r.id) to \(target.kind.place)")
                    }
                }
            }
            if !holdLeftovers, hasLeftovers { await removeLeftovers(of: r.id, pipeline: pipeline) }
            if let days = keepLocalDays, let copy, let size, r.end < now.addingTimeInterval(-Double(days) * 86_400), Self.size(local) == size {
                // The place is asked once, before the only local copy goes: a mark in a record is not the file.
                switch await confirm(copy.object, size: size, hash: copy.hash) {
                case .there:
                    try? FileManager.default.removeItem(at: local)
                    Log.info("Removed the local recording of \(r.id); it stays in the backup")
                case .notThere:
                    // The mark was false. Without it the recording is sent again in the next pass.
                    await pipeline.clearArchived(callID: r.id, ifCurrent: copy.object)
                    Log.error("The backup does not have the recording of \(r.id) that its record names. The local copy stays, and it is sent again")
                case .unknown:
                    break
                }
            }
        }
        return report
    }

    enum Confirmation { case there, notThere, unknown }

    /// Asks the place whether it has this very file: the size, and the hash when both sides know it.
    func confirm(_ object: ArchivedObject, size: Int64, hash: String?) async -> Confirmation {
        guard let place = place(of: object) else { return .unknown }
        switch await place.presence(object.key) {
        case .present(let remote, let remoteHash):
            return remote == size && (hash == nil || remoteHash == nil || hash == remoteHash) ? .there : .notThere
        case .absent: return .notThere
        case .unknown: return .unknown
        }
    }

    static func size(_ file: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value
    }

    /// The place that holds an object, when it is set up here. A file on a server is held only by the server with
    /// the id that the record names: after a change of server, the files on the old one are not in reach.
    func place(of object: ArchivedObject) -> (any ArchiveBackend)? {
        guard let kind = object.kind, let place = places[kind] else { return nil }
        if kind == .server, place.id == nil || place.id != object.server { return nil }
        return place
    }

    /// Whether a record's backup copy is in a place that is set up on this Mac. Only then may the audio on this
    /// Mac go by the keep rules: a mark for another server, or for a bucket with no settings, is not a backup.
    public func holds(_ r: CallRecord) -> Bool {
        r.archived.map { place(of: $0) != nil } ?? false
    }

    /// A signed link the player can stream for a few hours, without the secret. Nil when the recording is not
    /// archived, or its place is not set up on this Mac any more.
    public func playbackURL(for r: CallRecord) -> URL? {
        r.archived.flatMap { place(of: $0)?.playbackURL($0.key, expires: 6 * 3600) }
    }

    /// Removes the archived recording and any older copies, for a deleted meeting. A copy that cannot be removed
    /// now (no network, or its place is not set up) is remembered, and each later pass tries it again.
    public func delete(_ r: CallRecord) async {
        for object in Set([r.archived].compactMap { $0 } + (r.cloudLeftovers ?? [])) {
            if let place = place(of: object), await place.remove(object.key) { continue }
            Log.error("The backup copy of \(r.id) could not be removed yet. Mossad tries again")
            Self.rememberDelete(object, in: deletesFile)
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

    /// Uploads a file and gives back its SHA-256, or nil when the place did not take it.
    func put(_ file: URL, _ object: ArchivedObject, in place: any ArchiveBackend, sha256 known: String? = nil) async -> String? {
        do {
            let hash = try known ?? FileHash.sha256(of: file)
            try await TransientRetry.run(pause: retryPause) { try await place.put(file, key: object.key, sha256: hash) }
            return hash
        } catch {
            Log.error("Upload of \(object.key) to \(place.kind.place) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Removes the older copies of a record's recording, once the recording as it is now is safe: its archived
    /// copy is in a place that is set up here, with the right size, or it has no archived copy and is on this
    /// Mac. With `asking`, the place is asked even when the local file says the same, and the hash must agree too.
    /// With `requiring`, only a checked copy in that kind of place makes the old ones go (a move). Returns false
    /// when a copy had to stay.
    @discardableResult
    func removeLeftovers(of callID: String, pipeline: Pipeline, asking: Bool = false, requiring kind: ArchiveKind? = nil) async -> Bool {
        let dir = paths.callDirectory(callID)
        guard let r = try? CallRecord.load(from: dir), let leftovers = r.cloudLeftovers, !leftovers.isEmpty else { return true }
        let local = Self.size(Recording.url(in: dir))
        let safe: Bool
        if let current = r.archived {
            if place(of: current) == nil || (kind != nil && current.kind != kind) {
                safe = false
            } else if !asking, local != nil, local == r.cloudSize {
                safe = true
            } else if let size = r.cloudSize {
                safe = await confirm(current, size: size, hash: r.cloudHash) == .there
            } else {
                safe = false
            }
        } else {
            safe = kind == nil && local != nil
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

    // MARK: Deletes that failed

    /// Backup copies of deleted meetings that could not be removed yet.
    var deletesFile: URL { paths.sync.appendingPathComponent("backup-deletes.json") }
    private static let deletesLock = NSLock()

    static func pendingDeletes(in file: URL) -> [ArchivedObject] {
        (try? JSONDecoder().decode([ArchivedObject].self, from: Data(contentsOf: file))) ?? []
    }

    private static func changeDeletes(in file: URL, _ change: (inout [ArchivedObject]) -> Void) {
        deletesLock.withLock {
            var list = pendingDeletes(in: file)
            let before = list
            change(&list)
            guard list != before else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if list.isEmpty { try? FileManager.default.removeItem(at: file) } else { try? JSONEncoder().encode(list).write(to: file, options: .atomic) }
        }
    }

    /// Remembers the backup copies of a deleted meeting when no place is set up to remove them from now.
    public static func rememberDeletes(of r: CallRecord, paths: Paths) {
        let file = paths.sync.appendingPathComponent("backup-deletes.json")
        for object in Set([r.archived].compactMap { $0 } + (r.cloudLeftovers ?? [])) { rememberDelete(object, in: file) }
    }

    static func rememberDelete(_ object: ArchivedObject, in file: URL) {
        changeDeletes(in: file) { if !$0.contains(object) { $0.append(object) } }
    }

    /// Tries the remembered deletes again. One whose place is not set up waits for that place.
    func retryDeletes() async {
        for object in Self.pendingDeletes(in: deletesFile) {
            guard let place = place(of: object), await place.remove(object.key) else { continue }
            Self.changeDeletes(in: deletesFile) { $0.removeAll { $0 == object } }
            Log.info("Removed a backup copy of a deleted meeting that could not be removed before")
        }
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
        if let cloudBackend { return ArchivedObject(key: key, backend: cloudBackend, server: cloudServer) }
        // A build from before places had names drops the name when it saves a record. A server key says where it is;
        // which server is then not known, so the copy is not trusted and the recording is sent again.
        return ArchivedObject(key: key, kind: ServerArchive.name(of: key) != nil ? .server : .bucket, server: cloudServer)
    }
}
