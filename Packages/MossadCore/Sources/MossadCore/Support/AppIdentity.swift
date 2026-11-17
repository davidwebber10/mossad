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
    /// A run on `MOSSAD_ROOT`, which has no profiles.
    private let onOtherRoot: Bool
    /// The profile this process is from its first line to its last. `default` unless the copy takes profiles.
    public let profile: Profile
    /// The registry as read at launch, for what the switcher shows. `.none` with no file.
    public let registry: ProfileRegistry.Loaded
    /// The registry came from `MOSSAD_PROFILES`, not the real file: the window app is then inert.
    public let madeUpRegistry: Bool
    /// Why the chosen profile cannot start (an unknown id), or nil.
    public let profileRefusal: String?

    public init(bundleID: String?, arguments: [String] = [], environment: [String: String] = [:],
                registry: ProfileRegistry.Loaded? = nil, madeUpRegistry: Bool = false) {
        self.bundleID = bundleID
        isPreview = arguments.contains("--ui-preview") && !arguments.contains(where: Self.commands.contains)
        previewRoot = isPreview ? environment["MOSSAD_ROOT"].flatMap { $0.isEmpty ? nil : Self.standard($0) } : nil
        onOtherRoot = !(environment["MOSSAD_ROOT"] ?? "").isEmpty
        let loaded = registry ?? .none
        self.registry = loaded
        self.madeUpRegistry = madeUpRegistry
        let takes = bundleID != Self.rehearsalBundleID && !isPreview && !onOtherRoot
        switch takes ? ProfileLaunch.choice(arguments: arguments, registry: loaded) : .profile(.default) {
        case .profile(let chosen): profile = chosen; profileRefusal = nil
        case .refused(let why): profile = .default; profileRefusal = why
        }
    }

    #if os(macOS)
    public static let current = launch(bundleID: Bundle.main.bundleIdentifier, arguments: CommandLine.arguments,
                                       environment: ProcessInfo.processInfo.environment,
                                       home: FileManager.default.homeDirectoryForCurrentUser)
    #else
    public static let current = AppIdentity(bundleID: Bundle.main.bundleIdentifier, arguments: CommandLine.arguments,
                                            environment: ProcessInfo.processInfo.environment)
    #endif

    /// Only the real Mac app reads the registry: not Rehearsal, the iPhone, the tests, a preview, or a `MOSSAD_ROOT` run.
    public static func readsRegistry(bundleID: String?, arguments: [String], environment: [String: String]) -> Bool {
        bundleID == mainBundleID && !arguments.contains("--ui-preview") && (environment["MOSSAD_ROOT"] ?? "").isEmpty
    }

    /// The identity of this process. `MOSSAD_PROFILES=<file>` takes the place of the real registry: a preview only
    /// shows it, any other run becomes a profile of it and is inert. The real file is then never read.
    public static func launch(bundleID: String?, arguments: [String], environment: [String: String], home: URL) -> AppIdentity {
        #if os(macOS)
        let madeUp = environment["MOSSAD_PROFILES"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        if readsRegistry(bundleID: bundleID, arguments: arguments, environment: environment) {
            let loaded = ProfileRegistry.load(from: madeUp ?? ProfileRegistry.fileURL(home: home))
            return AppIdentity(bundleID: bundleID, arguments: arguments, environment: environment, registry: loaded,
                               madeUpRegistry: madeUp != nil)
        }
        let probe = AppIdentity(bundleID: bundleID, arguments: arguments, environment: environment)
        if probe.isPreview, let madeUp {
            return AppIdentity(bundleID: bundleID, arguments: arguments, environment: environment,
                               registry: ProfileRegistry.load(from: madeUp))
        }
        return probe
        #else
        return AppIdentity(bundleID: bundleID, arguments: arguments, environment: environment)
        #endif
    }

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
    /// Rehearsal, a preview, and a `MOSSAD_ROOT` run have no profiles.
    public var takesProfiles: Bool { !isRehearsal && !isPreview && !onOtherRoot }
    /// Only a preview's settings are emptied at launch; a profile's are kept.
    public var emptiesSettings: Bool { isPreview }
    /// A preview's service holds nothing: the Keychain of the copy it runs as stays unread. A profile other than
    /// `default` has its own.
    public var keychainService: String {
        if isPreview { return appID + ".preview" }
        return profile.isDefault ? appID : appID + ".profile." + profile.id
    }
    /// The settings a preview or a profile reads and writes instead of the app's own. A preview has one suite for each
    /// data folder, so two previews on two folders never empty each other's. Nil for `default`.
    public var defaultsSuite: String? {
        guard isPreview else { return profile.isDefault ? nil : appID + ".profile." + profile.id }
        // FNV-1a of the folder: stable across launches, unlike `hashValue`.
        let hash = (previewRoot ?? "").utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        return appID + ".preview." + String(hash, radix: 16)
    }

    /// Why a preview must not start: it has no made-up data folder, or its folder is the real one. Nil when it may.
    public func refusal(home: URL, environment: [String: String]) -> String? {
        guard isPreview else { return profileRefusal }
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

    /// `$MOSSAD_ROOT` when set, `~/Mossad Rehearsal` for Rehearsal, else the profile's folder (`~/Mossad` for `default`).
    public func dataRoot(home: URL, environment: [String: String]) -> URL {
        if let root = environment["MOSSAD_ROOT"], !root.isEmpty { return URL(fileURLWithPath: root) }
        if isRehearsal { return home.appendingPathComponent("Mossad Rehearsal") }
        return profile.rootURL(home: home)
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

    /// A profile's own settings, untouched: never emptied, no registered defaults. Nil for `default` and a preview.
    public func profileSettings() -> UserDefaults? {
        guard !isPreview, let suite = defaultsSuite else { return nil }
        return UserDefaults(suiteName: suite)
    }

    /// In a preview or a profile other than `default`, points `UserDefaults.standard` (and `@AppStorage`) at its own
    /// settings, so nothing a page shows or saves comes from or goes to another copy's settings. The real domain is
    /// held first in `MacDefaults` for the Mac-wide keys. Call it first, before anything reads a setting. False when
    /// the settings could not be isolated: the caller must then stop.
    public func isolateDefaults() -> Bool {
        if isPreview {
            guard let defaults = previewSettings(), Self.swap(to: { _ in defaults }) else { return false }
            MacDefaults.hold(defaults)
            return UserDefaults.standard === defaults
        }
        let real = UserDefaults.standard
        MacDefaults.hold(real)
        guard let defaults = profileSettings() else { return true }
        let swap = DefaultsSwap(real: real, profile: defaults)
        guard Self.swap(to: { _ in swap.current(handingOver: MacDefaults.handingOver, isMainThread: Thread.isMainThread) }) else { return false }
        return UserDefaults.standard === defaults
    }

    private static func swap(to block: @escaping @convention(block) (AnyObject) -> UserDefaults) -> Bool {
        guard let method = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard)) else { return false }
        method_setImplementation(method, imp_implementationWithBlock(block))
        return true
    }
}

extension Keychain {
    /// The app's own keys. Every Keychain the apps use comes from here, so Rehearsal never reads the real keys.
    public static let app = Keychain(service: AppIdentity.current.keychainService)
}
