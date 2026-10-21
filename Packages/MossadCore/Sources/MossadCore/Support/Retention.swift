import Foundation

/// Deletes old audio of calls that are fully written. `call.json` (the transcript record) is always kept.
/// The raw tracks go after `rawTracksDays`, but only once the compressed recording exists, so a meeting
/// can be heard again. The recording itself goes only when the person turned that on.
public enum Retention {
    public static let rawTracksDays = 30

    public static func sweep(audioRoot: URL, rawTracksAfterDays: Int = rawTracksDays, recordingsAfterDays: Int? = nil,
                             now: Date = Date()) {
        let fm = FileManager.default
        func cutoff(_ days: Int) -> Date { now.addingTimeInterval(-Double(days) * 86_400) }
        for dir in (try? fm.contentsOfDirectory(at: audioRoot, includingPropertiesForKeys: nil)) ?? [] {
            guard let r = try? CallRecord.load(from: dir), r.status == .written else { continue }
            let expired = recordingsAfterDays.map { r.end < cutoff($0) } ?? false
            let hasRecording = fm.fileExists(atPath: Recording.url(in: dir).path)
            guard expired || (hasRecording && r.end < cutoff(rawTracksAfterDays)) else { continue }
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "caf" || (expired && file.lastPathComponent == Recording.fileName) {
                try? fm.removeItem(at: file)
            }
        }
    }
}
