import Foundation

extension CloudArchive {
    /// What one run of a move did.
    public struct MoveReport: Equatable, Sendable {
        /// Recordings that were in the old place when this run started.
        public var total = 0
        /// Copied to the new place and checked there, in this run.
        public var moved = 0
        /// Not copied yet: a place did not answer, or an upload or its check failed. The next run tries again.
        public var waiting: [String] = []
        /// Larger than the new place takes. They stay in the old place.
        public var tooLarge: [String] = []
        /// Not in the old place and not on this Mac: there was nothing to copy.
        public var missing: [String] = []
        /// Old copies removed in this run, after every recording was checked in the new place.
        public var removed = 0
        /// Nothing is left in the old place.
        public var complete = false

        public init() {}

        /// One line for the log and for Settings. `old` and `new` name the places, such as "Cloudflare R2".
        public func summary(old: String, new: String) -> String {
            func recordings(_ n: Int) -> String { n == 1 ? "1 recording" : "\(n) recordings" }
            var parts: [String] = []
            if complete {
                parts.append(moved > 0 ? "Moved \(recordings(moved)) to \(new)." : "Every backup is on \(new).")
                parts.append(removed > 0 ? "Removed \(removed == 1 ? "the old copy" : "\(removed) old copies") from \(old)." : "Nothing is left in \(old).")
            } else {
                parts.append("Moved \(moved) of \(recordings(total)) to \(new).")
                if !waiting.isEmpty { parts.append("\(waiting.count) could not be copied yet.") }
                if !tooLarge.isEmpty { parts.append("\(tooLarge.count == 1 ? "1 is" : "\(tooLarge.count) are") larger than \(new) takes.") }
                parts.append("Nothing was removed from \(old).")
            }
            if !missing.isEmpty { parts.append("\(missing.count == 1 ? "1 was" : "\(missing.count) were") not in \(old) and had no copy to move.") }
            return parts.joined(separator: " ")
        }
    }

    private enum Copy { case moved, waiting, tooLarge, missing }

    /// The recordings that a move from this place still has to do something for: copy them, or remove their old copy.
    public static func leftToMove(_ records: [CallRecord], from old: ArchiveKind) -> Int {
        records.filter { $0.archived?.kind == old || $0.cloudLeftovers?.contains { $0.kind == old } == true }.count
    }

    /// Moves every archived recording from one place to another. It can stop at any point and run again.
    ///
    /// First each recording is copied: from this Mac when the local file is the one that was uploaded, otherwise
    /// from the old place. The new place must then report the same size and the same SHA-256 before the record
    /// names the new place; the old copy stays, as a leftover of the record. Only when no recording is left to
    /// copy are the old copies removed, each one after the new place says once more that it has the file.
    public func move(from old: ArchiveKind, to new: ArchiveKind, pipeline: Pipeline,
                     progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) async -> MoveReport {
        var report = MoveReport()
        let queue = ProcessingQueue(paths: paths)
        let waiting = queue.allRecords().filter { $0.archived?.kind == old }
        report.total = waiting.count
        guard let destination = places[new] else {
            report.waiting = waiting.map(\.id)
            return report
        }
        let source = places[old]
        if !waiting.isEmpty {
            // A bucket that does not answer, or a wrong bucket name, must not look like a bucket that is empty.
            guard await source?.check() != false else {
                Log.error("Backup move: \(old.place) did not answer, so nothing was moved")
                report.waiting = waiting.map(\.id)
                return report
            }
            for (i, r) in waiting.enumerated() {
                progress?(i, waiting.count)
                switch await copy(r, from: source, to: destination, pipeline: pipeline) {
                case .moved: report.moved += 1
                case .waiting: report.waiting.append(r.id)
                case .tooLarge: report.tooLarge.append(r.id)
                case .missing: report.missing.append(r.id)
                }
            }
            progress?(waiting.count, waiting.count)
        }
        guard report.waiting.isEmpty, report.tooLarge.isEmpty else { return report }
        // Every recording is in the new place and was checked there. Now, and only now, the old copies go.
        var blocked = false
        for r in queue.allRecords() {
            let before = r.cloudLeftovers?.filter { $0.kind == old }.count ?? 0
            guard before > 0 else { continue }
            await removeLeftovers(of: r.id, pipeline: pipeline, asking: true)
            let after = (try? CallRecord.load(from: paths.callDirectory(r.id)))?.cloudLeftovers?.filter { $0.kind == old }.count ?? 0
            report.removed += before - after
            if after > 0 { blocked = true }
        }
        let missing = Set(report.missing)
        report.complete = !blocked && !queue.allRecords().contains { $0.archived?.kind == old && !missing.contains($0.id) }
        return report
    }

    private func copy(_ r: CallRecord, from source: (any ArchiveBackend)?, to destination: any ArchiveBackend, pipeline: Pipeline) async -> Copy {
        guard let current = r.archived else { return .waiting }
        let local = Recording.url(in: paths.callDirectory(r.id))
        let localSize = Self.size(local)
        var file: URL?
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        if let localSize, localSize == r.cloudSize {
            // The local file is the file that was uploaded.
            file = local
        } else if let localSize, let known = r.cloudSize, localSize != known {
            // The recording changed after its upload (a merge). The next upload sends the new one; the old bytes are not copied.
            return .waiting
        } else {
            guard let source else { return .waiting }
            switch await source.presence(current.key) {
            case .unknown: return .waiting
            case .absent:
                Log.error("Backup move: the recording of \(r.id) is not in \(source.kind.place) and not on this Mac")
                return .missing
            case .present(let size, _):
                if localSize == size {
                    file = local
                } else {
                    do {
                        let downloaded = try await TransientRetry.run(pause: retryPause) { try await source.download(current.key, session: session) }
                        temporary = downloaded
                        guard Self.size(downloaded) == size else { return .waiting }
                        file = downloaded
                    } catch {
                        Log.error("Backup move: reading \(r.id) from \(source.kind.place) failed: \(error.localizedDescription)")
                        return .waiting
                    }
                }
            }
        }
        guard let file, let size = Self.size(file), let hash = try? FileHash.sha256(of: file) else { return .waiting }
        if let max = destination.maxBytes, size > max { return .tooLarge }
        let object = ArchivedObject(key: destination.key(for: r.id), kind: destination.kind)
        let wanted = ArchivePresence.present(size: size, sha256: hash)
        // A run that stopped after the upload finds the file there and does not send it again.
        if await destination.presence(object.key) != wanted {
            guard await put(file, object, in: destination) else { return .waiting }
            guard await destination.presence(object.key) == wanted else {
                Log.error("Backup move: \(destination.kind.place) does not have the whole recording of \(r.id); its old copy stays")
                return .waiting
            }
        }
        // Only a record that still names the old copy changes: an edit in between is looked at again in the next run.
        guard await pipeline.setArchived(callID: r.id, object, size: size, ifCurrent: current) else { return .waiting }
        Log.info("Backup move: \(r.id) is on \(destination.kind.place)")
        return .moved
    }
}
