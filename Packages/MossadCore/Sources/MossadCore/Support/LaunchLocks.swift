import Foundation

/// Which locks a window app holds at launch, and when a second copy may offer "Restart Mossad". With profiles a
/// copy takes the Mac-wide lock first, then its folder's. A second copy holds no lock at all: one that kept the
/// Mac-wide lock would make every later launch a second copy, and its own look would never find the lock free.
public enum LaunchLocks {
    public enum Result: Equatable, Sendable { case held, taken, failed }

    public struct Decision: Equatable, Sendable {
        public let secondCopy: Bool
        public let keepsMacWide: Bool

        public init(secondCopy: Bool, keepsMacWide: Bool) {
            self.secondCopy = secondCopy
            self.keepsMacWide = keepsMacWide
        }
    }

    /// The folder lock is not tried when another copy is the foreground app.
    public static func triesFolder(macWide: Result?) -> Bool { macWide != .taken }

    /// `macWide` is nil when the copy takes no Mac-wide lock (no registry file); `folder` is nil when not tried.
    /// A lock that failed is no sign of another copy, as on main.
    public static func decide(macWide: Result?, folder: Result?) -> Decision {
        if macWide == .taken || folder == .taken { return Decision(secondCopy: true, keepsMacWide: false) }
        return Decision(secondCopy: false, keepsMacWide: macWide == .held)
    }

    /// `macWideFree` is nil for a copy that takes no Mac-wide lock.
    public static func mayRestart(folderFree: Bool, macWideFree: Bool?) -> Bool {
        folderFree && (macWideFree ?? true)
    }
}
