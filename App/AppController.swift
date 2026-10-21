import AppKit
import AVFoundation
import CoreAudio
import Foundation
import MossadCore
import ServiceManagement
import SwiftUI

/// Owns detection, recording, and processing, and exposes app state to the menu and the window.
@MainActor
final class AppController: ObservableObject {
    enum Status: Equatable {
        case idle
        case recording(Platform, since: Date)
    }

    enum Section: String, CaseIterable, Identifiable {
        case meetings = "Meetings", people = "People", settings = "Settings", log = "Log"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .meetings: "bubble.left.and.text.bubble.right"
            case .people: "person.2"
            case .settings: "gearshape"
            case .log: "doc.text"
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var isPaused = false
    /// Muted in the call app: the mic track records silence meanwhile.
    @Published private(set) var isMuted = false
    /// The sub-step each call is in while processing, such as "AssemblyAI is transcribing".
    @Published private(set) var stepDetails: [String: String] = [:]
    /// What was said so far, from AssemblyAI streaming; shown while the call runs, not used for the note.
    @Published private(set) var live = LiveTranscript()
    @AppStorage("liveTranscript") var liveTranscriptEnabled = true
    /// "local", "r2", or "s3". The secret lives in the Keychain; the rest is not secret.
    @AppStorage("storage") var storage = "local"
    @AppStorage("cloudEndpoint") var cloudEndpoint = ""
    @AppStorage("cloudBucket") var cloudBucket = ""
    @AppStorage("cloudRegion") var cloudRegion = "us-east-1"
    @AppStorage("cloudAccessKeyID") var cloudAccessKeyID = ""
    @AppStorage("cloudKeepLocalDays") var cloudKeepLocalDays = 30
    private var liveSessions: [LiveTranscriber] = []
    private var liveStart = Date()
    /// 0 means on. Otherwise Mossad is off until this time (seconds since 1970; `.infinity` for "until I turn it on").
    @AppStorage("offUntil") private var offUntil: Double = 0
    private var resumeTimer: Timer?

    var isOn: Bool { offUntil == 0 }
    /// Live loudness of your mic and of the call audio, for the waveform.
    var meters: (me: LevelMeter, them: LevelMeter) { (recorder.meMeter, recorder.themMeter) }
    var offUntilDate: Date? { offUntil == 0 || offUntil == .infinity ? nil : Date(timeIntervalSince1970: offUntil) }
    @Published private(set) var meetings: [CallRecord] = []
    @Published private(set) var processing = 0
    @Published var section: Section = .meetings
    @Published var selectedMeetingID: String?
    @Published var namingCallID: String?

    let paths = Paths.live
    let library: VoiceLibrary
    let keychain = Keychain()
    let permissions = PermissionsMonitor()
    private let detection = DetectionService(mic: MicUsageProbe(), tabs: BrowserTabProbe(), windows: WindowTitleProbe(),
                                             mute: AccessibilityMuteProbe())
    private let calendar = EventKitCalendarSource()
    private let notifier = Notifier()
    private var pipeline: Pipeline!
    /// Used only on `CaptureQueue.queue`.
    private nonisolated let recorder: CallRecorder
    private var window: NSWindow?
    private let windowDelegate = WindowDelegate()
    private var housekeeping: Timer?
    private var outputWatcher: OutputDeviceWatcher?
    private var browserLaunchObserver: NSObjectProtocol?

    @AppStorage("deleteRecordings") var deleteRecordings = false
    @AppStorage("recordingDays") var recordingDays = 90
    @AppStorage("ownerName") var ownerName = NSFullUserName()
    @AppStorage("organization") var organization = ""
    @AppStorage("voiceFingerprints") var voiceFingerprints = true

    /// The mic is recorded raw: when Chrome also uses voice processing, macOS gives a second voice-processing
    /// client silence. Echo from the speakers is dropped later by TranscriptMerger.
    /// The recorder calls these closures on the capture queue. Built outside the main actor so Swift does not
    /// tie them to the main thread and stop the app when they run there.
    nonisolated private static func makeRecorder(paths: Paths) -> CallRecorder {
        CallRecorder(paths: paths, makeThem: { ProcessTap(processObjectIDs: $0) }, makeMe: { MicCapture(voiceProcessing: false) },
                     systemAudioAllowed: { TCC.preflight("kTCCServiceAudioCapture").map { $0 == 0 } ?? true })
    }

