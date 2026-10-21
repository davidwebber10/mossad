import Foundation

/// Deletes old audio for calls that are fully written. `call.json` (the transcript record) is kept.
public enum Retention {
    public static func sweep(audioRoot: URL, olderThan days: Int = 30, now: Date = Date()) {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        for dir in (try? fm.contentsOfDirectory(at: audioRoot, includingPropertiesForKeys: nil)) ?? [] {
            guard let r = try? CallRecord.load(from: dir), r.status == .written, r.end < cutoff else { continue }
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "caf" {
                try? fm.removeItem(at: file)
            }
        }
    }
}
