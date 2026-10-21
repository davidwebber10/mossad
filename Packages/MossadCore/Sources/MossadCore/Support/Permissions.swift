import CoreGraphics
import Foundation

public enum PermissionState: Equatable, Sendable {
    case granted, denied, notAsked
    /// Automation only: macOS can check a browser only while it runs.
    case needsApp

    public var isGood: Bool { self == .granted }
}

public enum PermissionKind: Hashable, Sendable {
    case microphone, systemAudio, accessibility, calendars, notifications
    case automation(String)

    static let appBundleID = "com.dwebber.mossad"

    /// Privacy lists with a "+" button also take an app dropped from Finder.
    public var acceptsDraggedApp: Bool {
        switch self {
        case .systemAudio, .accessibility: true
        default: false
        }
    }

    public var settingsURL: URL {
        let security = "x-apple.systempreferences:com.apple.preference.security?"
        let s = switch self {
        case .microphone: security + "Privacy_Microphone"
        case .systemAudio: security + "Privacy_ScreenCapture"
        case .accessibility: security + "Privacy_Accessibility"
        case .calendars: security + "Privacy_Calendars"
        case .automation: security + "Privacy_Automation"
        case .notifications: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Self.appBundleID)"
        }
        return URL(string: s)!
    }
}

public enum Permissions {
    /// Maps the result of AEDeterminePermissionToAutomateTarget.
    public static func automationState(osStatus: Int32) -> PermissionState {
        switch osStatus {
        case 0: .granted
        case -1743: .denied        // errAEEventNotPermitted
        case -600: .needsApp       // procNotFound
        default: .notAsked         // errAEEventWouldRequireUserConsent and others
        }
    }

    /// macOS can check a browser only while it runs. A closed browser keeps the last state that was seen.
    public static func resolve(_ state: PermissionState, lastKnown: PermissionState?) -> PermissionState {
        state == .needsApp ? (lastKnown ?? .needsApp) : state
    }

    /// Maps TCCAccessPreflight: 0 granted, 1 denied, anything else not asked yet.
    public static func tccState(preflight: Int?) -> PermissionState {
        switch preflight {
        case 0: .granted
        case 1: .denied
        default: .notAsked
        }
    }

    /// The AppKit frame for the drag helper: centered under the System Settings window, kept on screen.
    /// `settingsWindow` is a CGWindow bound (top-left origin of the primary screen).
    public static func helperFrame(settingsWindow: CGRect, primaryScreenHeight: CGFloat, visible: CGRect, size: CGSize) -> CGRect {
        let windowBottom = primaryScreenHeight - settingsWindow.maxY
        var f = CGRect(x: settingsWindow.midX - size.width / 2, y: windowBottom - 8 - size.height,
                       width: size.width, height: size.height)
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - size.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - size.height)
        return f
    }
}
