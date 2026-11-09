#if os(macOS)
// Call detection and capture use macOS-only APIs; the iPhone app reads meetings only.
import AppKit
import ApplicationServices

/// When a full walk of the call app's Accessibility tree is allowed. A walk asks the app for up to thousands of
/// elements, which the app answers on its interface thread during the call. A walk whose controls can then be read
/// from the cache is worth its cost; walks that follow each other with no cached read between them are not, so
/// they are spaced further and further apart. A change of the app's windows starts the count again.
struct WalkBackoff: Equatable, Sendable {
    /// The wait after 1, 2, 3, and more walks in a row. At the last step mute detection is as good as off.
    static let waits: [TimeInterval] = [3, 10, 30, 60]

    private(set) var walks = 0
    private(set) var lastWalk: Date?

    func mayWalk(at time: Date) -> Bool {
        guard walks > 0, let lastWalk else { return true }
        // A little slack, so a 3 s check that fires a few milliseconds early still walks.
        return time.timeIntervalSince(lastWalk) >= Self.waits[min(walks, Self.waits.count) - 1] - 0.1
    }

    /// True once the walks are at the slowest step.
    var isOff: Bool { walks >= Self.waits.count }

    mutating func walked(at time: Date) {
        walks += 1
        lastWalk = time
    }

    /// The cached controls answered: the last walk paid off.
    mutating func cacheHeld() { walks = 0 }
}

/// Reads mute-button labels from the call app through Accessibility (the permission Mossad already has).
/// Chrome exposes the Meet page's buttons this way, and Zoom and Teams their own controls and menus.
public final class AccessibilityMuteProbe: MuteProbing, @unchecked Sendable {
    static let elementLimit = 4_000
    /// A walk that takes longer than this is cut, and its answer is unknown.
    static let walkBudget: TimeInterval = 1

    private struct Entry {
        var key: String
        /// The mute controls found by the last walk, also when the walk was cut: reading them is a few requests.
        var elements: [AXUIElement] = []
        var backoff = WalkBackoff()
        var windows: [String] = []
    }
    /// Per app. Two apps can be read in turn (a Meet call's mute check and the idle Teams check).
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let now: @Sendable () -> Date

    public convenience init() { self.init(now: { Date() }) }

    init(now: @escaping @Sendable () -> Date) {
        self.now = now
        AccessibilityTimeout.apply()
    }

