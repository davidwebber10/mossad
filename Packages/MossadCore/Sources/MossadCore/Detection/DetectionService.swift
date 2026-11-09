#if os(macOS)
// Call detection and capture use macOS-only APIs; the iPhone app reads meetings only.
import CoreAudio
import Foundation

/// Polls the probes, builds snapshots, and feeds the call detector.
/// Not thread-safe: `tick` runs on the service's own serial queue. The mute check runs on a queue of its own, so
/// a slow Accessibility walk never delays a tick, and a tick never delays an unmute.
public final class DetectionService: @unchecked Sendable {
    private let mic: MicUsageProbing
    private let tabs: BrowserTabProbing
    private let windows: WindowTitleProbing
    private let mute: MuteProbing?
    private let initialDetector: CallDetector
    private var detector: CallDetector
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "com.dwebber.mossad.detection", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let muteQueue = DispatchQueue(label: "com.dwebber.mossad.detection.mute", qos: .utility)
    private var muteTimer: DispatchSourceTimer?
    private var currentPlatform: Platform?
    private var lastProcesses: [AudioProcess] = []
    private var activeMeetingIDs: [String: String] = [:]
    /// Browsers whose selected tab in this tick is titled as a Teams call.
    private var startedWithCallSign: Set<String> = []
    /// During a call the tab read is the costly part of a tick (AppleScript on the main thread), and the mic
    /// already shows when the call ends; so the tabs of the call's browser are read at most this often.
    static let tabRefreshDuringCall: TimeInterval = 10
    private var tabCache: [String: (time: Date, tabs: [BrowserTab]?)] = [:]
    private var tickTime = Date()
    private var lastLogged: [String: String] = [:]
    private var watch = UnconfirmedCallWatch()
    /// Apps in this tick that use the mic like a call while no meeting can be confirmed.
    private var suspects: [UnconfirmedCall] = []
    /// The current call showed a sign that its app removes when you leave (the Teams app's call controls, a Teams
    /// web tab titled as a call), so the sign's absence later means the call is over.
    private var callSignSeen = false
    /// The current call's meeting ID from its browser tab, for matching the calendar invite.
    public private(set) var meetingID: String?

    private struct MuteTarget: Equatable {
        var call: Int
        var bundleID: String
        var platform: Platform
        var meetingID: String?
    }
    /// Guards the mute target (written by the tick) and the mute tracker (read and written by the mute check).
    private let muteLock = NSLock()
    private var muteTarget: MuteTarget?
    private var tracker = MuteTracker()
    private var trackerCall = 0
    /// Read on the mute queue only: readings with labels but no known mute button, before any known state.
    private var unknownLabelReads = 0
    private var callNumber = 0

    private let suspendLock = NSLock()
    private var suspended = false
    /// Set during an in-person recording: it owns the mic until Stop, so a tick's scan would be thrown away.
    public var isSuspended: Bool {
        get { suspendLock.withLock { suspended } }
        set { suspendLock.withLock { suspended = newValue } }
    }

    public var onEvent: (DetectorEvent) -> Void = { _ in }
    /// Called after every tick during a call with the call app's audio process IDs.
    public var onCallProcesses: ([AudioObjectID]) -> Void = { _ in }
    /// Called when the person mutes or unmutes in the call app, during a call. Runs on the mute queue. A "muted" that
    /// cannot be read again for `MuteTracker.unknownLimit` reports unmuted; `lastMutedSeen` then tells when it was
    /// last seen.
    public var onMuteChange: (Bool) -> Void = { _ in }
    /// Called once per mic session when an app seems to be in a call that Mossad cannot confirm, so nothing records.
    public var onUnconfirmed: (UnconfirmedCall) -> Void = { _ in }

    public init(mic: MicUsageProbing, tabs: BrowserTabProbing, windows: WindowTitleProbing, mute: MuteProbing? = nil,
                detector: CallDetector = CallDetector(), tick: TimeInterval = 2) {
        self.mic = mic
        self.tabs = tabs
        self.windows = windows
        self.mute = mute
        self.initialDetector = detector
        self.detector = detector
        self.interval = tick
    }

    /// Core Audio process objects of the current call's app, including helpers.
    public var audioProcessIDs: [AudioObjectID] {
        guard let bundleID = detector.currentBundleID else { return [] }
        return lastProcesses.filter { Self.groupID(for: $0.bundleID) == bundleID }.map(\.objectID)
    }

    /// The last mute reading that still saw "muted" in the current call.
    public var lastMutedSeen: Date? { muteLock.withLock { tracker.lastMutedSeen } }

