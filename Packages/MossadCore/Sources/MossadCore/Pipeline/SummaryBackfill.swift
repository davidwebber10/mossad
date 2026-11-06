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
}
