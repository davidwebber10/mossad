import Foundation

/// Which old meetings still lack a generated title or the times of their decisions.
public enum SummaryBackfill {
    public static func isDue(_ r: CallRecord) -> Bool {
        r.status == .written && !r.utterances.isEmpty && (r.generatedTitle == nil || r.decisions.contains { $0.at == nil })
    }

    /// Newest first, so the meetings the owner sees first are fixed first.
    public static func due(_ records: [CallRecord]) -> [CallRecord] {
        records.filter(isDue).sorted { $0.start > $1.start }
    }
}
