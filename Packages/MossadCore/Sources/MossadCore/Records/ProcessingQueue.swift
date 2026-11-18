import AVFoundation
import Foundation

/// Finds call records that still need work and schedules retries.
public struct ProcessingQueue: Sendable {
    public static let minimumCallDuration: TimeInterval = 60
    static let backoff: [TimeInterval] = [60, 300, 1800, 7200, 21600]

    private let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    /// All records in the audio directory, oldest first. What cannot be read is left out; a caller that deletes or
    /// overwrites because something is missing must use `scan()` instead.
    public func allRecords() -> [CallRecord] {
        (try? scan().records) ?? []
    }

    /// Every call folder, with the records that could be read. Throws when the folder itself cannot be listed.
    /// Unchanged records come from a cache, so a scan decodes only what changed since the last one.
    public func scan() throws -> RecordScan {
        // A part of a cut recording that is still being made (`<id>.cutting`) is no meeting yet.
        let dirs = try FileManager.default.contentsOfDirectory(at: paths.audio, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !$0.lastPathComponent.hasSuffix(Pipeline.cuttingSuffix) }
        var records: [CallRecord] = []
        var unreadable: [String] = []
        for dir in dirs {
            do { records.append(try RecordCache.shared.record(in: dir)) } catch { unreadable.append(dir.lastPathComponent) }
        }
        RecordCache.shared.prune(root: paths.audio, kept: Set(dirs.map { $0.appendingPathComponent(CallRecord.fileName).path }))
        return RecordScan(records: records.sorted { $0.start < $1.start }, folders: Set(dirs.map(\.lastPathComponent)),
                          unreadable: unreadable.sorted())
    }

    public func pending(now: Date) -> [CallRecord] {
        let cutting = inCut()
        return allRecords().filter { r in
            // A meeting that leaves for another profile is never processed here, nor a recording in a cut or its parts.
            r.status != .written && r.status != .recording && r.status != .failed && r.moveTo == nil && (r.nextAttempt ?? .distantPast) <= now
                && !cutting.contains(r.id)
        }
    }

    /// The original and the parts of every cut in progress: until its ledger is gone, none of them is processed.
    func inCut() -> Set<String> {
        let fm = FileManager.default
        var out: Set<String> = []
        for dir in (try? fm.contentsOfDirectory(at: paths.audio, includingPropertiesForKeys: nil)) ?? [] {
            let url = dir.appendingPathComponent(Pipeline.CutLedger.fileName)
            guard fm.fileExists(atPath: url.path) else { continue }
            out.insert(dir.lastPathComponent)
            if let ledger = Pipeline.CutLedger.load(in: dir) { out.insert(ledger.original); out.formUnion(ledger.ids) }
        }
        return out
    }

    /// Finishes calls that were still recording when the app stopped. Returns the calls whose muted parts could not
    /// be silenced: they are kept, held back from processing, and tried again by the pipeline.
    @discardableResult
    public func recoverInterrupted() -> [String] { recoverInterruptedCalls().held }

    /// The same, with the calls that were recording when the app stopped and are kept (`recovered`): their audio
    /// length says nothing of a pause, so a kept choice of another profile counts from the launch (`MoveAfterCall`).
    public func recoverInterruptedCalls() -> (held: [String], recovered: [String]) {
        var held: [String] = [], recovered: [String] = []
        for var r in allRecords() where r.status == .recording {
            let dir = paths.callDirectory(r.id)
            removeTempTracks(in: dir)
            // The longer track: one track can be empty when its capture failed to start.
            // A missing file is an empty track; a file that exists but cannot be read is unknown (nil).
            let durations = [Track.me, .them].map { track -> Double? in
                let url = dir.appendingPathComponent(track.fileName)
                guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
                return (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.fileFormat.sampleRate }
            }
            let duration = durations.compactMap { $0 }.max() ?? 0
            if durations.contains(where: { $0 == nil }) && duration < Self.minimumCallDuration {
                // A track that cannot be read may hold the call. Never delete it: mark it failed at the
                // first processing step, so it shows in Meetings with a Retry button.
                Log.error("Interrupted call \(r.id) has an unreadable track; keeping it")
                r.end = r.start.addingTimeInterval(duration)
                r.status = .failed
                r.failedStep = .recorded
                try? r.save(to: dir)
                recovered.append(r.id)
                continue
            }
            if duration < Self.minimumCallDuration {
                try? FileManager.default.removeItem(at: dir)
                Log.info("Discarded interrupted call \(r.id) (\(Int(duration)) s)")
            } else {
                r.end = r.start.addingTimeInterval(duration)
                r.status = .recorded
                // The audio that was saved ends here; a frame after it has no place in the recording.
                FrameStore.trim(in: dir, to: duration)
                // The mic track holds the real samples until the call ends, so a crashed call has the muted time in it.
                do { try MutedAudio.apply(to: &r, in: dir) } catch {
                    Log.error("Interrupted call \(r.id): \(error.localizedDescription); it waits until that works")
                    MutedAudio.hold(&r)
                    held.append(r.id)
                }
                try? r.save(to: dir)
                recovered.append(r.id)
                Log.info("Recovered interrupted call \(r.id) (\(Int(duration)) s)")
            }
        }
        return (held, recovered)
    }

    /// A rewrite that a quit stopped leaves its temp file (a UUID name) in the call folder.
    private func removeTempTracks(in dir: URL) {
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "caf" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func markFailure(_ r: inout CallRecord, now: Date) {
        r.attempts += 1
        r.nextAttempt = now.addingTimeInterval(Self.backoff[min(r.attempts, Self.backoff.count) - 1])
    }
}
