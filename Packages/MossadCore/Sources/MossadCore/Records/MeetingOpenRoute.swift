/// Where a request to open a meeting lands on the Meetings page. Split mode shows the selected meeting by itself;
/// Calendar mode shows a meeting only full-pane, so a request must open it there.
public enum MeetingOpenRoute {
    /// The meeting Calendar mode shows full-pane; nil in Split mode, which has no full pane.
    public static func fullPane(calendarMode: Bool, request: String?, shown: String?) -> String? {
        guard calendarMode else { return nil }
        return request ?? shown
    }

    /// A pending seek belongs to one meeting; when another opens, it must not wait for the owner to open its own.
    public static func keepsSeek(for seekCallID: String?, opening: String) -> Bool {
        seekCallID == opening
    }
}
