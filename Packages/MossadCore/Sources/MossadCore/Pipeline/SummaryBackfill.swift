import Foundation

/// Which old meetings still lack a generated title or the times of their decisions.
public enum SummaryBackfill {
    /// Summaries with titles and decision times. Exact, so an interrupted run never pays twice for a meeting.
    public static let currentVersion = 2

    public static func isDue(_ r: CallRecord) -> Bool {
        r.status == .written && !r.utterances.isEmpty && (r.summaryVersion ?? 0) < currentVersion
    }

    /// Newest first, so the meetings the owner sees first are fixed first.
    public static func due(_ records: [CallRecord]) -> [CallRecord] {
        records.filter(isDue).sorted { $0.start > $1.start }
    }

    /// Runs `step` for each id and stops after this many failures in a row, so a dead key or network does not
    /// spend the whole library on retries.
    public static let maxConsecutiveFailures = 3

    public static func run(ids: [String], step: @Sendable (String) async -> Bool) async -> (updated: Int, paused: Bool) {
        var updated = 0, failures = 0
        for id in ids {
            if await step(id) {
                updated += 1
                failures = 0
            } else {
                failures += 1
                if failures >= maxConsecutiveFailures { return (updated, true) }
            }
        }
        return (updated, false)
    }
}
