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

    /// All records in the audio directory, oldest first.
    public func allRecords() -> [CallRecord] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: paths.audio, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { try? CallRecord.load(from: $0) }.sorted { $0.start < $1.start }
    }

    public func pending(now: Date) -> [CallRecord] {
        allRecords().filter { r in
            r.status != .written && r.status != .recording && r.status != .failed && (r.nextAttempt ?? .distantPast) <= now
        }
    }

    /// Finishes calls that were still recording when the app stopped.
    public func recoverInterrupted() {
        for var r in allRecords() where r.status == .recording {
            let dir = paths.callDirectory(r.id)
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
                continue
            }
            if duration < Self.minimumCallDuration {
                try? FileManager.default.removeItem(at: dir)
                Log.info("Discarded interrupted call \(r.id) (\(Int(duration)) s)")
            } else {
                r.end = r.start.addingTimeInterval(duration)
                r.status = .recorded
                try? r.save(to: dir)
                Log.info("Recovered interrupted call \(r.id) (\(Int(duration)) s)")
            }
        }
    }

    public func markFailure(_ r: inout CallRecord, now: Date) {
        r.attempts += 1
        r.nextAttempt = now.addingTimeInterval(Self.backoff[min(r.attempts, Self.backoff.count) - 1])
    }
}
