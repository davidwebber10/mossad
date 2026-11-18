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
    static let tickLeewayMilliseconds = 300
    /// The last known mic and sound state of each app: a state that cannot be read keeps its last known value.
    private var lastMic: [String: Bool] = [:]
    private var lastOutput: [String: Bool] = [:]
    private var activeMeetingIDs: [String: String] = [:]
    /// During a call the tab read is the costly part of a tick (AppleScript on the main thread), and the mic
    /// already shows when the call ends; so the tabs of the call's browser are read at most this often.
    static let tabRefreshDuringCall: TimeInterval = 10
    private var tabCache: [String: (time: Date, tabs: [BrowserTab]?)] = [:]
    /// The browser call's own link against each new tab list, and its windows' Meet title against each reading: a
    /// change is a mark in the recording (`DetectorEvent.marked`), never an end or a start.
    private var linkWatch = CallLinkWatch(link: nil)
    private var titleWatch = CallTitleWatch()
    /// The last sure mark of this call: a title change near it is the same change.
    private var lastSureMark: Date?
    /// A title change waits 10 s (`CallTitleWatch.readingGap`), and while a link change waits, for a sure mark of the
    /// same change, which replaces it, or a return to the title before it, which drops it; then it is a mark that is
    /// not sure, at the time of the change, with the key of the new title.
    private var titleChange: (at: Date, key: String, fromKey: String?)?
    /// The last new read of the tabs during a call: whether the call's own link was in its meeting (`CallMark.ownLinkInMeeting`).
    private var ownLinkRead: (at: Date, inMeeting: Bool?)?
    /// The marks of this tick, sent before the detector's event.
    private var marks: [DetectorEvent] = []
    /// When the call started, for its first minute: no title mark then (Meet can show the code first and the name
    /// later), and the call's own title is the one it shows at the end of that minute.
    private var callStart = Date.distantPast
    static let titleSettles: TimeInterval = 60
    private var firstTitleSent = false
    private var firstTitleKey: String?
    /// The window titles are read for the marks at most this often, and after a read that failed or was slow the
    /// next one waits longer (`titleBackoff`), so a browser that does not answer costs the tick little.
    static let titleReadEvery: TimeInterval = 4
    static let titleBackoff: [TimeInterval] = [10, 30, 60]
    static let slowTitleRead: TimeInterval = 1
    private var nextTitleRead = Date.distantPast
    private var titleFailures = 0
    /// While a link change waits for its next sure reading, the tabs are read at most this often instead of each
    /// 10 s. A change is forgotten 10 s after its last sure reading, so unknown lists never read more often than
    /// before. The probe's own back-off still holds.
    static let tabRefreshWhileChangeWaits: TimeInterval = 4
    /// Outside a call, a browser that uses the mic for something else (dictation, a voice search) was asked for
    /// its tabs at every tick, for as long as that lasted. A "no meeting here" answer now holds this long. It is
    /// read again at once when the browser's mic use stops and starts, or its window titles change (a new tab, a
    /// tab switch, a page that loaded), so a call that starts is still seen at the next tick. Without readable
    /// window titles (no Accessibility) nothing is held.
    static let idleTabRefresh: TimeInterval = 10
    private var idleTabs: [String: (time: Date, tabs: [BrowserTab], titles: [String])] = [:]
    private var tickTime = Date()
    private var lastLogged: [String: String] = [:]
    private var watch = UnconfirmedCallWatch()
    /// Apps in this tick that use the mic like a call while no meeting can be confirmed.
    private var suspects: [UnconfirmedCall] = []
    /// The current call showed the Teams app's call controls, which go when you leave, so their absence later means
    /// the call is over.
    private var callSignSeen = false
    /// Apps that showed their call sign in this tick, before the call started.
    private var signAtStart: Set<String> = []
    /// Without a call and without the mic, the Teams app's controls are read at most this often.
    static let idleControlsInterval: TimeInterval = 10
    private var lastIdleControlsRead = Date.distantPast
    /// The current call was started by the owner's Record on a warning. Read it on the detection queue, in `onEvent`.
    public private(set) var callIsForced = false
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
    /// The labels the mute check read last for the current call, so the tick does not walk the same app again.
    private var lastLabels: (call: Int, time: Date, labels: [String]?)?
    static let labelsFreshFor: TimeInterval = 4
    private var running = false
    private var tracker = MuteTracker()
    private var shownMute = ShownMute.none
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
    /// The key (`CallTitleWatch.key`) of the Meet title the call shows when its first minute ends, once per call. Runs
    /// on the detection queue, before the tick's marks.
    public var onFirstTitleKey: (String) -> Void = { _ in }
    /// Called when the person mutes or unmutes in the call app, during a call. Runs on the mute queue. A "muted" that
    /// cannot be read again for `MuteTracker.unknownLimit` reports unmuted; `lastMutedSeen` then tells when it was
    /// last seen.
    public var onMuteChange: (Bool) -> Void = { _ in }
    /// The same change, with the last reading that saw "muted" as it was at the change: the end of a mute span
    /// when "muted" turned unknown. Called just before `onMuteChange`.
    public var onMuteChangeAt: (_ muted: Bool, _ lastMutedSeen: Date?) -> Void = { _, _ in }
    /// What the app shows, when it changed: an unmute that comes only from the unknown limit shows as "muted when
    /// last seen", and a later sure "unmuted" clears it though the tracker did not change. Runs on the mute queue,
    /// after `onMuteChange`.
    public var onShownMute: (ShownMute) -> Void = { _ in }
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
        // The leeway lets the system fire the tick together with other timers; a call still starts within seconds.
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Self.tickLeewayMilliseconds))
        timer.setEventHandler { [weak self] in self?.tick(at: Date()) }
        timer.resume()
        self.timer = timer
        muteLock.withLock { running = true }
    }

    /// The mute timer runs during a call only. Runs inside the mute lock.
    private func setMuteTimer(on: Bool) {
        if on, running, mute != nil, muteTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: muteQueue)
            timer.schedule(deadline: .now() + 0.5, repeating: MuteTracker.mutedCheckInterval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.checkMute(at: Date()) }
            timer.resume()
            muteTimer = timer
        } else if !on {
            muteTimer?.cancel()
            muteTimer = nil
        }
    }

    /// Stops the ticks and forgets the call: a call still open when detection starts again is a new call.
    public func stop() {
        timer?.cancel()
        timer = nil
        muteLock.withLock {
            running = false
            setMuteTimer(on: false)
        }
        queue.async { [weak self] in self?.reset() }
    }

    /// Forgets the detector's call, the mute state, the tab cache, and the warning sessions. Runs on the detection
    /// queue, so no tick sees half of it.
    func reset() {
        detector = initialDetector
        currentPlatform = nil
        meetingID = nil
        lastProcesses = []
        lastMic = [:]
        lastOutput = [:]
        activeMeetingIDs = [:]
        signAtStart = []
        tabCache = [:]
        watchMarks(from: nil, at: .distantPast)
        idleTabs = [:]
        suspects = []
        callSignSeen = false
        callIsForced = false
        lastIdleControlsRead = .distantPast
        lastLogged = [:]
        watch.reset()
        mic.forget()
        muteLock.withLock {
            muteTarget = nil
            lastLabels = nil
            tracker = MuteTracker()
            shownMute = .none
            setMuteTimer(on: false)
        }
    }

    public func tick(at time: Date) {
        guard !isSuspended else { return }
        let snapshot = snapshot(at: time)
        // The marks go out before the detector's event of this tick, while the call they belong to still goes on.
        if detector.isInCall {
            // A title change waits 10 s, and as long as the tabs still check a change: a sure mark replaces it.
            if let change = titleChange, time.timeIntervalSince(change.at) > CallTitleWatch.readingGap, !linkWatch.isPending(at: time) {
                Log.info("The window of the call shows another Meet meeting; marked as not sure, and the recording goes on")
                // From the tab list of this tick only: an older read says nothing.
                let own = ownLinkRead.flatMap { time.timeIntervalSince($0.at) <= CallTitleWatch.readingGap ? $0.inMeeting : nil }
                marks.append(.marked(link: nil, platform: .meet, source: .title, sure: false, at: change.at, titleKey: change.key,
                                     ownLinkInMeeting: own))
                titleChange = nil
            }
            if let key = firstTitleKey { onFirstTitleKey(key) }
            for mark in marks { onEvent(mark) }
        }
        firstTitleKey = nil
        marks = []
        if let event = detector.process(snapshot) {
            switch event {
            case .started(let platform, let bundleID, _):
                currentPlatform = platform
                meetingID = activeMeetingIDs[bundleID]
                watchMarks(from: meetingID, at: time)
                callSignSeen = signAtStart.contains(bundleID)
                callIsForced = false
            case .ended:
                currentPlatform = nil
                meetingID = nil
                watchMarks(from: nil, at: .distantPast)
                callSignSeen = false
                callIsForced = false
                muteLock.withLock {
                    muteTarget = nil
                    lastLabels = nil
                    setMuteTimer(on: false)
                }
            case .marked:
                break
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
        muteLock.withLock {
            muteTarget = target
            lastLabels = nil
            setMuteTimer(on: true)
        }
    }

    /// Starts recording the app now, for the owner's Record on a warning. Runs on the detection queue.
    public func forceStart(bundleID: String, platform: Platform) {
        queue.async { [weak self] in self?.forceStartNow(bundleID: bundleID, platform: platform, at: Date()) }
    }

    /// Records a call that Mossad sees and keeps off the record, for the owner's Record on that notice: the owner's
    /// Record always wins. The call is already the detector's call, so its start goes out again, marked as the
    /// owner's choice. A call that ended meanwhile starts like any other forced call.
    public func recordBlockedCall(bundleID: String, platform: Platform) {
        queue.async { [weak self] in self?.recordBlockedCallNow(bundleID: bundleID, platform: platform, at: Date()) }
    }

    func recordBlockedCallNow(bundleID: String, platform: Platform, at time: Date) {
        guard !isSuspended else { return }
        guard detector.currentBundleID == bundleID, let current = currentPlatform else {
            forceStartNow(bundleID: bundleID, platform: platform, at: time)
            return
        }
        Log.info("The owner chose to record \(bundleID), which was kept off the record")
        callIsForced = true
        onEvent(.started(platform: current, bundleID: bundleID, at: time))
        // The recorder starts unmuted, so the current mute state must go out again.
        watchMute(bundleID: bundleID, platform: current)
    }

    func forceStartNow(bundleID: String, platform: Platform, at time: Date) {
        guard !isSuspended else { return }
        // A warning can be answered long after it came; an app that no longer uses the mic is not in a call.
        guard mic.processes().contains(where: { $0.isRunningInput == true && Self.groupID(for: $0.bundleID) == bundleID }) else {
            Log.info("Not recording \(bundleID): it no longer uses the mic")
            return
        }
        guard let event = detector.force(platform: platform, bundleID: bundleID, at: time) else { return }
        Log.info("The owner chose to record \(bundleID) as \(platform.displayName)")
        currentPlatform = platform
        meetingID = nil
        watchMarks(from: nil, at: time)
        callSignSeen = false
        callIsForced = true
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
        // A list that cannot be read is unknown: the last list stays, so a live call does not lose its mic.
        let processes = mic.scan(callActive: detector.isInCall) ?? lastProcesses
        lastProcesses = processes
        activeMeetingIDs = [:]
        signAtStart = []
        var inputs: [String: [Bool?]] = [:]
        var outputs: [String: [Bool?]] = [:]
        var order: [String] = []
        for p in processes {
            guard let group = Self.groupID(for: p.bundleID) else { continue }
            if inputs[group] == nil { order.append(group) }
            inputs[group, default: []].append(p.isRunningInput)
            outputs[group, default: []].append(p.isRunningOutput)
        }
        var micByApp: [String: Bool] = [:]
        var outputByApp: [String: Bool] = [:]
        for group in order {
            micByApp[group] = Self.anyRunning(inputs[group] ?? []) ?? lastMic[group] ?? false
            outputByApp[group] = Self.anyRunning(outputs[group] ?? []) ?? lastOutput[group] ?? false
        }
        lastMic = micByApp
        lastOutput = outputByApp
        // A browser whose mic use stopped is read again when it starts.
        idleTabs = idleTabs.filter { micByApp[$0.key] == true }

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
        let candidates = order.compactMap { group -> MeetingCandidate? in
            let micActive = micByApp[group] ?? false
            let output = outputByApp[group] ?? false
            // The Zoom and Teams apps release the mic while the owner is muted, so their meeting sign with the
            // call's sound is a call too. An app with no mic and no sound is not asked anything.
            let canStartWithoutMic = output && (group == MeetingMatcher.zoomBundleID || group == MeetingMatcher.teamsBundleID)
            guard micActive || group == current || canStartWithoutMic else { return nil }
            var c = candidate(group: group, micActive: micActive, outputActive: output, isCurrent: group == current)
            c?.outputActive = output
            return c
        }
        if current != nil, let c = candidates.first(where: { $0.bundleID == current }) {
            logChange("tick", "tick \(c.bundleID) mic=\(c.micActive) present=\(String(describing: c.meetingPresent))")
        }
        return DetectionSnapshot(time: time, candidates: candidates)
    }

    private func candidate(group: String, micActive: Bool, outputActive: Bool, isCurrent: Bool) -> MeetingCandidate? {
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
            if isCurrent, let labels = teamsLabels(group) {
                let controls = Self.teamsControls(in: labels)
                if controls {
                    present = true
                    sure = true
                    callSignSeen = true
                } else if !micActive, callSignSeen, !titleSaysMeeting {
                    present = false
                }
                logChange("teams-controls", "teams controls: \(controls)")
            } else if !isCurrent, !micActive, outputActive, tickTime.timeIntervalSince(lastIdleControlsRead) >= Self.idleControlsInterval {
                // Joined muted: Teams holds no mic, but it plays the call and shows the controls. A slow read, so a
                // Teams that only plays a sound costs one walk each 10 s.
                lastIdleControlsRead = tickTime
                if let labels = mute?.labels(bundleID: group, platform: .teams, meetingID: nil, pace: .callerPaced), Self.teamsControls(in: labels) {
                    present = true
                    sure = true
                    signAtStart.insert(group)
                }
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
        let (list, fresh) = readTabs(group, isCurrent: isCurrent)
        // The window titles of the copies of the browser that answer, read at most once in a tick.
        var titlesRead: [String]??
        func answeredTitles() -> [String]? {
            if let titlesRead { return titlesRead }
            let titles = windows.answeredWindowTitles(bundleID: group)
            titlesRead = .some(titles)
            return titles
        }
        if isCurrent { watchForMarks(list, fresh: fresh, group: group, titles: answeredTitles) }
        guard let list else {
            // The window titles of the copies of the browser that answer can still show a Meet call (Accessibility).
            if !isCurrent || currentPlatform == .meet,
               answeredTitles()?.contains(where: MeetingMatcher.meetWindowIsMeeting) == true {
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
            let present = meetingTabs.contains { $0.0 == platform }
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
        return MeetingCandidate(platform: first.0, bundleID: group, micActive: micActive, meetingPresent: true)
    }

    /// Starts the watch of a call's marks again: at each start and end of a call.
    private func watchMarks(from link: String?, at start: Date) {
        linkWatch = CallLinkWatch(link: link)
        titleWatch = CallTitleWatch()
        lastSureMark = nil
        titleChange = nil
        ownLinkRead = nil
        marks = []
        callStart = start
        firstTitleSent = false
        firstTitleKey = nil
        nextTitleRead = .distantPast
        titleFailures = 0
    }

    /// The call's link and its windows' Meet title against this tick's readings. Only a new read of the tabs counts,
    /// never the cache. Nothing here ends or starts a call, and nothing changes the service's link or the mute check:
    /// a change is a mark, sent with the tick. Only the watch's own link follows, so a later change is a later mark.
    private func watchForMarks(_ list: [BrowserTab]?, fresh: Bool, group: String, titles: () -> [String]?) {
        if fresh {
            ownLinkRead = (tickTime, list.flatMap { list in
                linkWatch.link.map { own in CallLinkWatch.meetings(in: list).contains { $0.id == own } }
            })
            // A mark is at the first reading of its change.
            let since = linkWatch.pendingSince(at: tickTime) ?? tickTime
            switch linkWatch.observe(list, at: tickTime) {
            case .none:
                break
            case .adopt:
                Log.info("The call in \(group) has a meeting link now; its marks are not sure")
            case .newCall(let link, let platform):
                // A link taken during the call was not read from the call's own tab at its start.
                let sure = !linkWatch.isAdopted
                Log.info("The call in \(group) shows another meeting now; marked as \(sure ? "sure" : "not sure"), and the recording goes on")
                // A title change of the same change that waits is its earlier sign.
                let at = min(since, titleChange?.at ?? since)
                lastSureMark = tickTime
                titleChange = nil
                // The windows show the new meeting from now on: their title is not a second change.
                titleWatch = CallTitleWatch()
                marks.append(.marked(link: link, platform: platform, source: .tabs, sure: sure, at: at))
            }
        }
        guard currentPlatform == .meet else { return }
        if !firstTitleSent, tickTime.timeIntervalSince(callStart) >= Self.titleSettles, let title = titleWatch.title {
            firstTitleSent = true
            firstTitleKey = CallTitleWatch.key(title)
        }
        guard tickTime >= nextTitleRead else { return }
        let began = Date()
        let read = titles()
        if read == nil || Date().timeIntervalSince(began) > Self.slowTitleRead {
            titleFailures += 1
            nextTitleRead = tickTime.addingTimeInterval(Self.titleBackoff[min(titleFailures, Self.titleBackoff.count) - 1])
        } else {
            titleFailures = 0
            // Half a second of slack, for a tick that comes a little early.
            nextTitleRead = tickTime.addingTimeInterval(Self.titleReadEvery - 0.5)
        }
        let before = titleWatch.title
        let seen = titleWatch.pendingSince ?? tickTime
        guard let title = titleWatch.observe(read, at: tickTime) else { return }
        let key = CallTitleWatch.key(title)
        // Back to the title before a change that waits: the owner only looked at another meeting's page.
        if let waiting = titleChange, waiting.fromKey == key {
            titleChange = nil
            return
        }
        if let sure = lastSureMark, tickTime.timeIntervalSince(sure) <= CallTitleWatch.readingGap { return }  // The same change.
        // In the first minute a code can become the meeting's name: no mark.
        guard seen.timeIntervalSince(callStart) >= Self.titleSettles else { return }
        titleChange = (seen, key, titleChange?.fromKey ?? before.map(CallTitleWatch.key))
        // The tabs may confirm it for sure: one new read at the next tick.
        tabCache[group] = nil
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
                shownMute = .none
                trackerCall = target.call
                fresh = true
            }
            return target
        }
        if fresh { unknownLabelReads = 0 }
        guard let target, muteLock.withLock({ tracker.isDue(at: time) }) else { return }
        let pace: MuteReadPace = muteLock.withLock({ tracker.muted == true }) ? .whileMuted : .backoff
        let labels = mute.labels(bundleID: target.bundleID, platform: target.platform, meetingID: target.meetingID, pace: pace)
        let state = labels.flatMap { MuteState.from(labels: $0, platform: target.platform) }
        var seen: Date?
        var shown: ShownMute?
        let change: Bool? = muteLock.withLock {
            // The call ended or changed during the read: its answer belongs to no call.
            guard muteTarget?.call == target.call else { return nil }
            lastLabels = (target.call, time, labels)
            let change = tracker.record(state, at: time)
            seen = tracker.lastMutedSeen
            let reading: ShownMute.Reading? = state.map { .sure(muted: $0) } ?? (change == false ? .unreadable : nil)
            if let reading, shownMute.after(reading) != shownMute {
                shownMute = shownMute.after(reading)
                shown = shownMute
            }
            return change
        }
        if let labels, state == nil, muteLock.withLock({ tracker.muted == nil }) {
            unknownLabelReads += 1
            if unknownLabelReads == 5 {
                Log.info("No known mute button in \(target.bundleID) (\(labels.count) labels); mute detection is off for this call")
            }
        } else if state != nil {
            unknownLabelReads = 0
        }
        if let change {
            if state == nil { Log.info("The mute state could not be read for \(Int(MuteTracker.unknownLimit)) s; recording the mic as unmuted") }
            onMuteChangeAt(change, seen)
            onMuteChange(change)
        }
        if let shown { onShownMute(shown) }
    }

    /// The Teams app's labels for the current call: the mute check's reading when it is fresh, so the tick does
    /// not walk the app a second time; a read of its own otherwise.
    private func teamsLabels(_ group: String) -> [String]? {
        let recent = muteLock.withLock { () -> (call: Int, time: Date, labels: [String]?)? in
            guard let last = lastLabels, last.call == muteTarget?.call else { return nil }
            return last
        }
        if let recent, abs(tickTime.timeIntervalSince(recent.time)) < Self.labelsFreshFor { return recent.labels }
        return mute?.labels(bundleID: group, platform: .teams, meetingID: nil)
    }

    /// Whether any process of an app runs: true with one "yes", false only when every answer is a "no", and nil
    /// (unknown) when a read failed and no other process says "yes".
    static func anyRunning(_ states: [Bool?]) -> Bool? {
        if states.contains(true) { return true }
        return states.contains(where: { $0 == nil }) ? nil : false
    }

    static func teamsControls(in labels: [String]) -> Bool {
        labels.contains { let l = $0.lowercased(); return l.hasPrefix("mute") || l.hasPrefix("unmute") }
    }

    /// The tabs, and whether they were read now (not from a cache).
    private func readTabs(_ group: String, isCurrent: Bool) -> (tabs: [BrowserTab]?, fresh: Bool) {
        let refresh = linkWatch.isPending(at: tickTime) ? Self.tabRefreshWhileChangeWaits : Self.tabRefreshDuringCall
        if isCurrent, let cached = tabCache[group], tickTime.timeIntervalSince(cached.time) < refresh {
            return (cached.tabs, false)
        }
        // The window titles are the proof that nothing changed. When they cannot be read, the tabs are read.
        let titles = isCurrent ? nil : windows.answeredWindowTitles(bundleID: group)
        if !isCurrent, let titles, let cached = idleTabs[group], cached.titles == titles,
           tickTime.timeIntervalSince(cached.time) < Self.idleTabRefresh {
            return (cached.tabs, false)
        }
        let list = tabs.tabs(browserBundleID: group)
        tabCache[group] = (tickTime, list)
        idleTabs[group] = nil
        // Only a known "no meeting here" is kept: an unknown answer is asked again, and a meeting starts the call.
        if !isCurrent, let titles, let list, !Self.showsMeeting(list) { idleTabs[group] = (tickTime, list, titles) }
        return (list, true)
    }

    /// A selected tab that is a meeting: what starts a call.
    static func showsMeeting(_ list: [BrowserTab]) -> Bool {
        list.contains { tab in
            guard tab.isActive, let platform = MeetingMatcher.platform(forTabURL: tab.url) else { return false }
            return !(platform == .meet && MeetingMatcher.meetTabLeftMeeting(title: tab.title))
        }
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