    init() {
        try? paths.ensureDirectories()
        Log.directory = paths.logs
        library = VoiceLibrary(directory: paths.voices)
        recorder = Self.makeRecorder(paths: paths)
        rebuildPipeline()

        // Development hook: `--ui-preview` opens the UI on $MOSSAD_ROOT with no detection, recording, or
        // processing, so the screens can be checked while the installed copy records a call.
        let preview = CommandLine.arguments.contains("--ui-preview")
        if !preview {
            enableLaunchAtLoginOnce()
            notifier.onOpen = { [weak self] callID in self?.openNaming(callID) }

            let detection = detection
            let recorder = recorder
            detection.onEvent = { @Sendable [weak self] event in
                // Read the call's audio processes on the detection queue, where they were just computed.
                let ids = detection.audioProcessIDs
                let meetingID = detection.meetingID
                guard let self else { return }
                // Recorder commands go straight from the detection queue to the capture queue, so they keep
                // the detector's order relative to the process updates below. The UI follows on the main actor.
                CaptureQueue.queue.async { self.capture(event, processIDs: ids, meetingID: meetingID, recorder: recorder) }
                Task { @MainActor in self.show(event) }
            }
            detection.onMuteChange = { @Sendable [weak self] muted in
                CaptureQueue.queue.async { recorder.setMuted(muted) }
                Task { @MainActor in self?.isMuted = muted }
            }
            detection.onCallProcesses = { @Sendable ids in
                CaptureQueue.queue.async { recorder.updateThemProcesses(ids) }
            }
            if isOn || (offUntilDate.map { $0 <= Date() } ?? false) {
                offUntil = 0
                detection.start()
            } else {
                scheduleTurnOn()
            }
            outputWatcher = OutputDeviceWatcher { @Sendable in
                CaptureQueue.queue.async { recorder.rebuildThem() }
            }
            requestPermissions()

            Task { await runHousekeeping() }
            housekeeping = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                Task { await self?.runHousekeeping() }
            }
            ProcessingQueue(paths: paths).recoverInterrupted()
        }
        refresh()
        if !preview {
            relinkEmails()
            Task { await track { await self.pipeline.continueSplitMeetings() } }
        }
        Log.info("Mossad started")
        // Development hook: `--show-recording` shows the recording state in the UI without recording anything.
        if CommandLine.arguments.contains("--show-recording") { status = .recording(.meet, since: Date().addingTimeInterval(-75)) }
        // Development hook: `--light` shows the UI in light mode, to check both looks.
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        // Development hook: `--open-naming` opens "Who is speaking?" for the first call that needs names.
        if CommandLine.arguments.contains("--open-naming"), let first = callsNeedingNames.first {
            DispatchQueue.main.async { self.openNaming(first.id) }
        }
        // Development hook: `--open-window [Meetings|People|Settings|Log]`.
        if let i = CommandLine.arguments.firstIndex(of: "--open-window") {
            let name = CommandLine.arguments.dropFirst(i + 1).first
            let section = Section.allCases.first { $0.rawValue == name } ?? .meetings
            DispatchQueue.main.async { self.open(section) }
        }
    }

    // MARK: State

    /// The calendar title of the call being recorded, when it is known already.
    var recordingTitle: String? { meetings.first { $0.status == .recording }?.calendarTitle }

    /// The step of the oldest call in progress, for the panel and the sidebar.
    var currentStep: ProcessingStep? {
        meetings.filter { ProcessingStep(status: $0.status) != nil }.min { $0.start < $1.start }.flatMap { ProcessingStep(status: $0.status) }
    }

    var isRecording: Bool {
        if case .recording = status { return true }
        return false
    }

    var callsNeedingNames: [CallRecord] {
        meetings.filter { $0.status == .written && !$0.unknownSpeakers.isEmpty }
    }

    func refresh() {
        meetings = MeetingIndex(paths: paths).all()
    }

    func hasKey(_ key: APIKey) -> Bool { keychain.get(key) != nil }