    public func labels(bundleID: String, platform: Platform, meetingID: String?) -> [String]? {
        guard AXIsProcessTrusted() else { return nil }
        // Every copy of the app: a second, hidden copy of Chrome (a test tool's) has the same ID.
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
        guard !pids.isEmpty else { return nil }
        let key = "\(bundleID)|\(meetingID ?? "")|\(pids.sorted())"
        if let labels = cachedLabels(bundleID: bundleID, key: key) { return labels }

        let isBrowser: Bool = switch MeetingMatcher.appKind(bundleID: bundleID) {
        case .browser, .unreadableBrowser: true
        default: false
        }
        var menus: [AXUIElement] = []
        var roots: [AXUIElement] = []
        var allTitles: [String] = []
        var anyCopyFailed = false
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Float(Self.walkBudget))
            var value: AnyObject?
            let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            guard result == .success || result == .noValue else {
                anyCopyFailed = true
                continue
            }
            let windows = (value as? [AXUIElement]) ?? []
            let titles = windows.map { (attribute($0, kAXTitleAttribute) as? String) ?? "" }
            if isBrowser {
                // Only the call's windows count as a change: the owner's other browser windows change all the time.
                let call = Self.callWindows(titles: titles, platform: platform, meetingID: meetingID)
                roots += call.map { windows[$0] }
                allTitles += call.map { titles[$0] }
            } else {
                allTitles += titles
                roots += windows
                // Zoom and Teams also name the action in their menus.
                if let menu = attribute(app, kAXMenuBarAttribute) { menus.append(menu as! AXUIElement) }
            }
        }
        // No window of the call: unknown, never "the controls are gone".
        guard !roots.isEmpty || !menus.isEmpty else { return nil }

        let time = now()
        let allowed: Bool = lock.withLock {
            var entry = entries[bundleID] ?? Entry(key: key)
            // A new call, a new copy of the app, or a change of its windows (the owner came back to the call's tab,
            // the meeting window opened or closed): the tree is worth a new look at once.
            if entry.key != key || entry.windows != allTitles { entry = Entry(key: key, windows: allTitles) }
            let allowed = entry.backoff.mayWalk(at: time)
            if allowed {
                entry.backoff.walked(at: time)
                if entry.backoff.walks == WalkBackoff.waits.count {
                    Log.info("The mute controls of \(bundleID) do not stay readable; looking for them only every \(Int(WalkBackoff.waits.last ?? 60)) s")
                }
            }
            entries[bundleID] = entry
            return allowed
        }
        // Not now: unknown. A mute that cannot be read again turns into unmuted after its limit, so nothing is lost.
        guard allowed else { return nil }

        var found: [String] = []
        var elements: [AXUIElement] = []
        var visited = 0
        var cut = false
        let deadline = Date().addingTimeInterval(Self.walkBudget)
        func read(_ e: AXUIElement, _ name: String) -> AnyObject? {
            var value: AnyObject?
            switch AXUIElementCopyAttributeValue(e, name as CFString, &value) {
            case .success: return value
            case .noValue, .attributeUnsupported, .invalidUIElement, .notImplemented: return nil
            default:
                cut = true  // The app did not answer: what was not read is unknown.
                return nil
            }
        }
        func walk(_ e: AXUIElement, depth: Int) {
            guard !cut else { return }
            visited += 1
            guard visited < Self.elementLimit, Date() < deadline else {
                cut = true
                return
            }
            guard depth < 40 else { return }
            let role = read(e, kAXRoleAttribute) as? String ?? ""
            if role == kAXButtonRole || role == kAXCheckBoxRole || role == kAXMenuItemRole {
                for name in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let text = read(e, name) as? String, !text.isEmpty {
                        let lower = text.lowercased()
                        if lower.contains("mute") || lower.contains("microphone") {
                            found.append(text)
                            if elements.last.map({ !CFEqual($0, e) }) ?? true { elements.append(e) }
                        }
                    }
                }
            }
            for child in (read(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth: depth + 1) }
        }
        // The menu bar first: it is small, and when it names the mute state the windows (the large part: video
        // tiles, chat, the participant list) are not walked at all.
        menus.forEach { walk($0, depth: 0) }
        if cut || MuteState.from(labels: found, platform: platform) == nil {
            roots.forEach { walk($0, depth: 0) }
        }
        // The controls a cut walk found are kept too: reading them again is cheap, and a tree too large to walk
        // in time would otherwise be walked again at every check.
        lock.withLock {
            if entries[bundleID]?.key == key { entries[bundleID]?.elements = elements }
        }
        // A cut walk, or a copy that did not answer, still proves the labels it found, but not their absence.
        if found.isEmpty, cut || anyCopyFailed { return nil }
        return found
    }

    /// The browser windows that can hold the current call's controls. A window whose title shows the meeting code
    /// wins, so a second meeting's waiting page in another window does not count. Without it, every window that
    /// looks like the call app counts, including Meet's picture-in-picture window.
    static func callWindows(titles: [String], platform: Platform, meetingID: String?) -> [Int] {
        let matches = titles.indices.filter { i in
            let title = titles[i]
            switch platform {
            case .meet: return MeetingMatcher.meetWindowIsMeeting(title) || title.lowercased().contains("meet.google.com")
            case .zoom: return title.contains("Zoom")
            case .teams: return title.contains("Teams")
            case .inPerson: return false
            }
        }
        if let meetingID, !meetingID.isEmpty {
            let own = matches.filter { titles[$0].lowercased().contains(meetingID.lowercased()) }
            if !own.isEmpty { return own }
        }
        return matches
    }

    /// The labels of the cached controls, or nil when any of them is gone or no longer names the microphone,
    /// so the caller looks at the tree again.
    private func cachedLabels(bundleID: String, key: String) -> [String]? {
        guard let cached = lock.withLock({ entries[bundleID] }), cached.key == key, !cached.elements.isEmpty else { return nil }
        var labels: [String] = []
        for e in cached.elements {
            AXUIElementSetMessagingTimeout(e, Float(Self.walkBudget))
            var any = false
            for name in [kAXTitleAttribute, kAXDescriptionAttribute] {
                var value: AnyObject?
                let result = AXUIElementCopyAttributeValue(e, name as CFString, &value)
                if result == .invalidUIElement || result == .cannotComplete { return invalidate(bundleID) }
                if let text = value as? String, !text.isEmpty {
                    let lower = text.lowercased()
                    if lower.contains("mute") || lower.contains("microphone") { labels.append(text); any = true }
                }
            }
            if !any { return invalidate(bundleID) }
        }
        lock.withLock { entries[bundleID]?.backoff.cacheHeld() }
        return labels
    }

    private func invalidate(_ bundleID: String) -> [String]? {
        lock.withLock { entries[bundleID]?.elements = [] }
        return nil
    }

    private func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }
}
#endif