    public func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick(at: Date()) }
        timer.resume()
        self.timer = timer
        let muteTimer = DispatchSource.makeTimerSource(queue: muteQueue)
        muteTimer.schedule(deadline: .now() + 1, repeating: MuteTracker.mutedCheckInterval, leeway: .milliseconds(100))
        muteTimer.setEventHandler { [weak self] in self?.checkMute(at: Date()) }
        muteTimer.resume()
        self.muteTimer = muteTimer
    }

    /// Stops the ticks and forgets the call: a call still open when detection starts again is a new call.
    public func stop() {
        timer?.cancel()
        timer = nil
        muteTimer?.cancel()
        muteTimer = nil
        queue.async { [weak self] in self?.reset() }
    }

    /// Forgets the detector's call, the mute state, the tab cache, and the warning sessions. Runs on the detection
    /// queue, so no tick sees half of it.
    func reset() {
        detector = initialDetector
        currentPlatform = nil
        meetingID = nil
        lastProcesses = []
        activeMeetingIDs = [:]
        startedWithCallSign = []
        tabCache = [:]
        suspects = []
        callSignSeen = false
        lastLogged = [:]
        watch.reset()
        muteLock.withLock {
            muteTarget = nil
            tracker = MuteTracker()
        }
    }

    public func tick(at time: Date) {
        guard !isSuspended else { return }
        let snapshot = snapshot(at: time)
        if let event = detector.process(snapshot) {
            switch event {
            case .started(let platform, let bundleID, _):
                currentPlatform = platform
                meetingID = activeMeetingIDs[bundleID]
                callSignSeen = startedWithCallSign.contains(bundleID)
            case .ended:
                currentPlatform = nil
                meetingID = nil
                callSignSeen = false
                muteLock.withLock { muteTarget = nil }
            }
            onEvent(event)
            // After the event, so a mute change never reaches the recorder before its call does.
            if case .started(let platform, let bundleID, _) = event { watchMute(bundleID: bundleID, platform: platform) }
        }
        if let warning = watch.update(at: time, suspects: suspects, inCall: detector.isInCall) {
            Log.info("\(warning.bundleID) uses the mic, but Mossad cannot confirm a meeting (\(warning.reason.rawValue)); asking the owner")
            onUnconfirmed(warning)
        }
        if detector.isInCall {
            onCallProcesses(audioProcessIDs)
        }
    }

    private func watchMute(bundleID: String, platform: Platform) {
        callNumber += 1
        let target = MuteTarget(call: callNumber, bundleID: bundleID, platform: platform, meetingID: meetingID)
        muteLock.withLock { muteTarget = target }
    }

    /// Starts recording the app now, for the owner's Record on a warning. Runs on the detection queue.
    public func forceStart(bundleID: String, platform: Platform) {
        queue.async { [weak self] in self?.forceStartNow(bundleID: bundleID, platform: platform, at: Date()) }
    }

    func forceStartNow(bundleID: String, platform: Platform, at time: Date) {
        guard !isSuspended else { return }
        // A warning can be answered long after it came; an app that no longer uses the mic is not in a call.
        guard mic.processes().contains(where: { $0.isRunningInput && Self.groupID(for: $0.bundleID) == bundleID }) else {
            Log.info("Not recording \(bundleID): it no longer uses the mic")
            return
        }
        guard let event = detector.force(platform: platform, bundleID: bundleID, at: time) else { return }
        Log.info("The owner chose to record \(bundleID) as \(platform.displayName)")
        currentPlatform = platform
        meetingID = nil
        callSignSeen = false
        onEvent(event)
        watchMute(bundleID: bundleID, platform: platform)
    }

    /// "Not a call": no more warnings for this app and reason until a time.
    public func dismissUnconfirmed(_ call: UnconfirmedCall, until: Date) {
        queue.async { [weak self] in self?.watch.dismiss(call, until: until) }
    }

    public func snapshot(at time: Date) -> DetectionSnapshot {
        tickTime = time
        suspects = []
        let processes = mic.processes()
        lastProcesses = processes
        activeMeetingIDs = [:]
        startedWithCallSign = []
        var micByApp: [String: Bool] = [:]
        var order: [String] = []
        for p in processes {
            guard let group = Self.groupID(for: p.bundleID) else { continue }
            if micByApp[group] == nil { order.append(group) }
            micByApp[group] = (micByApp[group] ?? false) || p.isRunningInput
        }

        let current = detector.currentBundleID
        // Every WebKit app plays and records through the shared WebKit GPU process, which counts as Safari's.
        // Without Safari running it is another app's, and not a call Mossad knows.
        let safari = MeetingMatcher.safariBundleID
        if micByApp[safari] != nil, current != safari, !windows.isRunning(bundleID: safari) {
            micByApp[safari] = nil
            order.removeAll { $0 == safari }
        }
        // An app can drop out of the Core Audio list during an audio reset; while it still runs, keep it as a candidate.
        if let current, !order.contains(current), windows.isRunning(bundleID: current) {
            order.append(current)
        }
        // The Zoom app's meeting window alone is a call, also while Zoom has released the mic (the owner is muted).
        let zoom = MeetingMatcher.zoomBundleID
        if !order.contains(zoom), windows.isRunning(bundleID: zoom) { order.append(zoom) }
        let candidates = order.compactMap { group -> MeetingCandidate? in
            let micActive = micByApp[group] ?? false
            guard micActive || group == current || group == zoom else { return nil }
            return candidate(group: group, micActive: micActive, isCurrent: group == current)
        }
        if current != nil, let c = candidates.first(where: { $0.bundleID == current }) {
            logChange("tick", "tick \(c.bundleID) mic=\(c.micActive) present=\(String(describing: c.meetingPresent))")
        }
        return DetectionSnapshot(time: time, candidates: candidates)
    }

    private func candidate(group: String, micActive: Bool, isCurrent: Bool) -> MeetingCandidate? {
        switch MeetingMatcher.appKind(bundleID: group) {
        case .zoomApp:
            let titles = windows.windowTitles(bundleID: group)
            if isCurrent, let titles { logChange("zoom", "zoom windows: \(titles)") }
            let meeting = titles.map { $0.contains(where: MeetingMatcher.zoomWindowIsMeeting) }
            var present = meeting
            // During a call with the mic on, a window set without "Zoom Meeting" (a screen share's toolbar, Zoom in
            // another language) is unknown, not gone. Leaving releases the mic, which makes it gone.
            if isCurrent, micActive, meeting == false { present = nil }
            if micActive, !isCurrent, meeting == false {
                suspects.append(UnconfirmedCall(bundleID: group, platform: .zoom, reason: .noMeetingWindow))
            }
            return MeetingCandidate(platform: .zoom, bundleID: group, micActive: micActive, meetingPresent: present,
                                    presenceIsSure: meeting == true)
        case .teamsApp:
            let titles = windows.windowTitles(bundleID: group)
            if isCurrent, let titles { logChange("teams", "teams windows: \(titles)") }
            // Teams meeting-window titles are not reliable yet: a match means present, anything else is unknown.
            let titleSaysMeeting = titles?.contains(where: MeetingMatcher.teamsWindowIsMeeting) == true
            var present: Bool? = titleSaysMeeting ? true : nil
            var sure = false
            // During the call, its mute button ("Mute mic", "Unmute mic") is there for the whole meeting and gone
            // once you leave. Gone counts only after the controls were seen in this call (so a Teams in another
            // language, whose labels never match, stays unknown) and with the mic released too.
            if isCurrent, let labels = mute?.labels(bundleID: group, platform: .teams, meetingID: nil) {
                let controls = labels.contains { let l = $0.lowercased(); return l.hasPrefix("mute") || l.hasPrefix("unmute") }
                if controls {
                    present = true
                    sure = true
                    callSignSeen = true
                } else if !micActive, callSignSeen, !titleSaysMeeting {
                    present = false
                }
                logChange("teams-controls", "teams controls: \(controls)")
            }
            return MeetingCandidate(platform: .teams, bundleID: group, micActive: micActive, meetingPresent: present, presenceIsSure: sure)
        case .browser:
            return browserCandidate(group: group, micActive: micActive, isCurrent: isCurrent)
        case .unreadableBrowser:
            // Its tabs cannot be read: it never starts a call by itself, and during a forced call it is unknown.
            if isCurrent, let platform = currentPlatform {
                return MeetingCandidate(platform: platform, bundleID: group, micActive: micActive, meetingPresent: nil)
            }
            if micActive { suspects.append(UnconfirmedCall(bundleID: group, platform: nil, reason: .cannotSeeMeeting)) }
            return nil
        case nil:
            return nil
        }
    }

    private func browserCandidate(group: String, micActive: Bool, isCurrent: Bool) -> MeetingCandidate? {
        guard let list = readTabs(group, isCurrent: isCurrent) else {
            // The window titles of the copies of the browser that answer can still show a Meet call (Accessibility).
            if !isCurrent || currentPlatform == .meet,
               windows.answeredWindowTitles(bundleID: group)?.contains(where: MeetingMatcher.meetWindowIsMeeting) == true {
                return MeetingCandidate(platform: .meet, bundleID: group, micActive: micActive, meetingPresent: true)
            }
            // Otherwise unreadable tabs never start a call; during a call they count as unknown.
            guard isCurrent, let platform = currentPlatform else {
                if micActive {
                    let reason: UnconfirmedCall.Reason = tabs.automationDenied(browserBundleID: group) ? .noAutomation : .cannotSeeMeeting
                    suspects.append(UnconfirmedCall(bundleID: group, platform: nil, reason: reason))
                }
                return nil
            }
            return MeetingCandidate(platform: platform, bundleID: group, micActive: micActive, meetingPresent: nil)
        }
        let meetingTabs = list.compactMap { tab -> (Platform, BrowserTab)? in
            guard let platform = MeetingMatcher.platform(forTabURL: tab.url) else { return nil }
            if platform == .meet, MeetingMatcher.meetTabLeftMeeting(title: tab.title) { return nil }
            return (platform, tab)
        }
        if isCurrent { logChange("tabs", "browser tabs: \(list.filter { MeetingMatcher.platform(forTabURL: $0.url) != nil }.map(\.title))") }
        if let platform = isCurrent ? currentPlatform : nil {
            var present = meetingTabs.contains { $0.0 == platform }
            // Every Teams page counts as a Teams tab, so the tab alone cannot show that a call ended. Once a tab
            // titled as a call was seen, its absence ends the call; otherwise the old rule (any Teams tab) holds.
            if platform == .teams {
                if list.contains(where: MeetingMatcher.teamsTabIsMeeting) { callSignSeen = true } else if callSignSeen { present = false }
            }
            // Only a list that shows the call is used again from the cache: a "gone" answer is read again at once,
            // so one wrong answer cannot count for several ticks.
            if !present { tabCache[group] = nil }
            return MeetingCandidate(platform: platform, bundleID: group, micActive: micActive, meetingPresent: present)
        }
        // To start a call the meeting tab must be the selected tab: a pinned background Teams or Meet tab
        // must not turn dictation or another site's mic use into a call.
        guard let first = meetingTabs.first(where: { $0.1.isActive }) else {
            if micActive, let background = meetingTabs.first {
                suspects.append(UnconfirmedCall(bundleID: group, platform: background.0, reason: .meetingTabNotSelected))
            }
            return nil
        }
        activeMeetingIDs[group] = MeetingMatcher.meetingID(forTabURL: first.1.url)
        if MeetingMatcher.teamsTabIsMeeting(first.1) { startedWithCallSign.insert(group) }
        return MeetingCandidate(platform: first.0, bundleID: group, micActive: micActive, meetingPresent: true)
    }

    /// Reads the owner's mute state for the current call, at most every 3 s, or every 1 s while muted. Runs on the
    /// mute queue; the timer fires each second.
    func checkMute(at time: Date) {
        guard let mute, !isSuspended else { return }
        var fresh = false
        let target: MuteTarget? = muteLock.withLock {
            let target = muteTarget
            if let target, target.call != trackerCall {
                tracker = MuteTracker()
                trackerCall = target.call
                fresh = true
            }
            return target
        }
        if fresh { unknownLabelReads = 0 }
        guard let target, muteLock.withLock({ tracker.isDue(at: time) }) else { return }
        let labels = mute.labels(bundleID: target.bundleID, platform: target.platform, meetingID: target.meetingID)
        let state = labels.flatMap { MuteState.from(labels: $0, platform: target.platform) }
        let change: Bool? = muteLock.withLock {
            // The call ended or changed during the read: its answer belongs to no call.
            guard muteTarget?.call == target.call else { return nil }
            return tracker.record(state, at: time)
        }
        if let labels, state == nil, muteLock.withLock({ tracker.muted == nil }) {
            unknownLabelReads += 1
            if unknownLabelReads == 5 {
                Log.info("No known mute button in \(target.bundleID) (\(labels.count) labels); mute detection is off for this call")
            }
        } else if state != nil {
            unknownLabelReads = 0
        }
        guard let change else { return }
        if state == nil { Log.info("The mute state could not be read for \(Int(MuteTracker.unknownLimit)) s; recording the mic as unmuted") }
        onMuteChange(change)
    }

    private func readTabs(_ group: String, isCurrent: Bool) -> [BrowserTab]? {
        if isCurrent, let cached = tabCache[group], tickTime.timeIntervalSince(cached.time) < Self.tabRefreshDuringCall {
            return cached.tabs
        }
        let list = tabs.tabs(browserBundleID: group)
        tabCache[group] = (tickTime, list)
        return list
    }

    /// Debug lines only when they change, so a long call does not write one line every tick.
    private func logChange(_ key: String, _ message: String) {
        guard lastLogged[key] != message else { return }
        lastLogged[key] = message
        Log.debug(message)
    }

    /// The app a process belongs to: the browser for browser helpers, the app ID for Zoom and Teams.
    static func groupID(for bundleID: String) -> String? {
        switch MeetingMatcher.appKind(bundleID: bundleID) {
        case .zoomApp: MeetingMatcher.zoomBundleID
        case .teamsApp: MeetingMatcher.teamsBundleID
        case .browser(let base), .unreadableBrowser(let base): base
        case nil: nil
        }
    }
}
#endif
