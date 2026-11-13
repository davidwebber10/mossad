import Foundation
import ObjectiveC

/// Which copy of the Mac app is running: the real Mossad, Mossad Rehearsal, which walks through setup with its
/// own folder, its own Keychain service, and its own permissions, or a preview (`--ui-preview`, or any run on a
/// `MOSSAD_ROOT`), which has its own empty settings and Keychain service. Neither ever touches the real app's
/// settings or secrets: a signed preview could otherwise show the owner's server, keys, or Google account.
public struct AppIdentity: Sendable, Equatable {
    public static let mainBundleID = "com.dwebber.mossad"
    public static let rehearsalBundleID = "com.dwebber.mossad.rehearsal"

    public let bundleID: String?
    /// A preview or a run on a made-up folder.
    public let isPreview: Bool

    public init(bundleID: String?, arguments: [String] = [], environment: [String: String] = [:]) {
        self.bundleID = bundleID
        isPreview = arguments.contains("--ui-preview") || !(environment["MOSSAD_ROOT"] ?? "").isEmpty
    }

    public static let current = AppIdentity(bundleID: Bundle.main.bundleIdentifier, arguments: CommandLine.arguments,
                                            environment: ProcessInfo.processInfo.environment)

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
    /// A preview's service holds nothing: the Keychain of the copy it runs as stays unread.
    public var keychainService: String { isPreview ? appID + ".preview" : appID }
    /// The settings a preview reads and writes instead of the app's own. Nil for the real copies.
    public var defaultsSuite: String? { isPreview ? appID + ".preview" : nil }

    /// `~/Mossad`, `~/Mossad Rehearsal` for Rehearsal, or `$MOSSAD_ROOT` when set.
    public func dataRoot(home: URL, environment: [String: String]) -> URL {
        if let root = environment["MOSSAD_ROOT"], !root.isEmpty { return URL(fileURLWithPath: root) }
        return home.appendingPathComponent(isRehearsal ? "Mossad Rehearsal" : "Mossad")
    }
}

extension AppIdentity {
    /// The few settings a page needs in a preview. Made up.
    public static let previewDefaults: [String: String] = ["ownerName": "Avery Webb"]

    /// In a preview, points `UserDefaults.standard` (and `@AppStorage`) at the preview's own settings, emptied at
    /// each launch, so nothing a page shows or saves comes from or goes to the real app's settings. Values given as
    /// launch arguments (`-ownerName "Sam Carter"`) still apply. Call it first, before anything reads a setting.
    @discardableResult
    public func isolateDefaults() -> UserDefaults? {
        guard let suite = defaultsSuite, let defaults = UserDefaults(suiteName: suite) else { return nil }
        defaults.removePersistentDomain(forName: suite)
        // A made-up owner, so no page falls back to the Mac account's real name; launch arguments win.
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.register(defaults: (Self.previewDefaults as [String: Any]).merging(arguments) { $1 })
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        guard let method = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard)) else { return nil }
        method_setImplementation(method, imp_implementationWithBlock(block))
        return defaults
    }
}

extension Keychain {
    /// The app's own keys. Every Keychain the apps use comes from here, so Rehearsal never reads the real keys.
    public static let app = Keychain(service: AppIdentity.current.keychainService)
}
