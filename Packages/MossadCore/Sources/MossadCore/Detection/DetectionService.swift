import CoreAudio
import Foundation

/// Polls the probes, builds snapshots, and feeds the call detector.
/// Not thread-safe: `tick` runs on the service's own serial queue.
public final class DetectionService: @unchecked Sendable {
    private let mic: MicUsageProbing
    private let tabs: BrowserTabProbing
    private let windows: WindowTitleProbing
    private var detector: CallDetector
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "com.dwebber.mossad.detection", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var currentPlatform: Platform?
    private var lastProcesses: [AudioProcess] = []

    public var onEvent: (DetectorEvent) -> Void = { _ in }

    public init(mic: MicUsageProbing, tabs: BrowserTabProbing, windows: WindowTitleProbing,
                detector: CallDetector = CallDetector(), tick: TimeInterval = 2) {
        self.mic = mic
        self.tabs = tabs
        self.windows = windows
        self.detector = detector
        self.interval = tick
    }

    /// Core Audio process objects of the current call's app, including helpers.
    public var audioProcessIDs: [AudioObjectID] {
        guard let bundleID = detector.currentBundleID else { return [] }
        return lastProcesses.filter { Self.groupID(for: $0.bundleID) == bundleID }.map(\.objectID)
    }

    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick(at: Date()) }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func tick(at time: Date) {
        let snapshot = snapshot(at: time)
        guard let event = detector.process(snapshot) else { return }
        switch event {
        case .started(let platform, _, _): currentPlatform = platform
        case .ended: currentPlatform = nil
        }
        onEvent(event)
    }

    public func snapshot(at time: Date) -> DetectionSnapshot {
        let processes = mic.processes()
        lastProcesses = processes
        var micByApp: [String: Bool] = [:]
        var order: [String] = []
        for p in processes {
            guard let group = Self.groupID(for: p.bundleID) else { continue }
            if micByApp[group] == nil { order.append(group) }
            micByApp[group] = (micByApp[group] ?? false) || p.isRunningInput
        }

        let current = detector.currentBundleID
        let candidates = order.compactMap { group -> MeetingCandidate? in
            let micActive = micByApp[group] ?? false
            guard micActive || group == current else { return nil }
            return candidate(group: group, micActive: micActive, isCurrent: group == current)
        }
        if current != nil, let c = candidates.first(where: { $0.bundleID == current }) {
            Log.debug("tick \(c.bundleID) mic=\(c.micActive) present=\(String(describing: c.meetingPresent))")
        }
        return DetectionSnapshot(time: time, candidates: candidates)
    }

    private func candidate(group: String, micActive: Bool, isCurrent: Bool) -> MeetingCandidate? {
        switch MeetingMatcher.appKind(bundleID: group) {
        case .zoomApp:
            let titles = windows.windowTitles(bundleID: group)
            if isCurrent, let titles { Log.debug("zoom windows: \(titles)") }
            let present = titles.map { $0.contains(where: MeetingMatcher.zoomWindowIsMeeting) }
            return MeetingCandidate(platform: .zoom, bundleID: group, micActive: micActive, meetingPresent: present)
        case .teamsApp:
            let titles = windows.windowTitles(bundleID: group)
            if isCurrent, let titles { Log.debug("teams windows: \(titles)") }
            // Teams meeting-window titles are not reliable yet: a match means present, anything else is unknown.
            let present: Bool? = titles?.contains(where: MeetingMatcher.teamsWindowIsMeeting) == true ? true : nil
            return MeetingCandidate(platform: .teams, bundleID: group, micActive: micActive, meetingPresent: present)
        case .browser:
            return browserCandidate(group: group, micActive: micActive, isCurrent: isCurrent)
        case nil:
            return nil
        }
    }

    private func browserCandidate(group: String, micActive: Bool, isCurrent: Bool) -> MeetingCandidate? {
        guard let list = tabs.tabs(browserBundleID: group) else {
            // Unreadable tabs never start a call; during a call they count as unknown.
            guard isCurrent, let platform = currentPlatform else { return nil }
            return MeetingCandidate(platform: platform, bundleID: group, micActive: micActive, meetingPresent: nil)
        }
        let meetingTabs = list.compactMap { tab -> (Platform, BrowserTab)? in
            guard let platform = MeetingMatcher.platform(forTabURL: tab.url) else { return nil }
            if platform == .meet, MeetingMatcher.meetTabLeftMeeting(title: tab.title) { return nil }
            return (platform, tab)
        }
        if isCurrent { Log.debug("browser tabs: \(list.filter { MeetingMatcher.platform(forTabURL: $0.url) != nil }.map(\.title))") }
        if let platform = isCurrent ? currentPlatform : nil {
            let present = meetingTabs.contains { $0.0 == platform }
            return MeetingCandidate(platform: platform, bundleID: group, micActive: micActive, meetingPresent: present)
        }
        guard let first = meetingTabs.first else { return nil }
        return MeetingCandidate(platform: first.0, bundleID: group, micActive: micActive, meetingPresent: true)
    }

    /// The app a process belongs to: the browser for browser helpers, the app ID for Zoom and Teams.
    static func groupID(for bundleID: String) -> String? {
        switch MeetingMatcher.appKind(bundleID: bundleID) {
        case .zoomApp: MeetingMatcher.zoomBundleID
        case .teamsApp: MeetingMatcher.teamsBundleID
        case .browser(let base): base
        case nil: nil
        }
    }
}
