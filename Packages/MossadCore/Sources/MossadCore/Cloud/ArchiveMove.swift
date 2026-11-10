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
        /// Not in the old place and not on this Mac: there was nothing to copy. Their false backup mark is gone.
        public var missing: [String] = []
        /// Meetings whose record could not be read. One of them may name a copy in the old place, so nothing is removed.
        public var unreadable: [String] = []
        /// Old copies removed in this run, each after its recording was checked in the new place once more.
        public var removed = 0
        /// The caller ended the run: the owner chose another place, or a call started.
        public var stopped = false
        /// The old place did not answer, so nothing was tried.
        public var silent = false
        /// Recordings in the old place at the end, by its own list. Nil when it was not asked or could not say.
        public var strays: Int?
        /// The old place was asked for its list and did not give one.
        public var listFailed = false
        /// Nothing is left in the old place: no record names it, and its own list is empty.
        public var complete = false
        /// Not complete, and another run changes nothing: what is left needs the owner.
        public var settled = false

        public init() {}

        /// One line for the log and for Settings. `old` and `new` name the places, such as "Cloudflare R2".
        public func summary(old: String, new: String) -> String {
            func recordings(_ n: Int) -> String { n == 1 ? "1 recording" : "\(n) recordings" }
            if silent { return "\(old) did not answer, so nothing was moved." }
            var parts: [String] = []
            if complete {
                parts.append(moved > 0 ? "Moved \(recordings(moved)) to \(new)." : "Every backup is on \(new).")
                parts.append(removed > 0 ? "Removed \(removed == 1 ? "the old copy" : "\(removed) old copies") from \(old)." : "Nothing is left in \(old).")
            } else {
                if total > 0 { parts.append("Moved \(moved) of \(recordings(total)) to \(new).") }
                if stopped { parts.append("The move stopped before it was done.") }
                if !waiting.isEmpty { parts.append("\(waiting.count) could not be copied yet.") }
                if !tooLarge.isEmpty { parts.append("\(tooLarge.count == 1 ? "1 is" : "\(tooLarge.count) are") larger than \(new) takes\(settled ? " and \(tooLarge.count == 1 ? "stays" : "stay") in \(old)" : "").") }
                if !unreadable.isEmpty { parts.append("\(unreadable.count == 1 ? "1 meeting" : "\(unreadable.count) meetings") on this Mac could not be read, so \(unreadable.count == 1 ? "its backup is" : "their backups are") not known.") }
                parts.append(removed > 0 ? "Removed \(removed == 1 ? "1 old copy" : "\(removed) old copies") from \(old)." : "Nothing was removed from \(old).")
                if let strays, strays > 0 { parts.append("\(strays == 1 ? "1 recording is" : "\(strays) recordings are") still in \(old).") }
                else if listFailed { parts.append("\(old) did not say what it still holds.") }
            }
            if !missing.isEmpty { parts.append("\(missing.count == 1 ? "1 was" : "\(missing.count) were") not in \(old) and had no copy to move.") }
            return parts.joined(separator: " ")
        }
    }

    private enum Copy { case moved, waiting, tooLarge, missing, gone }

    /// The recordings that a move from this place still has to do something for: copy them, or remove their old copy.
    public static func leftToMove(_ records: [CallRecord], from old: ArchiveKind) -> Int {
        records.filter { $0.archived?.kind == old || $0.cloudLeftovers?.contains { $0.kind == old } == true }.count
    }

    /// Whether, read from the disk at this moment, no meeting names a copy in this place and every record could be
    /// read. The app asks this once more at the moment it forgets the old place.
    public static func nothingLeft(in paths: Paths, from old: ArchiveKind) -> Bool {
        guard let scan = try? ProcessingQueue(paths: paths).scan() else { return false }
        let damaged = scan.unreadable.contains { FileManager.default.fileExists(atPath: paths.callDirectory($0).appendingPathComponent(CallRecord.fileName).path) }
        return !damaged && leftToMove(scan.records, from: old) == 0
    }

    /// What the app does after a run of a move.
    public enum MoveEnd: Equatable, Sendable {
        /// The owner ended the move during the run. Nothing changes: no setting, no secret.
        case ignored
        /// Everything is in the new place and checked: the old place's settings and secret can go.
        case forgetOldPlace
        /// Nothing is left in the old place, but a recording was missing there. The owner decides about its settings.
        case doneKeepSettings
        /// Another run changes nothing. The move ends, and the old place stays set up.
        case rests
        /// The run ended for a call. It goes on after it.
        case paused
        /// Something failed for a reason that passes. The next pass tries again.
        case again
    }

    /// The rule for the end of a run. `stillAsked`: the move is still wanted and the new place is still the chosen
    /// backup, at this moment. `nothingLeftNow`: no record names the old place, read at this moment. `missing`:
    /// recordings that the move, over all its runs, did not find anywhere.
    /// Whether a run of the move may go on, asked before each copy and each delete, and once more at its end. A run
    /// belongs to the server it started with (`runServerID`): after "Change server" or "Disconnect" it must stop, or
    /// it copies to the old server and then removes the bucket copies and the bucket settings.
    public static func moveMayGoOn(pending: Bool, choiceIsServer: Bool, canMove: Bool, recording: Bool,
                                   serverID: String, runServerID: String?) -> Bool {
        pending && choiceIsServer && canMove && !recording && !serverID.isEmpty && (runServerID.map { $0 == serverID } ?? true)
    }

    public static func moveEnd(_ report: MoveReport, stillAsked: Bool, nothingLeftNow: @autoclosure () -> Bool, missing: Int) -> MoveEnd {
        guard stillAsked else { return .ignored }
        if report.stopped { return .paused }
        if report.complete {
            guard nothingLeftNow() else { return .again }
            return missing == 0 ? .forgetOldPlace : .doneKeepSettings
        }
        return report.settled ? .rests : .again
    }

    /// Moves every archived recording from one place to another. It can stop at any point and run again.
    ///
    /// First each recording is copied: from this Mac when the local file is the one that was uploaded, otherwise
    /// from the old place. The new place must then report the same size and the same SHA-256 before the record
    /// names the new place; the old copy stays, as a leftover of the record. Only when no recording waits to be
    /// copied are the old copies removed, each one after the new place says once more that it has the file.
    ///
    /// `shouldContinue` is asked before each copy and before each delete. When it says no (the owner chose another
    /// place, a call started), the run ends at once and deletes nothing more.
    public func move(from old: ArchiveKind, to new: ArchiveKind, pipeline: Pipeline,
                     shouldContinue: @Sendable () async -> Bool = { true },
                     progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) async -> MoveReport {
        var report = MoveReport()
        let queue = ProcessingQueue(paths: paths)
        // The whole list, or nothing: a move that removes copies must know about every meeting.
        guard let scan = try? queue.scan() else {
            Log.error("Backup move: the meetings on this Mac could not be listed, so nothing was moved")
            report.unreadable = ["*"]
            return report
        }
        // A folder with no record is not a meeting. A record that is there and cannot be read may name a copy.
        report.unreadable = damaged(scan)
        let waiting = scan.records.filter { $0.archived?.kind == old }
        report.total = waiting.count
        guard let destination = places[new] else {
            report.waiting = waiting.map(\.id)
            return report
        }
        guard await shouldContinue() else {
            report.stopped = true
            return report
        }
        let source = places[old]
        if !waiting.isEmpty {
            // A bucket that does not answer, or a wrong bucket name, must not look like a bucket that is empty.
            guard await source?.check() != false else {
                Log.error("Backup move: \(old.place) did not answer, so nothing was moved")
                report.silent = true
                report.waiting = waiting.map(\.id)
                return report
            }
            for (i, r) in waiting.enumerated() {
                guard await shouldContinue() else {
                    report.stopped = true
                    return report
                }
                progress?(i, waiting.count)
                switch await copy(r, from: source, to: destination, pipeline: pipeline) {
                case .moved: report.moved += 1
                case .waiting: report.waiting.append(r.id)
                case .tooLarge: report.tooLarge.append(r.id)
                case .missing: report.missing.append(r.id)
                case .gone: break
                }
            }
            progress?(waiting.count, waiting.count)
        }
        // A recording that a merge made new has its old copy as a leftover and no copy in the new place yet. The
        // upload pass sends it; until then its old copy is the only one in a backup, and stays.
        var held: Set<String> = []
        for r in scan.records where r.archived?.kind != old && r.cloudLeftovers?.contains(where: { $0.kind == old }) == true {
            if let current = r.archived, current.kind == new, place(of: current) != nil { continue }
            held.insert(r.id)
            guard let size = Self.size(Recording.url(in: paths.callDirectory(r.id))) else { continue }
            if let max = destination.maxBytes, size > max { report.tooLarge.append(r.id) } else { report.waiting.append(r.id) }
        }
        guard report.waiting.isEmpty, report.unreadable.isEmpty else { return report }
        // Every recording that can be in the new place is there and was checked. Now, and only now, the old copies go.
        var failed = false
        for r in queue.allRecords() {
            let before = r.cloudLeftovers?.filter { $0.kind == old }.count ?? 0
            guard before > 0, !held.contains(r.id) else { continue }
            guard await shouldContinue() else {
                report.stopped = true
                return report
            }
            await removeLeftovers(of: r.id, pipeline: pipeline, asking: true, requiring: new)
            let after = (try? CallRecord.load(from: paths.callDirectory(r.id)))?.cloudLeftovers?.filter { $0.kind == old }.count ?? 0
            report.removed += before - after
            if after > 0 { failed = true }
        }
        guard await shouldContinue() else {
            report.stopped = true
            return report
        }
        // Read once more: the answer "nothing is left" lets the owner's app forget the old place.
        guard let after = try? queue.scan(), damaged(after).isEmpty else { return report }
        let named = after.records.contains { $0.archived?.kind == old || $0.cloudLeftovers?.contains { $0.kind == old } == true }
        if !named {
            // The records name nothing there. The place itself has the last word: an object that no record names
            // (an earlier delete that failed) is still the owner's recording.
            report.strays = source == nil ? 0 : await source?.recordingCount()
            report.listFailed = report.strays == nil
            report.complete = report.strays == 0
        }
        report.settled = !report.complete && !failed
        return report
    }

    /// The folders whose record is there and cannot be read.
    private func damaged(_ scan: RecordScan) -> [String] {
        scan.unreadable.filter { FileManager.default.fileExists(atPath: paths.callDirectory($0).appendingPathComponent(CallRecord.fileName).path) }
    }

    private func copy(_ r: CallRecord, from source: (any ArchiveBackend)?, to destination: any ArchiveBackend, pipeline: Pipeline) async -> Copy {
        guard let current = r.archived else { return .waiting }
        let dir = paths.callDirectory(r.id)
        let local = Recording.url(in: dir)
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
                // The place answers (it passed its check) and does not have this file, so the mark is false. Without
                // the mark the audio on this Mac stays, and a recording that is here (or can be made again from the
                // raw tracks) goes to the new place in the next upload pass.
                await pipeline.clearArchived(callID: r.id, ifCurrent: current)
                if localSize != nil {
                    Log.info("Backup move: the recording of \(r.id) was not in \(source.kind.place); the one on this Mac is sent in the next pass")
                    return .waiting
                }
                Log.error("Backup move: the recording of \(r.id) is not in \(source.kind.place) and not on this Mac. Its backup mark was removed")
                return .missing
            case .present(let size, _):
                // Before anything is read: a file that the new place cannot take is not downloaded.
                if let max = destination.maxBytes, size > max { return .tooLarge }
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
        guard let file, let size = Self.size(file) else { return .waiting }
        if let max = destination.maxBytes, size > max { return .tooLarge }
        guard let hash = try? FileHash.sha256(of: file) else { return .waiting }
        let object = destination.object(for: r.id)
        let wanted = ArchivePresence.present(size: size, sha256: hash)
        // A run that stopped after the upload finds the file there and does not send it again.
        if await destination.presence(object.key) != wanted {
            guard await put(file, object, in: destination, sha256: hash) != nil else {
                return FileManager.default.fileExists(atPath: dir.path) ? .waiting : .gone
            }
            guard await destination.presence(object.key) == wanted else {
                Log.error("Backup move: \(destination.kind.place) does not have the whole recording of \(r.id); its old copy stays")
                return .waiting
            }
        }
        // Only a record that still names the old copy changes: an edit in between is looked at again in the next run.
        guard await pipeline.setArchived(callID: r.id, object, size: size, sha256: hash, ifCurrent: current) else {
            // Deleted or merged away during the copy: a meeting that is gone leaves nothing in the new place.
            if !FileManager.default.fileExists(atPath: dir.path) {
                await destination.remove(object.key)
                Log.info("Backup move: removed the copy of \(r.id), which was deleted during the move")
                return .gone
            }
            return .waiting
        }
        Log.info("Backup move: \(r.id) is on \(destination.kind.place)")
        return .moved
    }
}
