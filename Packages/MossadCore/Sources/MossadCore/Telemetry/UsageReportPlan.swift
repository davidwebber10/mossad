import Foundation

/// When and how the statistics go out: at most once a day, after a random wait at launch, to one fixed address.
/// The request sets the body's type and the app's version; the session's own Accept and Accept-Language get fixed
/// values, so the owner's language list does not go. A failed send waits for the next day.
public enum UsageReportPlan {
    public static let defaultEndpoint = URL(string: "https://getmossad.com/api/telemetry")!
    /// The settings switch, on by default.
    public static let enabledKey = "usageStatsEnabled"
    public static let installIDKey = "usageStatsInstallID"
    public static let lastAttemptKey = "usageStatsLastAttempt"
    /// Hidden, for tests of the receiver: another address to send to.
    public static let endpointKey = "usageStatsEndpoint"
    /// Hidden: a debug build sends only with this set.
    public static let debugKey = "usageStatsInDebug"

    public static let interval: TimeInterval = 86_400
    public static let timeout: TimeInterval = 10

    /// Who may send. A preview, Rehearsal, a second copy, a demo folder, and a debug build never do.
    public struct Gate: Equatable, Sendable {
        public var enabled: Bool
        public var inert: Bool
        public var rehearsal: Bool
        public var rootOverride: Bool
        public var debugBuild: Bool
        public var debugFlag: Bool

        public init(enabled: Bool, inert: Bool, rehearsal: Bool, rootOverride: Bool, debugBuild: Bool, debugFlag: Bool) {
            self.enabled = enabled; self.inert = inert; self.rehearsal = rehearsal
            self.rootOverride = rootOverride; self.debugBuild = debugBuild; self.debugFlag = debugFlag
        }

        public var allows: Bool { enabled && !inert && !rehearsal && !rootOverride && (!debugBuild || debugFlag) }
    }

    /// Whether the counts can be made: the meetings and the calendar are read. Before that a count of recurring
    /// meetings would say 0 for "not read yet", which the receiver cannot tell from none, so the report waits.
    public static func inputsRead(meetings: Bool, calendar: Bool) -> Bool { meetings && calendar }

    public static func isDue(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        let since = now.timeIntervalSince(lastAttempt)
        return since >= interval || since < 0
    }

    /// From 1 to 30 minutes after launch, for `unit` from 0 to 1, so the reports of many Macs do not come together.
    public static func launchDelay(_ unit: Double) -> TimeInterval {
        60 + min(max(unit, 0), 1) * (1_800 - 60)
    }

    public static func endpoint(override: String?) -> URL {
        guard let override, let url = URL(string: override), let scheme = url.scheme, ["https", "http"].contains(scheme),
              url.host?.isEmpty == false else { return defaultEndpoint }
        return url
    }

    public static func request(body: Data, endpoint: URL, appVersion: String) -> URLRequest {
        var r = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.httpShouldHandleCookies = false
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Mossad/\(UsageStats.versionText(appVersion))", forHTTPHeaderField: "User-Agent")
        r.httpBody = body
        return r
    }

    /// The random id of this install, made once. Never from the hardware.
    public static func installID(_ defaults: UserDefaults = .standard) -> UUID {
        if let saved = defaults.string(forKey: installIDKey).flatMap(UUID.init(uuidString:)) { return saved }
        return resetInstallID(defaults)
    }

    @discardableResult
    public static func resetInstallID(_ defaults: UserDefaults = .standard) -> UUID {
        let id = UUID()
        defaults.set(id.uuidString.lowercased(), forKey: installIDKey)
        return id
    }

    public static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpAdditionalHeaders = ["Accept-Language": "en", "Accept": "*/*"]
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        return config
    }

    /// Sends one report. The log says only that it went, or the HTTP status; never the body.
    @discardableResult
    public static func send(_ stats: UsageStats, endpoint: URL, appVersion: String) async -> Bool {
        guard stats.isSendable, let body = try? stats.json() else { return false }
        let session = URLSession(configuration: sessionConfiguration())
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request(body: body, endpoint: endpoint, appVersion: appVersion))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                Log.info("Usage statistics sent")
                return true
            }
            Log.info("Usage statistics not sent: HTTP \(status)")
        } catch is CancellationError {
            Log.info("Usage statistics not sent: stopped")
        } catch let error as URLError where error.code == .cancelled {
            Log.info("Usage statistics not sent: stopped")
        } catch {
            Log.info("Usage statistics not sent: no answer")
        }
        return false
    }
}
