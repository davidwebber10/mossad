import Foundation

/// Which copy of the Mac app is running: the real Mossad, or Mossad Rehearsal, which walks through setup with its
/// own folder, its own Keychain service, and its own permissions, so it never touches the real app's data or secrets.
public struct AppIdentity: Sendable, Equatable {
    public static let mainBundleID = "com.dwebber.mossad"
    public static let rehearsalBundleID = "com.dwebber.mossad.rehearsal"

    public let bundleID: String?

    public init(bundleID: String?) {
        self.bundleID = bundleID
    }

    public static let current = AppIdentity(bundleID: Bundle.main.bundleIdentifier)

    public var isRehearsal: Bool { bundleID == Self.rehearsalBundleID }

    /// Why the bundle id disagrees with how the app was built, or nil when they agree. The build flag decides what
    /// the app does; the bundle id picks the folder and the Keychain, so a mismatch would mix the two copies' data.
    public func mismatch(rehearsalBuild: Bool) -> String? {
        guard isRehearsal != rehearsalBuild else { return nil }
        return "The \(rehearsalBuild ? "Rehearsal" : "Mossad") build has the bundle id \(bundleID ?? "none")"
    }

    /// The Mac app's own id, for its Keychain service and its System Settings entries. The iPhone app and the tests
    /// use the Mac's; only Rehearsal has its own.
    public var appID: String { isRehearsal ? Self.rehearsalBundleID : Self.mainBundleID }
    public var keychainService: String { appID }

    /// `~/Mossad`, `~/Mossad Rehearsal` for Rehearsal, or `$MOSSAD_ROOT` when set.
    public func dataRoot(home: URL, environment: [String: String]) -> URL {
        if let root = environment["MOSSAD_ROOT"], !root.isEmpty { return URL(fileURLWithPath: root) }
        return home.appendingPathComponent(isRehearsal ? "Mossad Rehearsal" : "Mossad")
    }
}

extension Keychain {
    /// The app's own keys. Every Keychain the apps use comes from here, so Rehearsal never reads the real keys.
    public static let app = Keychain(service: AppIdentity.current.keychainService)
}
