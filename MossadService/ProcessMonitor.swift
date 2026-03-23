import AppKit
import Foundation
import os.log

private let monitorLog = Logger(subsystem: "com.mossad.app", category: "ProcessMonitor")

public enum MeetingPlatform: String, Codable {
    case zoom
    case meet
    case teams
}

public struct DetectedMeeting {
    public let platform: MeetingPlatform
    public let processIdentifier: pid_t
    public let meetingUrl: String?
    public let bundleIdentifier: String?
}

public final class ProcessMonitor {
    public typealias MeetingDetectedHandler = (DetectedMeeting) -> Void
    public typealias MeetingEndedHandler = () -> Void

    private var timer: Timer?
    private var currentMeeting: DetectedMeeting?
    private var onMeetingDetected: MeetingDetectedHandler?
    private var onMeetingEnded: MeetingEndedHandler?

    private static let zoomBundleIds = ["us.zoom.xos"]
    private static let teamsBundleIds = ["com.microsoft.teams", "com.microsoft.teams2"]
    private static let meetBrowserBundleIds = [
        "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "company.thebrowser.Browser",
    ]

    public init() {}

    public func startMonitoring(onDetected: @escaping MeetingDetectedHandler, onEnded: @escaping MeetingEndedHandler) {
        self.onMeetingDetected = onDetected
        self.onMeetingEnded = onEnded
        monitorLog.notice("Starting poll timer (every 3s)")
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in self?.poll() }
        // Run immediately too
        poll()
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        currentMeeting = nil
    }

    private func poll() {
        let apps = NSWorkspace.shared.runningApplications

        // Check for Google Meet first (most reliable — URL-based detection)
        let meetUrl = detectMeetInBrowsers()
        if let meetUrl {
            monitorLog.notice("Detected Meet URL: \(meetUrl)")
            if currentMeeting?.platform != .meet {
                let browserApp = apps.first(where: { Self.meetBrowserBundleIds.contains($0.bundleIdentifier ?? "") })
                let meeting = DetectedMeeting(
                    platform: .meet,
                    processIdentifier: browserApp?.processIdentifier ?? 0,
                    meetingUrl: meetUrl,
                    bundleIdentifier: browserApp?.bundleIdentifier
                )
                currentMeeting = meeting
                onMeetingDetected?(meeting)
            }
            return
        }

        // Check for Zoom (only if it's the frontmost app — heuristic for "in a call")
        if let zoom = apps.first(where: { Self.zoomBundleIds.contains($0.bundleIdentifier ?? "") }),
           zoom.isActive {
            if currentMeeting?.platform != .zoom {
                let meeting = DetectedMeeting(platform: .zoom, processIdentifier: zoom.processIdentifier, meetingUrl: nil, bundleIdentifier: zoom.bundleIdentifier)
                currentMeeting = meeting
                onMeetingDetected?(meeting)
            }
            return
        }

        // Check for Teams (only if it's the frontmost app)
        if let teams = apps.first(where: { Self.teamsBundleIds.contains($0.bundleIdentifier ?? "") }),
           teams.isActive {
            if currentMeeting?.platform != .teams {
                let meeting = DetectedMeeting(platform: .teams, processIdentifier: teams.processIdentifier, meetingUrl: nil, bundleIdentifier: teams.bundleIdentifier)
                currentMeeting = meeting
                onMeetingDetected?(meeting)
            }
            return
        }

        // No meeting detected — if we had one, it ended
        if currentMeeting != nil {
            monitorLog.notice("Meeting ended")
            currentMeeting = nil
            onMeetingEnded?()
        }
    }

    // MARK: - Static helpers (testable)

    public static func identifyPlatform(bundleIdentifier: String, processName: String) -> MeetingPlatform? {
        if zoomBundleIds.contains(bundleIdentifier) { return .zoom }
        if teamsBundleIds.contains(bundleIdentifier) { return .teams }
        return nil
    }

    public static func extractMeetingURL(from urlString: String) -> String? {
        guard urlString.contains("meet.google.com/") else { return nil }
        return urlString
    }

    public static func extractZoomMeetingId(from urlString: String) -> String? {
        guard let range = urlString.range(of: #"zoom\.us/j/(\d+)"#, options: .regularExpression) else { return nil }
        let match = urlString[range]
        if let jRange = match.range(of: "/j/") {
            return String(match[jRange.upperBound...]).components(separatedBy: "?").first
        }
        return nil
    }

    static func processHasActiveAudio(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        guard !app.isTerminated else { return false }
        return app.isActive || app.activationPolicy == .regular
    }

    public func detectMeetInBrowsers() -> String? {
        // Only check browsers that are actually running
        let apps = NSWorkspace.shared.runningApplications
        let runningBundleIds = Set(apps.compactMap { $0.bundleIdentifier })

        if runningBundleIds.contains("com.google.Chrome") {
            if let url = queryBrowserTabs(appName: "Google Chrome") { return url }
        }
        return nil
    }

    private func queryBrowserTabs(appName: String) -> String? {
        let script = """
            tell application "\(appName)"
                repeat with w in windows
                    repeat with t in tabs of w
                        set tabURL to URL of t
                        if tabURL starts with "https://meet.google.com/" then
                            return tabURL
                        end if
                    end repeat
                end repeat
            end tell
            return missing value
            """
        guard let appleScript = NSAppleScript(source: script) else {
            monitorLog.error("Failed to create NSAppleScript for \(appName)")
            return nil
        }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error = error {
            monitorLog.error("AppleScript error for \(appName): \(error.description)")
        }
        guard error == nil, result.stringValue != nil else { return nil }
        return result.stringValue
    }

}