    /// Recreates the pipeline with the current keys and settings.
    func rebuildPipeline() {
        let owner = ownerName.trimmingCharacters(in: .whitespaces).isEmpty ? NSFullUserName() : ownerName
        let organization = organization.trimmingCharacters(in: .whitespaces)
        let transcriber: Transcribing = keychain.get(.assemblyai).map { AssemblyAIClient(apiKey: $0) } ?? MissingKeyTranscriber()
        let summarizer: Summarizing? = keychain.get(.anthropic).map { ClaudeSummarizer(apiKey: $0, ownerName: owner, organization: organization) }
        let notifier = notifier
        pipeline = Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: FluidEmbeddingProvider(),
                            calendar: calendar, summarizer: summarizer, notify: { record in
                                Task { @MainActor in notifier.postNewVoices(record) }
                            }, ownerName: owner, voiceFingerprints: voiceFingerprints,
                            onStep: { [weak self] record in
                                Task { @MainActor in self?.update(record) }
                            },
                            onDetail: { [weak self] id, text in
                                Task { @MainActor in self?.stepDetails[id] = text }
                            })
    }

    /// Puts a record saved by the pipeline into the list, so the step shows while the call is processed.
    private func update(_ record: CallRecord) {
        if let i = meetings.firstIndex(where: { $0.id == record.id }) { meetings[i] = record } else { refresh() }
    }

    // MARK: Actions

    func deleteAllVoices() {
        do { try library.deleteAll() } catch { Log.error("Deleting voices failed: \(error)") }
        objectWillChange.send()
    }

    func skipCurrentCall() {
        let recorder = recorder
        CaptureQueue.queue.async { recorder.skip() }
        status = .idle
        isPaused = false
        stopLive()
    }

    /// Ends the recording now and processes it. The detector still sees this call, so it does not start a
    /// new recording until the call really ends.
    func stopCurrentCall() {
        let recorder = recorder
        CaptureQueue.queue.async {
            guard let record = recorder.end(at: Date(), trimTo: nil, byPerson: true) else { return }
            Task { @MainActor in
                self.refresh()
                await self.track { await self.pipeline.process(record.id) }
            }
        }
        isMuted = false
        status = .idle
        isPaused = false
        stopLive()
    }

    func pauseCurrentCall() {
        let recorder = recorder
        CaptureQueue.queue.async { recorder.pause() }
        isPaused = true
        stopLive()
    }

    func resumeCurrentCall() {
        let recorder = recorder
        CaptureQueue.queue.async { recorder.resume() }
        isPaused = false
        startLive(reset: false)
    }

    /// Opens one streaming session per track. Billed while open, so only while recording and not paused.
    private func startLive(reset: Bool) {
        stopLive()
        if reset { live = LiveTranscript() }
        guard liveTranscriptEnabled, case .recording(_, let since) = status, let key = keychain.get(.assemblyai) else { return }
        liveStart = since
        for (track, sink) in [(Track.me, recorder.meSink), (.them, recorder.themSink)] {
            let session = LiveTranscriber(apiKey: key) { [weak self] message in
                Task { @MainActor in
                    guard let self else { return }
                    self.live.apply(message, source: track, at: Date().timeIntervalSince(self.liveStart))
                }
            }
            sink.set { buffer in session.send(buffer) }
            liveSessions.append(session)
        }
    }

    private func stopLive() {
        recorder.meSink.set(nil)
        recorder.themSink.set(nil)
        liveSessions.forEach { $0.stop() }
        liveSessions = []
    }

    /// Turns detection and recording off until a time (nil: until turned on again). A call being recorded
    /// ends normally and is processed.
    func turnOff(until date: Date?) {
        offUntil = date?.timeIntervalSince1970 ?? .infinity
        if isRecording { stopCurrentCall() }
        detection.stop()
        scheduleTurnOn()
        objectWillChange.send()
        Log.info("Mossad turned off" + (date.map { " until \($0.formatted())" } ?? ""))
    }

    func turnOn() {
        offUntil = 0
        resumeTimer?.invalidate()
        resumeTimer = nil
        detection.start()
        objectWillChange.send()
        Log.info("Mossad turned on")
    }

    /// Turns Mossad back on when an "off until" time passes, also after a restart.
    private func scheduleTurnOn() {
        resumeTimer?.invalidate()
        guard let date = offUntilDate else { return }
        resumeTimer = Timer.scheduledTimer(withTimeInterval: max(1, date.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.turnOn() }
        }
    }

    func open(_ section: Section) {
        self.section = section
        showWindow()
    }

    func openMeeting(_ callID: String) {
        section = .meetings
        selectedMeetingID = callID
        showWindow()
    }

    func openNaming(_ callID: String) {
        section = .meetings
        selectedMeetingID = callID
        namingCallID = callID
        showWindow()
    }

    func applyNames(callID: String, names: [String: String], emails: [String: String] = [:]) {
        Task {
            await pipeline.applyNames(callID: callID, names: names, emails: emails)
            refresh()
        }
    }

    func deleteMeeting(_ callID: String) {
        let archived = meetings.first { $0.id == callID }
        let archive = cloudArchive
        Task {
            if let archived, let archive { await archive.delete(archived) }
            if await pipeline.delete(callID: callID) {
                if selectedMeetingID == callID { selectedMeetingID = nil }
                refresh()
            }
        }
    }

    /// The voices stay in the transcript as letters, but the call stops asking for their names.
    func dismissSpeakers(callID: String, keys: [String]) {
        Task {
            await pipeline.dismissSpeakers(callID: callID, keys: keys)
            refresh()
        }
    }

    /// The bucket to archive recordings in, when one is set up completely.
    var cloudArchive: CloudArchive? {
        guard storage != "local", let endpoint = URL(string: cloudEndpoint), endpoint.host != nil, !cloudBucket.isEmpty,
              !cloudAccessKeyID.isEmpty, let secret = keychain.get(.cloudSecret) else { return nil }
        let config = S3Config(endpoint: endpoint, bucket: cloudBucket, region: storage == "r2" ? "auto" : cloudRegion,
                              accessKeyID: cloudAccessKeyID, secret: secret, pathStyle: storage == "r2")
        return CloudArchive(config: config, paths: paths)
    }

    /// Uploads finished recordings and removes old local copies, off the main actor.
    func syncCloud() {
        guard let archive = cloudArchive else { return }
        let days = cloudKeepLocalDays
        cloudSyncing = true
        Task.detached(priority: .utility) {
            let uploaded = await archive.sync(keepLocalDays: days)
            await MainActor.run {
                self.cloudSyncing = false
                if uploaded > 0 { self.refresh() }
            }
        }
    }

    @Published private(set) var cloudSyncing = false

    /// The text for a call in progress: the live sub-step, or the step name.
    func progressText(_ r: CallRecord) -> String? {
        stepDetails[r.id] ?? ProcessingStep(status: r.status)?.title
    }

    /// Joins the meetings into the earliest one and opens it.
    func mergeMeetings(_ ids: [String]) {
        Task {
            let merged = await pipeline.merge(callIDs: ids)
            refresh()
            if let merged { selectedMeetingID = merged }
        }
    }

    /// A person's new name reaches every past meeting and note.
    func renamePerson(_ old: String, to new: String) {
        Task {
            await pipeline.renamePerson(old, to: new)
            refresh()
        }
    }

    /// Meetings that used a saved person's email as the name get the person's name instead.
    func relinkEmails() {
        let pairs = library.profiles.compactMap { p in p.email.map { ($0, p.name) } }
        guard !pairs.isEmpty else { return }
        Task {
            for (email, name) in pairs where email != name { await pipeline.renamePerson(email, to: name) }
            refresh()
        }
    }

    func retry(_ callID: String) {
        Task {
            await track { await self.pipeline.retry(callID) }
        }
    }

    // MARK: Internals

    /// Runs on the capture queue.
    private nonisolated func capture(_ event: DetectorEvent, processIDs: [AudioObjectID], meetingID: String?, recorder: CallRecorder) {
        switch event {
        case .started(let platform, let bundleID, let at):
            Log.info("Call started: \(platform.displayName) (\(bundleID))")
            do {
                let id = try recorder.begin(platform: platform, bundleID: bundleID, processIDs: processIDs, meetingID: meetingID, at: at)
                Task { @MainActor in
                    self.refresh()
                    await self.findInvite(callID: id, platform: platform, meetingID: meetingID, start: at, recorder: recorder)
                }
            } catch {
                Log.error("Could not start recording: \(error)")
                Task { @MainActor in
                    // Only clear the status of this call, never of a newer one.
                    if case .recording(_, let since) = self.status, since == at { self.status = .idle }
                }
            }
        case .ended(let at, let trimTo):
            Log.info("Call ended")
            guard let record = recorder.end(at: at, trimTo: trimTo) else { return }
            Task { @MainActor in
                self.refresh()
                await self.track { await self.pipeline.process(record.id) }
            }
        }
    }

    /// The live call's invite, so it shows its real title while it runs instead of "Google Meet call".
    private func findInvite(callID: String, platform: Platform, meetingID: String?, start: Date, recorder: CallRecorder) async {
        let events = await calendar.events(from: start.addingTimeInterval(-900), to: start.addingTimeInterval(5400))
        guard let event = CalendarMatcher.bestEvent(for: platform, meetingID: meetingID, start: start,
                                                    end: start.addingTimeInterval(1800), in: events) else { return }
        CaptureQueue.queue.async {
            recorder.setCalendar(title: event.title, attendees: event.attendees, forCall: callID)
            Task { @MainActor in self.refresh() }
        }
    }

    private func show(_ event: DetectorEvent) {
        switch event {
        case .started(let platform, _, let at):
            status = .recording(platform, since: at)
            startLive(reset: true)
        case .ended:
            status = .idle
            isPaused = false
            isMuted = false
            stopLive()
        }
    }

    private func track(_ work: @escaping () async -> Void) async {
        processing += 1
        refresh()
        await work()
        syncCloud()
        processing -= 1
        refresh()
    }

    private func runHousekeeping() async {
        await track { await self.pipeline.runPending() }
        // Encoding an hour of audio takes seconds, so this stays off the main actor.
        let audio = paths.audio, days = deleteRecordings ? max(1, recordingDays) : nil
        await Task.detached(priority: .utility) {
            Recording.backfill(audioRoot: audio)
            Retention.sweep(audioRoot: audio, recordingsAfterDays: days)
        }.value
    }

    private func requestPermissions() {
        WindowTitleProbe.requestAccess()
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { Log.error("Microphone access denied") }
        }
        Task {
            if !(await calendar.requestAccess()) { Log.error("Calendar access denied") }
        }
        notifier.requestAuthorization()

        // System Audio Recording: show the one-time prompt now, not in the first call.
        permissions.requestSystemAudioIfNeeded()

        // Automation: ask each browser once, now and whenever a browser starts. The tab probe
        // itself never asks, so a prompt can never block detection during a call.
        for app in NSWorkspace.shared.runningApplications { primeAutomation(app.bundleIdentifier) }
        browserLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            Task { @MainActor in self?.primeAutomation(id) }
        }
    }

    private func primeAutomation(_ bundleID: String?) {
        guard let bundleID, case .browser(let base) = MeetingMatcher.appKind(bundleID: bundleID), base == bundleID else { return }
        permissions.askAutomationIfNeeded(bundleID)
    }

    private func enableLaunchAtLoginOnce() {
        guard !UserDefaults.standard.bool(forKey: "didSetLoginItem") else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didSetLoginItem")
        } catch {
            Log.error("Launch at login failed: \(error)")
        }
    }

    private func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Mossad"
            // A full-height sidebar with the traffic lights inside it; pane titles live in the content.
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: MainWindow().environmentObject(self).environmentObject(permissions))
            host.sceneBridgingOptions = [.toolbars]
            w.contentViewController = host
            w.setContentSize(NSSize(width: 1240, height: 820))
            w.contentMinSize = NSSize(width: 980, height: 600)
            w.delegate = windowDelegate
            w.center()
            w.setFrameAutosaveName("MossadMain")
            window = w
        }
        refresh()
        // A Dock icon only while the window is open, so it can be found with Cmd-Tab.
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private final class WindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Used when no AssemblyAI key is stored: the call stays queued until a key exists.
struct MissingKeyTranscriber: Transcribing {
    func transcribe(file: URL, track: Track, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [Utterance] {
        throw MissingAPIKey(service: "AssemblyAI")
    }
}
