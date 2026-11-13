import Foundation
import ObjectiveC

/// Which copy of the Mac app is running: the real Mossad, Mossad Rehearsal, which walks through setup with its
/// own folder, its own Keychain service, and its own permissions, or a preview: a run with the exact argument
/// `--ui-preview` (and no command such as `--mcp`). A preview has its own emptied settings for its data folder and its
/// own empty Keychain service, so a signed preview never shows or changes the owner's settings or secrets. A run on a
/// `MOSSAD_ROOT` alone is the real app on another folder.
public struct AppIdentity: Sendable, Equatable {
    public static let mainBundleID = "com.dwebber.mossad"
    public static let rehearsalBundleID = "com.dwebber.mossad.rehearsal"
    /// The commands that run without the window. They read the real settings, never a preview's.
    public static let commands = ["--mcp", "--people-migration", "--persona-fill", "--persona-eval", "--import-keys"]

    public let bundleID: String?
    /// A `--ui-preview` run.
    public let isPreview: Bool
    /// The data folder a preview was started on, for its own settings suite.
    private let previewRoot: String?

    public init(bundleID: String?, arguments: [String] = [], environment: [String: String] = [:]) {
        self.bundleID = bundleID
        isPreview = arguments.contains("--ui-preview") && !arguments.contains(where: Self.commands.contains)
        previewRoot = isPreview ? environment["MOSSAD_ROOT"].flatMap { $0.isEmpty ? nil : Self.standard($0) } : nil
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
    /// The settings a preview reads and writes instead of the app's own, one suite for each data folder, so two
    /// previews on two folders never empty each other's. Nil for the real copies.
    public var defaultsSuite: String? {
        guard isPreview else { return nil }
        // FNV-1a of the folder: stable across launches, unlike `hashValue`.
        let hash = (previewRoot ?? "").utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        return appID + ".preview." + String(hash, radix: 16)
    }

    /// Why a preview must not start: it has no made-up data folder, or its folder is the real one. Nil when it may.
    public func refusal(home: URL, environment: [String: String]) -> String? {
        guard isPreview else { return nil }
        guard let root = environment["MOSSAD_ROOT"], !root.isEmpty else {
            return "Mossad: --ui-preview needs MOSSAD_ROOT set to a made-up data folder; not starting."
        }
        let real = [home.appendingPathComponent("Mossad"), home.appendingPathComponent("Mossad Rehearsal")].map { Self.standard($0.path) }
        if real.contains(Self.standard(root)) {
            return "Mossad: --ui-preview with MOSSAD_ROOT on the real data folder (\(root)); not starting."
        }
        return nil
    }

    private static func standard(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// `~/Mossad`, `~/Mossad Rehearsal` for Rehearsal, or `$MOSSAD_ROOT` when set.
    public func dataRoot(home: URL, environment: [String: String]) -> URL {
        if let root = environment["MOSSAD_ROOT"], !root.isEmpty { return URL(fileURLWithPath: root) }
        return home.appendingPathComponent(isRehearsal ? "Mossad Rehearsal" : "Mossad")
    }
}

extension AppIdentity {
    /// The few settings a page needs in a preview. Made up.
    public static let previewDefaults: [String: String] = ["ownerName": "Avery Webb"]

    /// A preview's own settings, emptied, with the made-up defaults under the launch arguments
    /// (`-ownerName "Sam Carter"` still applies). Nil for the real copies, which keep their settings untouched.
    public func previewSettings(arguments: [String: Any]? = nil) -> UserDefaults? {
        guard let suite = defaultsSuite, let defaults = UserDefaults(suiteName: suite) else { return nil }
        defaults.removePersistentDomain(forName: suite)
        let given = arguments ?? UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.register(defaults: (Self.previewDefaults as [String: Any]).merging(given) { $1 })
        return defaults
    }

    /// In a preview, points `UserDefaults.standard` (and `@AppStorage`) at the preview's own settings, so nothing a
    /// page shows or saves comes from or goes to the real app's settings. Call it first, before anything reads a
    /// setting. False when a preview could not be isolated: the caller must then stop.
    public func isolateDefaults() -> Bool {
        guard isPreview else { return true }
        guard let defaults = previewSettings(),
              let method = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard)) else { return false }
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in defaults }
        method_setImplementation(method, imp_implementationWithBlock(block))
        return UserDefaults.standard === defaults
    }
}

extension Keychain {
    /// The app's own keys. Every Keychain the apps use comes from here, so Rehearsal never reads the real keys.
    public static let app = Keychain(service: AppIdentity.current.keychainService)
}
