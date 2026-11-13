import Foundation

/// Which series the Recurring page shows next to its list.
public enum SeriesShown {
    /// The selected series while the list shows it, else the first of the list. A series that Back, Forward, or a
    /// link asked for (`asked`) shows even before the list has answered its search, until the owner changes the list.
    public static func pick(selected: String?, asked: Bool, visible: [String], all: [String]) -> String? {
        if let selected, visible.contains(selected) || (asked && all.contains(selected)) { return selected }
        return visible.first
    }

    /// A link to a series that the search or the filter hides clears them: the link asks to see that series.
    public static func linkClearsList(to id: String, visible: [String]) -> Bool { !visible.contains(id) }

    /// The series a link opens full-pane in Calendar mode, as Meetings' calendar opens a meeting; nil in List mode,
    /// where the selection shows it, and for a series that is gone. `resolve` turns a key into the series' id.
    public static func fullPane(calendarMode: Bool, request: String, all: [String], resolve: (String) -> String? = { _ in nil }) -> String? {
        guard calendarMode else { return nil }
        if all.contains(request) { return request }
        return resolve(request).flatMap { all.contains($0) ? $0 : nil }
    }
}
