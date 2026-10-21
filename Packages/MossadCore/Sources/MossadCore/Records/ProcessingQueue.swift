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
            let duration = (try? AVAudioFile(forReading: dir.appendingPathComponent(Track.me.fileName))).map {
                Double($0.length) / $0.fileFormat.sampleRate
            } ?? 0
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
