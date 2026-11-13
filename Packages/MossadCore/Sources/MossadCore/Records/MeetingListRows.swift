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

    /// When the list takes the keys back (the search closed, Return or Down Arrow in the field): whether the
    /// selection stays, or the first row is selected.
    /// A meeting or an invite that the list has no row for (an invite past the two work days, opened from a search
    /// or a link) stays shown while there is no search text; Return or Down Arrow from a search goes to its rows.
    public static func keepsSelection(_ selection: String?, query: String, inList: Bool, known: Bool) -> Bool {
        guard selection != nil else { return false }
        if inList { return true }
        return known && query.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
