import Foundation

/// The day the filter's counts were made for. "Today" and "Last 7 days" move with the clock, and the menu bar app
/// runs for days, so the app counts again once this day is over: at midnight, after a sleep, and in a new time zone.
public struct MeetingFilterDay: Sendable {
    public var calendar: Calendar
    /// The day of the last count, as the calendar of that moment had it.
    private var day: DateInterval?

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public mutating func counted(at date: Date) { day = calendar.dateInterval(of: .day, for: date) }

    /// Whether the day of `now` is another day than that of the last count, in `calendar` (the system's one now,
    /// which a new time zone moves).
    public func isStale(now: Date, calendar: Calendar? = nil) -> Bool {
        guard let day else { return true }
        return (calendar ?? self.calendar).dateInterval(of: .day, for: now) != day
    }

    /// The start of the day after the last count, when the date choices change by themselves.
    public var nextChange: Date? { day?.end }
}

/// A click on the filter button while the flyout is open first closes the flyout, as any click outside it does;
/// the same click must not open it again.
public struct MeetingFilterFlyoutGate: Sendable {
    public static let pause: TimeInterval = 0.3
    private var closedAt = Date.distantPast

    public init() {}

    public mutating func closed(at date: Date) { closedAt = date }
    public func mayOpen(at date: Date) -> Bool { date.timeIntervalSince(closedAt) >= Self.pause }
}
