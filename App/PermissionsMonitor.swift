import AppKit
import ApplicationServices
import AVFoundation
import EventKit
import MossadCore
import UserNotifications

/// Reads the state of every permission Mossad needs, and fixes one on a click.
@MainActor
final class PermissionsMonitor: ObservableObject {
    struct Item: Identifiable {
        let kind: PermissionKind
        let title: String
        let reason: String
        var state: PermissionState
        var id: PermissionKind { kind }
    }

    @Published private(set) var items: [Item] = []
    private var timer: Timer?
    private let dragHelper = DragHelper()

    var allGood: Bool { items.allSatisfy { $0.state.isGood } }

    init() {
        items = Self.baseItems()
        refresh()
        // A slow check in the background; the Settings view asks for fast checks while it is open.
        setInterval(10)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func setInterval(_ seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let kinds = items.map(\.kind)
        Task.detached(priority: .utility) {
            var states: [PermissionKind: PermissionState] = [:]
            for kind in kinds { states[kind] = await Self.check(kind) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for i in self.items.indices { self.items[i].state = states[self.items[i].kind] ?? self.items[i].state }
                self.dragHelper.closeIfGranted(states)
            }
        }
    }

    // MARK: Checks

    private static func baseItems() -> [Item] {
        var items = [
            Item(kind: .microphone, title: "Microphone", reason: "Records your side of the call.", state: .notAsked),
            Item(kind: .systemAudio, title: "System Audio Recording", reason: "Records the other people on the call.", state: .notAsked),
            Item(kind: .accessibility, title: "Accessibility", reason: "Reads Zoom and Teams window titles to see when a call starts and ends.", state: .notAsked),
            Item(kind: .calendars, title: "Calendars", reason: "Names each meeting and its attendees from your calendar.", state: .notAsked),
            Item(kind: .notifications, title: "Notifications", reason: "Tells you when a call has new voices to name.", state: .notAsked),
        ]
        for id in MeetingMatcher.browserBundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            items.append(Item(kind: .automation(id), title: "Automation: \(name)",
                              reason: "Reads the \(name) tab address to detect browser calls.", state: .notAsked))
        }
        return items
    }

    nonisolated private static func check(_ kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .systemAudio:
            return Permissions.tccState(preflight: TCC.preflight("kTCCServiceAudioCapture"))
        case .accessibility:
            // macOS does not tell "not asked" from "denied" here; both need the Settings list.
            return AXIsProcessTrusted() ? .granted : .denied
        case .calendars:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .notifications:
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .automation(let bundleID):
            return Permissions.automationState(osStatus: automationStatus(bundleID, ask: false))
        }
    }

    nonisolated private static func automationStatus(_ bundleID: String, ask: Bool) -> Int32 {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return -600 }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
    }

    // MARK: Fixes

    func fix(_ item: Item) {
        let kind = item.kind
        switch (kind, item.state) {
        case (_, .granted):
            return
        case (.microphone, .notAsked):
            AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in self.refresh() } }
        case (.systemAudio, .notAsked):
            TCC.request("kTCCServiceAudioCapture") { Task { @MainActor in self.refresh() } }
        case (.calendars, .notAsked):
            Task {
                _ = try? await EKEventStore().requestFullAccessToEvents()
                refresh()
            }
        case (.notifications, .notAsked):
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
                refresh()
            }
        case (.automation(let id), .needsApp):
            // macOS can ask about a browser only while it runs.
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    _ = Self.automationStatus(id, ask: true)
                    Task { @MainActor in self.refresh() }
                }
            }
        case (.automation(let id), .notAsked):
            // The prompt waits for an answer, so ask off the main thread.
            DispatchQueue.global().async {
                _ = Self.automationStatus(id, ask: true)
                Task { @MainActor in self.refresh() }
            }
        default:
            NSWorkspace.shared.open(kind.settingsURL)
            if kind.acceptsDraggedApp { dragHelper.show(for: kind, title: item.title) }
        }
    }
}

/// The private TCC calls that read and request System Audio Recording. macOS has no public API for this permission.
private enum TCC {
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    nonisolated(unsafe) private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static func preflight(_ service: String) -> Int? {
        guard let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFn.self)(service as CFString, nil)
    }

    static func request(_ service: String, done: @escaping @Sendable () -> Void) {
        guard let sym = dlsym(handle, "TCCAccessRequest") else { return done() }
        unsafeBitCast(sym, to: RequestFn.self)(service as CFString, nil) { _ in done() }
    }
}
