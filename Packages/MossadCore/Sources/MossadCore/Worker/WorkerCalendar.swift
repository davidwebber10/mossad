import Foundation

/// The calendar that a worker's pipeline reads, to match the invite of a meeting it finishes, and what "unknown"
/// is. The Mac's calendars only with full access and a choice the profile's window app saved; Google with the
/// profile's own tokens. It never asks for a permission.
public final class WorkerCalendar: CalendarSource, @unchecked Sendable {
    public enum Mac: Equatable, Sendable {
        /// Full access, and the profile chose its calendars.
        case readable
        /// The profile chose no Mac calendar: nothing to read, and that is known.
        case none
        /// No permission, no choice yet (every calendar of the Mac would come in), or a made-up registry.
        case unknown
    }

    public static func mac(authorized: Bool, chosen: [String]?, madeUpRegistry: Bool) -> Mac {
        guard !madeUpRegistry, authorized, let chosen else { return .unknown }
        return chosen.isEmpty ? .none : .readable
    }

    /// Whether "no event" is an answer: never with the Mac unknown, or with a Google read that failed.
    public static func known(mac: Mac, google: CalendarSnapshot.Access.Read) -> Bool {
        mac != .unknown && google != .failed
    }

    /// Whether the window app looks again at its marked meetings at launch: only with a registry file (a meeting is
    /// marked only by a worker, and a worker needs one), and a calendar it can read. With one profile, never.
    public static func looksAgainAtLaunch(registry: ProfileRegistry.State, macCalendar: CalendarSnapshot.Access.Read, googleCalendar: Bool) -> Bool {
        registry != .none && (macCalendar == .yes || googleCalendar)
    }

    private struct Nothing: CalendarSource {
        func events(from: Date, to: Date) async -> [CalendarEventInfo] { [] }
    }

    private let mac: Mac
    private let merged: MergedCalendarSource

    /// A worker has no owner who waits for its read, so Google gets longer than the window app's 2 s.
    static let googleWaitLimit: Duration = .seconds(20)
    var googleWait: Duration { merged.waitLimit }

    public init(mac: Mac, macSource: CalendarSource, google: GoogleCalendarSource?) {
        self.mac = mac
        merged = MergedCalendarSource(mac: mac == .readable ? macSource : Nothing(), google: { google }, waitLimit: Self.googleWaitLimit)
    }

    public func events(from: Date, to: Date) async -> [CalendarEventInfo] {
        await merged.events(from: from, to: to)
    }

    /// "Known" by this read's own Google answer, never by another call's.
    public func read(from: Date, to: Date) async -> CalendarRead {
        let r = await merged.read(from: from, to: to)
        return CalendarRead(events: r.events, known: Self.known(mac: mac, google: r.google), google: r.google)
    }

    public func canRead() async -> Bool {
        Self.known(mac: mac, google: merged.lastGoogleRead)
    }
}
