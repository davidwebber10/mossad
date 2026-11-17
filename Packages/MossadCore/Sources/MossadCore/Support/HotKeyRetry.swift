import Foundation

/// A global hot key that could not be registered (another app, or the instance before a switch, still had it) is
/// tried again after 2, 5, and 15 seconds; after that one log line says so.
public enum HotKeyRetry {
    public static let delays: [TimeInterval] = [2, 5, 15]

    /// The wait after the `failures`-th failed try (1 is the first), or nil when no try is left.
    public static func delay(afterFailure failures: Int) -> TimeInterval? {
        guard failures >= 1, failures <= delays.count else { return nil }
        return delays[failures - 1]
    }
}
