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
        case meetings = "Meetings", voices = "Voices", settings = "Settings", log = "Log"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .meetings: "text.bubble"
            case .voices: "person.wave.2"
            case .settings: "gearshape"
            case .log: "doc.plaintext"
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var meetings: [CallRecord] = []
    @Published private(set) var processing = 0
    @Published var section: Section = .meetings
    @Published var selectedMeetingID: String?
    @Published var namingCallID: String?

    let paths = Paths.live
    let library: VoiceLibrary
    let keychain = Keychain()
    let permissions = PermissionsMonitor()
    private let detection = DetectionService(mic: MicUsageProbe(), tabs: BrowserTabProbe(), windows: WindowTitleProbe())
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

    @AppStorage("retentionDays") var retentionDays = 30

    init() {
        try? paths.ensureDirectories()
        Log.directory = paths.logs
        library = VoiceLibrary(directory: paths.voices)
        recorder = CallRecorder(paths: paths, makeThem: { ProcessTap(processObjectIDs: $0) }, makeMe: { MicCapture() },
                                systemAudioAllowed: { TCC.preflight("kTCCServiceAudioCapture").map { $0 == 0 } ?? true })
        rebuildPipeline()

        enableLaunchAtLoginOnce()
        notifier.onOpen = { [weak self] callID in self?.openNaming(callID) }

        let detection = detection
        detection.onEvent = { [weak self] event in
            // Read the call's audio processes on the detection queue, where they were just computed.
            let ids = detection.audioProcessIDs
            Task { @MainActor in self?.handle(event, processIDs: ids) }
        }
        detection.onCallProcesses = { [weak self] ids in
            guard let recorder = self?.recorder else { return }
            CaptureQueue.queue.async { recorder.updateThemProcesses(ids) }
        }
        detection.start()
        outputWatcher = OutputDeviceWatcher { [weak self] in
            guard let recorder = self?.recorder else { return }
            CaptureQueue.queue.async { recorder.rebuildThem() }
        }
        requestPermissions()

        ProcessingQueue(paths: paths).recoverInterrupted()
        refresh()
        Task { await runHousekeeping() }
        housekeeping = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { await self?.runHousekeeping() }
        }
        Log.info("Mossad started")
        // Development hook: `--open-window [Meetings|Voices|Settings|Log]`.
        if let i = CommandLine.arguments.firstIndex(of: "--open-window") {
            let name = CommandLine.arguments.dropFirst(i + 1).first
            let section = Section.allCases.first { $0.rawValue == name } ?? .meetings
            DispatchQueue.main.async { self.open(section) }
        }
    }

    // MARK: State

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

    /// Recreates the pipeline with the current keys (after a key import).
    func rebuildPipeline() {
        let transcriber: Transcribing = keychain.get(.assemblyai).map { AssemblyAIClient(apiKey: $0) } ?? MissingKeyTranscriber()
        let summarizer: Summarizing? = keychain.get(.anthropic).map { ClaudeSummarizer(apiKey: $0) }
        let notifier = notifier
        pipeline = Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: FluidEmbeddingProvider(),
                            calendar: calendar, summarizer: summarizer, notify: { record in
                                Task { @MainActor in notifier.postNewVoices(record) }
                            })
    }

    // MARK: Actions

    func skipCurrentCall() {
        let recorder = recorder
        CaptureQueue.queue.async { recorder.skip() }
        status = .idle
    }

    func open(_ section: Section) {
        self.section = section
        showWindow()
    }

    func openNaming(_ callID: String) {
        section = .meetings
        selectedMeetingID = callID
        namingCallID = callID
        showWindow()
    }

    func applyNames(callID: String, names: [String: String]) {
        Task {
            await pipeline.applyNames(callID: callID, names: names)
            refresh()
        }
    }

    func retry(_ callID: String) {
        Task {
            await track { await self.pipeline.retry(callID) }
        }
    }

    // MARK: Internals

    private func handle(_ event: DetectorEvent, processIDs: [AudioObjectID]) {
        switch event {
        case .started(let platform, let bundleID, let at):
            Log.info("Call started: \(platform.displayName) (\(bundleID))")
            status = .recording(platform, since: at)
            let recorder = recorder
            CaptureQueue.queue.async {
                do {
                    try recorder.begin(platform: platform, bundleID: bundleID, processIDs: processIDs, at: at)
                } catch {
                    Log.error("Could not start recording: \(error)")
                    Task { @MainActor in self.status = .idle }
                }
            }
        case .ended(let at, let trimTo):
            Log.info("Call ended")
            status = .idle
            let recorder = recorder
            CaptureQueue.queue.async {
                guard let record = recorder.end(at: at, trimTo: trimTo) else { return }
                Task { @MainActor in
                    self.refresh()
                    await self.track { await self.pipeline.process(record.id) }
                }
            }
        }
    }

    private func track(_ work: @escaping () async -> Void) async {
        processing += 1
        refresh()
        await work()
        processing -= 1
        refresh()
    }

    private func runHousekeeping() async {
        await track { await self.pipeline.runPending() }
        Retention.sweep(audioRoot: paths.audio, olderThan: retentionDays)
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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Mossad"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: MainWindow().environmentObject(self).environmentObject(permissions))
            w.setContentSize(NSSize(width: 1040, height: 700))
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
    func transcribe(file: URL, track: Track) async throws -> [Utterance] { throw MissingAPIKey(service: "AssemblyAI") }
}
