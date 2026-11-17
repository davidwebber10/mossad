import Foundation
import Synchronization

/// The settings of the Mac, not of a profile: the Off switch, the login item, the permission memory, the usage
/// statistics, and Sparkle's own keys. They stay in the real standard domain, which a profile's swap would hide.
public enum MacDefaults {
    public static let keys = ["offUntil", "didSetLoginItem", "screenCaptureAsked", "usageStatsEnabled", "usageStatsInstallID",
                              "usageStatsLastAttempt", "usageStatsEndpoint", "usageStatsInDebug"]
    /// Sparkle's keys all start with `SU`.
    public static let prefixes = ["SU", "automationState."]

    public static func isMacWide(_ key: String) -> Bool {
        keys.contains(key) || prefixes.contains { key.hasPrefix($0) }
    }

    /// The Mac-wide keys found in a profile's settings, which nothing should have written there.
    public static func strays(in domain: [String: Any]) -> [String] {
        domain.keys.filter(isMacWide).sorted()
    }

    // UserDefaults is thread-safe but not marked Sendable, so the lock guards the one reference by hand.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: UserDefaults?
    private static let flag = Atomic<Bool>(false)

    /// The real standard domain, held before a profile's swap. `.standard` until held.
    public static var store: UserDefaults { lock.withLock { held } ?? .standard }

    static func hold(_ real: UserDefaults) { lock.withLock { held = real } }

    /// True while `handOver` runs, on any thread.
    static var handingOver: Bool { flag.load(ordering: .acquiring) }

    /// Runs `make` with `UserDefaults.standard` on the main thread as the real domain, so an object that keeps the
    /// standard defaults it found (Sparkle's hosts) keeps the Mac's own. Main thread only.
    public static func handOver<T>(_ make: () -> T) -> T {
        dispatchPrecondition(condition: .onQueue(.main))
        flag.store(true, ordering: .releasing)
        defer { flag.store(false, ordering: .releasing) }
        return make()
    }
}

/// What `UserDefaults.standard` answers in a profile: its own suite, except on the main thread during a hand-over.
struct DefaultsSwap: @unchecked Sendable {
    let real: UserDefaults
    let profile: UserDefaults

    func current(handingOver: Bool, isMainThread: Bool) -> UserDefaults {
        handingOver && isMainThread ? real : profile
    }
}
