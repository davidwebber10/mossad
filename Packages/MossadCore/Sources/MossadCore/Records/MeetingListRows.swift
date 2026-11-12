import Foundation

/// The meetings of the Meetings list under a search and the filter.
public enum MeetingListRows {
    /// The meetings that both the search (`found`) and the filter (`kept`) leave; nil is no search or no filter.
    /// The call that records now stays under any search and any filter: it has no transcript, people, or summary
    /// to match yet, and the owner must see that it records.
    public static func visible(_ records: [CallRecord], found: Set<String>?, kept: Set<String>?) -> [CallRecord] {
        guard found != nil || kept != nil else { return records }
        return records.filter { r in
            r.status == .recording || ((found?.contains(r.id) ?? true) && (kept?.contains(r.id) ?? true))
        }
    }
}
