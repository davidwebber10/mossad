import AppKit
import AVFoundation
import Combine
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
        case meetings = "Meetings", commitments = "Tasks", chat = "Chat", people = "People", analytics = "Analytics", settings = "Settings", log = "Log"
        var id: String { rawValue }
        var icon: Icon {
            switch self {
            case .meetings: .meetings
            case .commitments: .commitments
            case .chat: .sparkle
            case .people: .people
            case .analytics: .analytics
            case .settings: .settings
            case .log: .log
            }
        }

        static func typeSelect(_ typed: String, from current: Section) -> Section? {
            TypeSelect.next(in: allCases.map(\.rawValue), typed: typed, after: allCases.firstIndex(of: current)).map { allCases[$0] }
        }
    }

    @Published private(set) var status: Status = .idle {
        // An in-person recording owns the mic until Stop; the call scan every 2 s would be thrown away.
        didSet {
            let room = if case .recording(.inPerson, _) = status { true } else { false }
            detection.isSuspended = room
            // With detection suspended, the room's mic gets its own stall check.
            if room, roomMicTimer == nil {
                let recorder = recorder
                roomMicTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                    CaptureQueue.queue.async { recorder.checkMic() }
                }
            } else if !room {
                roomMicTimer?.invalidate()
                roomMicTimer = nil
            }
        }
    }
    private var roomMicTimer: Timer?
    @Published private(set) var isPaused = false
    /// Muted in the call app: the mic track records silence meanwhile.
    @Published private(set) var isMuted = false
    /// The sub-step each call is in while processing, such as "AssemblyAI is transcribing".
    @Published private(set) var stepDetails: [String: String] = [:]
    /// Each call's progress while it is processed, for the progress card.
    @Published private(set) var progress: [String: ProcessingProgress] = [:]
    /// What was said so far, from AssemblyAI streaming; shown while the call runs, not used for the note.
    /// What was said so far, from AssemblyAI streaming. Its own object, so only the transcript view redraws when
    /// a message arrives, not the whole window.
    let live = LiveTranscriptModel()
    @AppStorage("liveTranscript") var liveTranscriptEnabled = true
    /// "local", "r2", or "s3". The secret lives in the Keychain; the rest is not secret.
    @AppStorage("storage") var storage = "local"
    @AppStorage("cloudEndpoint") var cloudEndpoint = ""
    @AppStorage("cloudBucket") var cloudBucket = ""
    @AppStorage("cloudRegion") var cloudRegion = "us-east-1"
    @AppStorage("cloudAccessKeyID") var cloudAccessKeyID = ""
    @AppStorage("cloudKeepLocalDays") var cloudKeepLocalDays = 30
    private var liveSessions: [LiveTranscriber] = []
    private var liveTitling: Task<Void, Never>?
    private var liveStart = Date()
    /// When the open streaming sessions started, to log the time AssemblyAI bills.
    private var liveOpened: Date?
    private var liveNaming: Task<Void, Never>?
    /// One voice model for the pipeline and the live names, loaded once.
    private let embeddings = FluidEmbeddingProvider()
    /// 0 means on. Otherwise Mossad is off until this time (seconds since 1970; `.infinity` for "until I turn it on").
    @AppStorage("offUntil") private var offUntil: Double = 0
    private var resumeTimer: Timer?

    var isOn: Bool { offUntil == 0 }
    /// Live loudness of your mic and of the call audio, for the waveform.
    var meters: (me: LevelMeter, them: LevelMeter) { (recorder.meMeter, recorder.themMeter) }
    var offUntilDate: Date? { offUntil == 0 || offUntil == .infinity ? nil : Date(timeIntervalSince1970: offUntil) }
    @Published private(set) var meetings: [CallRecord] = []
    @Published private(set) var processing = 0
    /// The window's title is hidden, but it names the page for the Window menu, Mission Control, and the Dock.
    @Published var section: Section = .meetings { didSet { window?.title = section.rawValue } }
    /// The main window is in full screen, where the traffic lights leave the sidebar.
    @Published private(set) var fullScreen = false
    @Published var selectedMeetingID: String?
    @Published var namingCallID: String?
    var personToOpen: String?
    /// The one controller, for the app delegate's Dock handling.
    nonisolated(unsafe) static weak var current: AppController?
    /// Checks GitHub releases for new versions; never in the UI preview.
    private(set) lazy var updater = Updater(start: !CommandLine.arguments.contains("--ui-preview") && !Rehearsal.isOn) { [weak self] in self?.isRecording ?? false }
    /// Whether the main window can be seen. A window on another desktop or behind others keeps its views
    /// alive, so animations check this and stop while it is hidden.
    @Published private(set) var windowVisible = false
    private var occlusionObserver: NSObjectProtocol?
    /// Calendar events still to come, for the Upcoming list and the menu bar.
    /// The chosen calendars' events for the next days; `upcoming` filters them against the meetings.
    @Published private(set) var calendarEvents: [CalendarEventInfo] = [] {
        didSet { noRecordGate.update(events: calendarEvents) }
    }
    /// The upcoming meetings the owner chose not to record.
    @Published private(set) var noRecord = NoRecordBook()
    private let noRecordGate = NoRecordGate()
    /// Calls still to come, without the ones being recorded or already recorded.
    var upcoming: [UpcomingMeeting] { UpcomingMeeting.from(calendarEvents, recorded: meetings) }
    /// The Mac's calendars, for the choice in Settings.
    @Published private(set) var calendars: [CalendarInfo] = []
    /// The calendars Mossad reads; saved once chosen, and defaulted to the owner's own on first use.
    @Published var chosenCalendars: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "calendarIDs") ?? []) {
        didSet {
            UserDefaults.standard.set(Array(chosenCalendars), forKey: "calendarIDs")
            calendar.choose(chosenCalendars)
            refreshUpcoming()
        }
    }
    private var upcomingTimer: Timer?
    /// The Meetings search text; a tag click sets it to "#Tag".
    @Published var meetingQuery = ""
    /// Set to open the Chat tab on a new chat.
    @Published var newChatRequest = 0
    lazy var chats = ChatStore(directory: paths.chats)
    /// A meeting to open and play from a time; the meeting view takes it when it appears.
    @Published var seekRequest: SeekRequest?

    struct SeekRequest: Equatable {
        let callID: String
        let at: TimeInterval
        /// False marks the line instead of playing from it.
        var play = true
        /// False only opens the Transcript tab, with no line marked.
        var mark = true
    }
    /// When the last bookmark was made, so the controls can confirm it.
    @Published private(set) var lastBookmark: Date?
    private var bookmarkKey: GlobalHotKey?

    let paths = Paths.live
    let library: VoiceLibrary
    let keychain = Keychain.app
    /// Every billed AssemblyAI and Claude request, for the costs in Analytics.
    let usage = UsageLog(directory: Paths.live.usage)
    let permissions = PermissionsMonitor()
    private let detection = DetectionService(mic: MicUsageProbe(), tabs: BrowserTabProbe(), windows: WindowTitleProbe(),
                                             mute: AccessibilityMuteProbe())
    private let calendar = EventKitCalendarSource()
    private let notifier = Notifier()
    private var pipeline: Pipeline!
    /// Used only on `CaptureQueue.queue`.
    private nonisolated let recorder: CallRecorder
    private var window: NSWindow?
    private var trafficLights: TrafficLights?
    /// The menu bar panel shown in a window, for a preview's screenshots.
    var panelPreviewWindow: NSWindow?
    private var housekeeping: Timer?
    private var outputWatcher: OutputDeviceWatcher?
    private var browserLaunchObserver: NSObjectProtocol?

    @AppStorage("deleteRecordings") var deleteRecordings = false
    @AppStorage("recordingDays") var recordingDays = 90
    @AppStorage("ownerName") var ownerName = NSFullUserName()
    @AppStorage("organization") var organization = ""
    @AppStorage("voiceFingerprints") var voiceFingerprints = true
    /// The provider and model for each job. Keys stay in the Keychain; these names are not secret.
    @AppStorage("transcriptionProvider") var transcriptionProvider = TranscriptionProvider.assemblyai
    @AppStorage("transcriptionModel") var transcriptionModel = ""
    @AppStorage("aiProvider") var aiProvider = AIProvider.anthropic
    @AppStorage("aiModel") var aiModel = ""
    /// The local AI server's address, such as Ollama's http://localhost:11434/v1. Meeting text goes nowhere else.
    @AppStorage("localServerURL") var localServerURL = LocalServer.ollama.absoluteString
    /// The provider and key the "Latest" models were last read for.
    private var latestModelsSignature = ""
    /// The picked OpenRouter model's rating, from its listed prices.
    @Published var openRouterRating: Rating?
    /// Counts the local server checks, so the model menu reads the server's list again after one.
    @Published var localServerChecks = 0
    @AppStorage("mailProvider") var mailProvider = MailProvider.resend
    @AppStorage("mailDomain") var mailDomain = ""
    @AppStorage("mailEurope") var mailEurope = false
    @AppStorage("mailRegion") var mailRegion = "us-east-1"
    @AppStorage("mailAccessKeyID") var mailAccessKeyID = ""
    /// Where meetings sync: iCloud (the default), the owner's own server, or nowhere.
    @AppStorage("syncWith") var syncWith: SyncChoice = .icloud
    /// The owner's server, such as https://notes.example.com; the secret is in the Keychain.
    @AppStorage("serverAddress") var serverAddress = ""
    /// Puts the server's address and secret in iCloud Keychain, so the iPhone finds it on its own.
    @AppStorage("serverOnPhone") var serverOnPhone = true
    /// Where AI apps connect, as the server reported it.
    @AppStorage("serverMCP") var serverMCP = ""
    /// Whether the server has an AI key for the chat on share pages.
    @AppStorage("serverHasChat") var serverHasChat = false
    @AppStorage("shareAIKey") var shareAIKey = true
    var syncRunning = false
    /// The server learns the owner's name and time zone once a launch, for the MCP's answers and dates.
    var serverConfigSent = false
    var syncAgain = false
    /// The sync engine for the chosen store, rebuilt when the choice or the server changes.
    var syncEngine: (key: String, sync: CloudSync)?
    /// With iCloud sync and a server set up, the server keeps a copy of the meetings for ChatGPT.
    var mirrorEngine: (key: String, sync: CloudSync)?
    @Published var syncActivity = SyncActivity()
    @Published var shareBook = ShareBook()
    /// The meeting the Share sheet is open for.
    @Published var sharingCallID: String?
    /// The meeting whose "Transcribe again" sheet is open.
    @Published var transcribingAgainCallID: String?
    @AppStorage("coachEnabled") var coachEnabled = false
    /// Calls that start before this (seconds since 1970) are not coached, so turning the coach on does not review years of calls.
    @AppStorage("coachSince") var coachSince: Double = 0
    @AppStorage("commitmentsSince") var commitmentsSince: Double = 0
    @AppStorage("coachEmailEnabled") var coachEmailEnabled = false
    @AppStorage("coachMonthlyEmail") var coachMonthlyEmail = false
    @AppStorage("coachLastMonthEmail") var coachLastMonthEmail: Double = 0
    @AppStorage("coachEmailTo") var coachEmailTo = ""
    @AppStorage("coachEmailFrom") var coachEmailFrom = ""
    @AppStorage("coachLastEmail") var coachLastEmail: Double = 0
    @Published var coaching = false
    /// Bumped after each review so open Coach tabs reload from disk.
    @Published var coachVersion = 0
    /// Bumped when chats change on another device, so the Chat list reloads.
    @Published var chatsVersion = 0
    @Published var commitmentsVersion = 0
    var findingCommitments = false
    private var iCloudTimer: Timer?
    /// The search palette (Command-K) and its index, kept up to date as meetings, tasks, and chats change.
    let search = SearchModel()
    var searchObservers: [AnyCancellable] = []
    /// Bumped by `openPerson`, so a People page already open selects the person too.
    @Published var personRequests = 0
    /// A task or a chat to select when its page shows; the page clears it.
    @Published var taskToOpen: UUID?
    @Published var chatToOpen: UUID?

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
        // A preview only looks: its lines would fill the owner's log with starts that recorded nothing.
        Log.writesFile = !CommandLine.arguments.contains("--ui-preview")
        library = VoiceLibrary(directory: paths.voices)
        recorder = Self.makeRecorder(paths: paths)
        Self.current = self
        // Before the sync choice existed, turning iCloud sync off was its own switch.
        if UserDefaults.standard.object(forKey: "syncWith") == nil, UserDefaults.standard.object(forKey: "iCloudSync") as? Bool == false {
            syncWith = .off
        }
        shareBook = ShareBook.load(from: paths.shares)
        noRecord = NoRecordBook.load(from: paths.noRecord)
        noRecordGate.update(book: noRecord)
        noRecordGate.persistSession(in: paths.noRecord)
        // The chosen calendars apply before anything matches a call to an invite.
        calendar.choose(UserDefaults.standard.stringArray(forKey: "calendarIDs").map(Set.init))
        rebuildPipeline()
        observeForSearch()

        // Development hook: `--ui-preview` opens the UI on $MOSSAD_ROOT with no detection, recording, or
        // processing, so the screens can be checked while the installed copy records a call.
        let preview = CommandLine.arguments.contains("--ui-preview")
        // Rehearsal only walks through setup: like a preview, it starts no detection, recording, processing, or sync.
        let inert = preview || Rehearsal.isOn
        // Reading the calendar records nothing, so the preview shows the real upcoming meetings too.
        if inert { refreshUpcoming() }
        if !inert {
            enableLaunchAtLoginOnce()
            notifier.onOpen = { [weak self] callID in self?.openNaming(callID) }
            notifier.onRecord = { [weak self] bundleID, platform in
                guard let self, case .idle = self.status else { return }
                self.detection.forceStart(bundleID: bundleID, platform: platform)
            }
            notifier.onNotACall = { [weak self] call in self?.quietUnconfirmed(call) }
            for answer in UnconfirmedDismissals(data: UserDefaults.standard.data(forKey: "notACall")).active(at: Date()) {
                detection.dismissUnconfirmed(answer.call, until: answer.until)
            }

            let detection = detection
            let recorder = recorder
            detection.onEvent = { @Sendable [weak self] event in
                // Read the call's audio processes on the detection queue, where they were just computed.
                let ids = detection.audioProcessIDs
                let meetingID = detection.meetingID
                let forced = detection.callIsForced
                guard let self else { return }
                // Before anything records or streams: a meeting the owner marked stays off the record, for the whole
                // call session (a late end, a mic gap, Off then On, a restart); the owner's Record wins. At launch the calendar comes a moment
                // after detection, so the first call waits for it.
                switch event {
                case .started(let platform, let bundleID, let at):
                    self.noRecordGate.waitForCalendar(timeout: 3)
                    if self.noRecordGate.blocksStart(platform: platform, bundleID: bundleID, meetingID: meetingID, at: at, forced: forced) {
                        Log.info("Not recording \(platform.displayName): the owner chose not to record this meeting")
                        return
                    }
                case .ended(let at, _):
                    if self.noRecordGate.callEnded(at: at) { return }
                }
                // Recorder commands go straight from the detection queue to the capture queue, so they keep
                // the detector's order relative to the process updates below. The UI follows on the main actor.
                CaptureQueue.queue.async { self.capture(event, processIDs: ids, meetingID: meetingID, recorder: recorder) }
                Task { @MainActor in self.show(event) }
            }
            detection.onUnconfirmed = { @Sendable [weak self] call in
                Task { @MainActor in
                    guard let self, case .idle = self.status else { return }
                    self.notifier.postUnconfirmed(call)
                    // A missing permission is said one time a day, not on each use of the mic.
                    if call.reason == .noAutomation { self.quietUnconfirmed(call) }
                }
            }
            detection.onMuteChange = { @Sendable [weak self] muted in
                // A call that stays off the record has no recorder and no menu state to follow.
                if self?.noRecordGate.isBlockingCall == true { return }
                CaptureQueue.queue.async { recorder.setMuted(muted) }
                Task { @MainActor in
                    // A change that arrives after the end of its call must not leave the menu on "muted".
                    guard let self, self.isRecording else { return }
                    self.isMuted = muted
                }
            }
            detection.onCallProcesses = { @Sendable [weak self] ids in
                self?.noRecordGate.seen(at: Date())
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
            _ = updater
            bookmarkKey = GlobalHotKey { [weak self] in self?.bookmarkCurrentCall() }

            Task { await runHousekeeping() }
            refreshUpcoming()
            // Chats and notes from the phone arrive within five minutes.
            iCloudTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                // Not while recording: the call itself syncs once it is written, and the recording gets the disk and network.
                Task { @MainActor in if self?.isRecording == false { self?.syncNow() } }
            }
            upcomingTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshUpcoming() }
            }
            housekeeping = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                Task { await self?.runHousekeeping() }
                Task { @MainActor in self?.refreshLatestModels() }
            }
            ProcessingQueue(paths: paths).recoverInterrupted()
        }
        refresh()
        if !inert {
            relinkEmails()
            Task { await track { await self.pipeline.continueSplitMeetings() } }
        }
        Log.info("Mossad started")
        // Development hook: `--show-recording` shows the recording state in the UI without recording anything.
        if preview, CommandLine.arguments.contains("--show-recording") {
            // MOSSAD_RECORDING_PLATFORM=inPerson|zoom|teams|meet and MOSSAD_RECORDING_SECONDS pick what it shows.
            let env = ProcessInfo.processInfo.environment
            let platform = env["MOSSAD_RECORDING_PLATFORM"].flatMap(Platform.init(rawValue:)) ?? .meet
            let seconds = env["MOSSAD_RECORDING_SECONDS"].flatMap(Double.init) ?? 75
            status = .recording(platform, since: Date().addingTimeInterval(-seconds))
        }
        if preview, CommandLine.arguments.contains("--show-muted") { isMuted = true }
        if !inert {
            backfillSummaries()
            backfillTitlesAndDecisionTimes()
            // The coach's reads on people: a minute after launch, so a call being processed goes first.
            Task {
                try? await Task.sleep(for: .seconds(60))
                if coachEnabled { await writePersonBriefs(PersonBriefWriter.due(profile: coachProfile, records: meetings, owner: ownerName)) }
            }
        }
        // Development hook: `--regenerate-summaries` writes new summaries for today's finished meetings.
        if !inert, CommandLine.arguments.contains("--regenerate-summaries") {
            let today = meetings.filter { Calendar.current.isDateInToday($0.start) && $0.status == .written }.map(\.id)
            Task { for id in today { await track { await self.pipeline.regenerateSummary(id) } } }
        }
        if preview { applyLivePreview() }
        if let failure = Self.errorPreview("sync") {
            var status = SyncStatus()
            status.show(failure)
            syncActivity = SyncActivity(last: Date().addingTimeInterval(-7200), status: status)
        }
        if preview, let update = ProcessInfo.processInfo.environment["MOSSAD_UPDATE_PREVIEW"] { updater.applyPreview(update) }
        // Development hook: `--light` shows the UI in light mode, to check both looks.
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        // Development hook: `MOSSAD_APPEARANCE=dark|light` picks the look of a preview, to capture both.
        if preview, let look = ProcessInfo.processInfo.environment["MOSSAD_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
        }
        // The high-contrast appearances carry the tokens' Increase Contrast values.
        if PreviewAccessibility.increaseContrast {
            let dark = (NSApp.appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            NSApp.appearance = NSAppearance(named: dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
        }
        // Development hook: `--open-naming` opens "Who is speaking?" for the first call that needs names.
        if CommandLine.arguments.contains("--open-naming"), let first = callsNeedingNames.first {
            DispatchQueue.main.async { self.openNaming(first.id) }
        }
        // Development hook: `--open-window [Meetings|People|Settings|Log]`, or `MenuPanel` in a preview for the
        // menu bar panel's content in a window of its own.
        if let i = CommandLine.arguments.firstIndex(of: "--open-window") {
            let name = CommandLine.arguments.dropFirst(i + 1).first
            if preview, name == "MenuPanel" {
                DispatchQueue.main.async { self.openPanelPreview() }
                return
            }
            // `--open-window Onboarding` opens setup alone; MOSSAD_ONBOARDING_STEP picks the step in a preview.
            if name == "Onboarding" {
                DispatchQueue.main.async { self.openOnboarding() }
                return
            }
            let section = Section.allCases.first { $0.rawValue == name } ?? .meetings
            DispatchQueue.main.async { self.open(section) }
        }
        // Development hook: `MOSSAD_SEARCH=<query>` opens the search palette with that query.
        if preview, let query = ProcessInfo.processInfo.environment["MOSSAD_SEARCH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.openSearch(query) }
        }
        // Development hook: `MOSSAD_PERSON` opens that person's page.
        if let person = ProcessInfo.processInfo.environment["MOSSAD_PERSON"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openPerson(person) }
        }
    }

    // MARK: State

    /// The calendar title of the call being recorded, when it is known already.
    var recordingTitle: String? { meetings.first { $0.status == .recording && $0.titleSource != .platform }?.title }

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
        meetings = Self.previewFailures(MeetingIndex(paths: paths).all())
    }

    /// Development hook, in a preview only: `MOSSAD_ERROR_PREVIEW=sync,chat,meetingChat,coach,org,processing,failed`
    /// shows those error cards with sample errors, so each one can be captured without breaking anything.
    static func errorPreview(_ surface: String) -> FriendlyError? {
        guard CommandLine.arguments.contains("--ui-preview"),
              let list = ProcessInfo.processInfo.environment["MOSSAD_ERROR_PREVIEW"]?.split(separator: ","),
              list.contains(Substring(surface)) else { return nil }
        return ErrorPreview.sample(surface == "meetingChat" ? "chat" : surface)
    }

    /// `processing` puts the newest meeting back in its summary step after two busy replies; `failed` marks it
    /// failed with a raw gateway page as its reason. Only in memory.
    private static func previewFailures(_ records: [CallRecord]) -> [CallRecord] {
        guard CommandLine.arguments.contains("--ui-preview"),
              let list = ProcessInfo.processInfo.environment["MOSSAD_ERROR_PREVIEW"]?.split(separator: ","),
              let i = records.indices.filter({ records[$0].status == .written }).max(by: { records[$0].start < records[$1].start })
        else { return records }
        var records = records
        if list.contains("processing") {
            records[i].status = .identified
            records[i].attempts = 2
            records[i].failureReason = "Anthropic error 529"
            records[i].nextAttempt = Date().addingTimeInterval(240)
        } else if list.contains("failed") {
            records[i].status = .failed
            records[i].failedStep = .recorded
            records[i].attempts = 3
            records[i].failureReason = "AssemblyAI HTTP 502: <html><head><title>502 Bad Gateway</title></head><body><center><h1>502 Bad Gateway</h1></center></body></html>"
        }
        return records
    }

    func hasKey(_ key: APIKey) -> Bool { keychain.get(key) != nil }

    /// Reads the provider's model list off the main thread when the provider or key changed, or once a day, so the
    /// "Latest" choices follow new models. A changed model rebuilds the pipeline.
    func refreshLatestModels() {
        let provider = aiProvider, key = provider.key.flatMap { keychain.get($0) }
        let signature = "\(provider.rawValue)-\(key?.hashValue ?? 0)"
        guard !LatestModel.aliases(for: provider).isEmpty, key != nil,
              signature != latestModelsSignature || LatestModelCache.shared.needsRefresh(provider) else { return }
        latestModelsSignature = signature
        Task.detached { [weak self] in
            guard await LatestModelCache.shared.refresh(provider, apiKey: key) else { return }
            await MainActor.run {
                guard let self, self.aiProvider == provider, LatestModel.isAlias(self.aiModel) else { return }
                Log.info("The latest \(provider.displayName) model is now \(provider.resolvedModel(self.aiModel))")
                self.rebuildPipeline()
            }
        }
    }

    /// The local server's address as typed, or Ollama's when it does not read as an address.
    var localServerBase: URL { LocalServer.url(from: localServerURL) ?? LocalServer.ollama }

    /// The chosen AI model, or nil without its key (or without a picked OpenRouter or local server model).
    var languageModel: (any LanguageModel)? {
        let key = aiProvider.key.flatMap { keychain.get($0) }
        guard key != nil || !aiProvider.requiresKey, !(aiModel.isEmpty && aiProvider.defaultModel.isEmpty) else { return nil }
        return aiProvider.model(aiModel, apiKey: key, usage: usage, serverURL: localServerBase)
    }

    var mailSettings: MailSettings {
        MailSettings(from: coachEmailFrom.trimmingCharacters(in: .whitespaces), domain: mailDomain, europe: mailEurope,
                     region: mailRegion, accessKeyID: mailAccessKeyID)
    }

    /// Recreates the pipeline with the current keys and settings.
    func rebuildPipeline() {
        refreshLatestModels()
        updateSharedAIKey()
        updateSharedServer()
        let owner = ownerName.trimmingCharacters(in: .whitespaces).isEmpty ? NSFullUserName() : ownerName
        let organization = organization.trimmingCharacters(in: .whitespaces)
        let provider = transcriptionProvider
        let transcriber: Transcribing = if let key = provider.key {
            keychain.get(key).map { provider.transcriber(model: transcriptionModel, apiKey: $0, usage: usage) } ?? MissingKeyTranscriber(service: provider.displayName)
        } else {
            provider.transcriber(model: transcriptionModel, apiKey: "", usage: usage)
        }
        let summarizer: Summarizing? = languageModel.map { LLMSummarizer(llm: $0, ownerName: owner, organization: organization) }
        let notifier = notifier
        pipeline = Pipeline(paths: paths, transcriber: transcriber, library: library, embeddings: embeddings,
                            calendar: calendar, summarizer: summarizer, notify: { record in
                                Task { @MainActor in notifier.postNewVoices(record) }
                            }, ownerName: owner, voiceFingerprints: voiceFingerprints,
                            onStep: { [weak self] record in
                                Task { @MainActor in self?.update(record) }
                            },
                            onDetail: { [weak self] id, text in
                                Task { @MainActor in self?.stepDetails[id] = text }
                            },
                            onProgress: { [weak self] id, p in
                                Task { @MainActor in self?.progress[id] = p }
                            },
                            titles: { [paths] in OrgChart.contextLines(for: $0, paths: paths) })
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
        CaptureQueue.queue.async {
            recorder.skip()
            Task { @MainActor in self.refresh() }
        }
        status = .idle
        isPaused = false
        stopLive()
        updater.callEnded()
    }

    /// Ends the recording now and processes it. The detector still sees this call, so it does not start a
    /// new recording until the call really ends.
    func stopCurrentCall() {
        let recorder = recorder
        CaptureQueue.queue.async {
            guard let record = recorder.end(at: Date(), trimTo: nil, byPerson: true) else {
                Task { @MainActor in self.refresh() }
                return
            }
            Task { @MainActor in
                self.refresh()
                await self.track { await self.pipeline.process(record.id) }
            }
        }
        isMuted = false
        status = .idle
        isPaused = false
        stopLive()
        updater.callEnded()
    }

    /// Development hooks for screenshots, in a preview only, with nothing recorded or sent:
    /// `MOSSAD_LIVE=<live.json>` shows those lines and some audio levels for a meeting saved as recording,
    /// `MOSSAD_MUTED=1` shows the muted note, and `MOSSAD_PROGRESS=upload|queued|summarizing` shows that progress
    /// for each meeting being processed.
    private func applyLivePreview() {
        let env = ProcessInfo.processInfo.environment
        if let path = env["MOSSAD_LIVE"], let transcript = try? LiveTranscript.load(from: URL(fileURLWithPath: path)) {
            live.show(transcript)
            for i in 0..<160 {
                let speech = { (phase: Double) -> Float in
                    let v = abs(sin(Double(i) * 0.37 + phase)) * abs(sin(Double(i) * 0.11 + phase * 2))
                    return v > 0.25 ? Float(0.02 + v * 0.12) : 0
                }
                recorder.meMeter.record(speech(0))
                recorder.themMeter.record(speech(1.7))
            }
        }
        if env["MOSSAD_MUTED"] == "1" { isMuted = true }
        if let state = env["MOSSAD_PROGRESS"] {
            for r in meetings {
                guard let step = ProcessingStep(status: r.status) else { continue }
                var p = ProcessingProgress(step: state == "summarizing" ? .summarizing : step, started: Date().addingTimeInterval(-134))
                let room = r.platform == .inPerson
                switch state {
                case "upload": p.tracks = room ? [.me: .uploading(0.42)] : [.me: .done, .them: .uploading(0.42)]
                case "queued": p.tracks = room ? [.me: .queued] : [.me: .transcribing, .them: .queued]
                default: p.detail = "Claude is writing the summary"
                }
                progress[r.id] = p
            }
        }
    }

    /// Marks this moment of the call as important. Also bound to ⌃⌥B everywhere.
    func bookmarkCurrentCall() {
        guard case .recording = status, !isPaused else { return }
        let recorder = recorder
        CaptureQueue.queue.async {
            recorder.bookmark()
            Task { @MainActor in self.refresh() }
        }
        lastBookmark = Date()
    }

    /// Adds a bookmark from the player and returns its offset, so the note popover can name it. While this call
    /// records, the recorder marks the live moment; after the call, the saved call gets one at `offset`.
    func addBookmark(callID: String, at offset: TimeInterval) async -> TimeInterval? {
        let recorder = recorder
        let live: TimeInterval?? = await withCheckedContinuation { done in
            CaptureQueue.queue.async {
                guard recorder.currentRecord?.id == callID else { return done.resume(returning: .none) }
                done.resume(returning: .some(recorder.bookmark()))
            }
        }
        if let live {
            if live != nil { lastBookmark = Date() }
            refresh()
            return live
        }
        await pipeline.addBookmark(callID: callID, offset: offset)
        refresh()
        return offset
    }

    /// The note of a bookmark: through the recorder while the call records, else on the saved call.
    func setBookmarkNote(callID: String, offset: TimeInterval, note: String) {
        let recorder = recorder
        Task {
            let live = await withCheckedContinuation { done in
                CaptureQueue.queue.async {
                    done.resume(returning: recorder.currentRecord?.id == callID && recorder.setBookmarkNote(at: offset, note))
                }
            }
            if !live { await pipeline.setBookmarkNote(callID: callID, offset: offset, note: note) }
            refresh()
        }
    }

    /// Records a meeting in a room through the mic, until Stop. Detection ignores calls meanwhile.
    func recordInPerson() {
        guard case .idle = status, isOn, !Rehearsal.isOn else { return }
        let start = Date()
        status = .recording(.inPerson, since: start)
        isPaused = false
        isMuted = false
        let recorder = recorder
        CaptureQueue.queue.async {
            do {
                let id = try recorder.beginManual(at: start)
                Task { @MainActor in
                    self.refresh()
                    await self.findInvite(callID: id, platform: .inPerson, meetingID: nil, start: start, recorder: recorder)
                }
            } catch {
                Log.error("Could not start the in-person recording: \(error)")
                Task { @MainActor in if case .recording(.inPerson, let since) = self.status, since == start { self.status = .idle } }
            }
        }
        startLive(reset: true)
    }

    func pauseCurrentCall() {
        guard case .recording = status else { return }
        let recorder = recorder
        CaptureQueue.queue.async { recorder.pause() }
        isPaused = true
        stopLive()
    }

    func resumeCurrentCall() {
        guard case .recording = status else { return }
        let recorder = recorder
        CaptureQueue.queue.async { recorder.resume() }
        isPaused = false
        startLive(reset: false)
    }

    /// Opens one streaming session per track. Billed while open, so only while recording and not paused.
    private func startLive(reset: Bool) {
        stopLive()
        if reset { live.reset() } else { live.newSession() }
        guard liveTranscriptEnabled, case .recording(_, let since) = status, let key = keychain.get(.assemblyai) else { return }
        liveStart = since
        // In a room the mic hears everyone and there is no call audio: one stream, with speaker labels, shown
        // like call audio so each voice gets its own name.
        let room: Bool = if case .recording(.inPerson, _) = status { true } else { false }
        // A new call's stream starts with the file; after a pause it starts where the file is now.
        let themOffset = reset ? 0 : (room ? recorder.meDuration : recorder.themDuration)
        let dir = paths.callDirectory(CallRecorder.callID(for: since))
        let themURL = dir.appendingPathComponent(room ? Track.me.fileName : Track.them.fileName)
        // Saved for the current_call tool in Chat and in other AI apps.
        live.fileURL = dir.appendingPathComponent(LiveTranscript.fileName)
        let streams: [(Track, AudioSink)] = room ? [(.me, recorder.meSink)] : [(.me, recorder.meSink), (.them, recorder.themSink)]
        for (track, sink) in streams {
            let source: Track = room ? .them : track
            let session = LiveTranscriber(apiKey: key, speakers: source == .them) { [weak self] message in
                Task { @MainActor in
                    guard let self else { return }
                    self.live.apply(message, source: source, at: Date().timeIntervalSince(self.liveStart),
                                    audioOffset: source == .them ? themOffset : 0)
                }
            }
            sink.set { buffer in session.send(buffer) }
            liveSessions.append(session)
        }
        liveOpened = Date()
        // A pause cancels the timer, so a resumed call starts it again; the recorder keeps only the first title.
        startLiveTitling(callID: CallRecorder.callID(for: since))
        if voiceFingerprints { startLiveNaming(themURL: themURL, room: room) }
    }

    /// Once per call, after about 5 minutes of live transcript, asks a small model for a provisional title so the
    /// menu and the list show it while the call runs. The summary's title replaces it.
    private func startLiveTitling(callID: String) {
        let chosen = aiProvider.resolvedModel(aiModel)
        let key = aiProvider.key.flatMap { keychain.get($0) }
        guard key != nil || !aiProvider.requiresKey, let model = aiProvider.smallModel ?? (chosen.isEmpty ? nil : chosen) else { return }
        let titler = LiveTitler(llm: aiProvider.model(model, apiKey: key, usage: usage, serverURL: localServerBase))
        let owner = ownerName
        liveTitling?.cancel()
        liveTitling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled, let self, self.isRecording(callID) else { return }
            // A calendar title or the owner's title wins, so no model call is spent on a title nobody shows.
            let recorder = self.recorder
            let hasTitle = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                CaptureQueue.queue.async {
                    let r = recorder.currentRecord
                    done.resume(returning: r?.id != callID || r?.calendarTitle != nil || r?.customTitle != nil)
                }
            }
            guard !hasTitle else { return }
            let text = self.live.snapshot.text(owner: owner, since: nil)
            guard let title = await UsageContext.$callID.withValue(callID, operation: { await titler.title(transcript: text) }),
                  !Task.isCancelled, self.isRecording(callID) else { return }
            CaptureQueue.queue.async {
                recorder.setGeneratedTitle(title, forCall: callID)
                Task { @MainActor in self.refresh() }
            }
        }
    }

    private func isRecording(_ callID: String) -> Bool {
        if case .recording(_, let since) = status { return CallRecorder.callID(for: since) == callID }
        return false
    }

    /// Every 20 s, names the call's voices that the voice library knows, for the live transcript and current_call.
    private func startLiveNaming(themURL: URL, room: Bool) {
        let namer = LiveSpeakerNamer(library: library, provider: embeddings, room: room)
        liveNaming = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let snapshot = self?.live.snapshot, !Task.isCancelled else { return }
                let names = await Task.detached(priority: .utility) { await namer.names(for: snapshot, themURL: themURL) }.value
                guard !Task.isCancelled, names.count > snapshot.names.count else { continue }
                Log.info("Live transcript: \(names.count) voices named")
                self?.live.setNames(names)
            }
        }
    }

    private func stopLive() {
        live.save()
        liveNaming?.cancel()
        liveNaming = nil
        liveTitling?.cancel()
        liveTitling = nil
        recorder.meSink.set(nil)
        recorder.themSink.set(nil)
        liveSessions.forEach { $0.stop() }
        if let opened = liveOpened, !liveSessions.isEmpty {
            let seconds = Date().timeIntervalSince(opened) * Double(liveSessions.count)
            let id = meetings.first { $0.status == .recording }?.id
            UsageContext.$callID.withValue(id) { usage.record(service: .assemblyai, purpose: .live, model: nil, audioSeconds: seconds) }
        }
        liveOpened = nil
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

    func setRecording(_ choice: RecordingChoice, for meeting: UpcomingMeeting) {
        noRecord.set(choice, for: meeting)
        noRecord.removeExpired(now: Date())
        noRecordGate.update(book: noRecord)
        do { try noRecord.save(to: paths.noRecord) } catch { Log.error("Saving the recording choice failed: \(error)") }
    }

    func turnOn() {
        offUntil = 0
        resumeTimer?.invalidate()
        resumeTimer = nil
        if !Rehearsal.isOn { detection.start() }
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

    /// Opens the People page on one person; the page picks the name up when it loads.
    func openPerson(_ name: String) {
        personToOpen = name
        personRequests += 1
        open(.people)
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

    /// The owner's own title; nil or blank goes back to the automatic one.
    func setTitle(callID: String, _ title: String?) {
        Task {
            await pipeline.setTitle(callID: callID, title)
            refresh()
        }
    }

    func setTags(callID: String, _ tags: [String]) {
        Task {
            await pipeline.setTags(callID: callID, tags)
            refresh()
        }
    }

    /// Opens a meeting and plays it from a time.
    func openMeeting(_ callID: String, at time: TimeInterval) {
        seekRequest = SeekRequest(callID: callID, at: time)
        openMeeting(callID)
    }

    /// Opens a meeting's transcript at a moment and marks the line, without playing.
    func showMoment(_ callID: String, at time: TimeInterval) {
        seekRequest = SeekRequest(callID: callID, at: time, play: false)
        openMeeting(callID)
    }


    func startChat() {
        newChatRequest += 1
        open(.chat)
    }

    func chatAnswer(_ question: String, history: [ChatMessage], about callID: String? = nil,
                    onStep: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let llm = languageModel else { throw MissingAPIKey(service: aiProvider.displayName) }
        return try await ChatAgent(llm: llm, ownerName: ownerName).answer(question, history: history, records: meetings, paths: paths,
                                                                          about: callID, onStep: onStep)
    }

    /// Writes the chat's short summary for later chats to recall, and syncs it.
    func summarizeChat(_ id: UUID) {
        guard let llm = languageModel, let chat = chats.all().first(where: { $0.id == id }) else { return }
        let owner = ownerName, store = chats
        Task {
            guard let summary = try? await ChatAgent(llm: llm, ownerName: owner).summarize(chat) else { return }
            guard var latest = store.all().first(where: { $0.id == id }) else { return }
            latest.summary = summary
            try? store.save(latest)
            syncNow()
        }
    }

    /// Opens a `mossad://call/<id>?t=<seconds>` link from a chat answer.
    func openLink(_ url: URL) -> Bool {
        guard let link = ChatLink.parse(url), meetings.contains(where: { $0.id == link.callID }) else { return false }
        if let at = link.at { openMeeting(link.callID, at: at) } else { openMeeting(link.callID) }
        return true
    }

    /// Shows every meeting with this tag.
    func showTag(_ tag: String) {
        meetingQuery = "#\(tag)"
        open(.meetings)
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

    /// Asks for skipped voices again.
    func restoreSpeakers(callID: String, keys: [String]) {
        Task {
            await pipeline.restoreSpeakers(callID: callID, keys: keys)
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
        guard !Rehearsal.isOn, let archive = cloudArchive else { return }
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
        // While uploading, the list and the menu show the percent of the track that is furthest behind.
        if let p = progress[r.id], p.step == .transcribing, p.detail == nil, let t = p.slowestUpload,
           let line = p.trackLine(t, service: transcriptionProvider.displayName, room: r.platform == .inPerson) {
            return line
        }
        return stepDetails[r.id] ?? ProcessingStep(status: r.status)?.title
    }

    /// A new summary from Claude for a finished meeting; the transcript and names stay.
    /// Once: new summaries for the last 90 days' calls from before topics, kinds, and outcomes, so Analytics has them.
    func backfillSummaries() {
        guard !UserDefaults.standard.bool(forKey: "summaryBackfill2026") else { return runQuestionPass() }
        UserDefaults.standard.set(true, forKey: "summaryBackfill2026")
        let since = Date().addingTimeInterval(-90 * 86_400)
        let ids = meetings.filter { $0.status == .written && $0.start >= since && ($0.kind == nil || $0.tags.isEmpty || $0.hasOutcomes == nil) }.map(\.id)
        Log.info("Writing new summaries for \(ids.count) recent calls")
        Task {
            for id in ids { await track { await self.pipeline.regenerateSummary(id) } }
            refresh()
            runQuestionPass()
        }
    }

    /// Once, after the editorial update: old meetings get a generated title and the times of their decisions.
    /// One meeting at a time, newest first, at utility priority, and never while a call records. The flag is set
    /// when the run ends, so a quit part way continues next launch with the meetings still due.
    func backfillTitlesAndDecisionTimes() {
        let key = "summaryBackfill2026-11"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let ids = SummaryBackfill.due(meetings).map(\.id)
        guard !ids.isEmpty else { return UserDefaults.standard.set(true, forKey: key) }
        Log.info("Updating \(ids.count) older meetings with titles and decision times")
        Task(priority: .utility) { [weak self] in
            let began = Date()
            let done = Set(ids)
            let result = await SummaryBackfill.run(ids: ids) { [weak self] id in
                // Wait out a call; the phone and the owner come first.
                while let self, await self.isRecording { try? await Task.sleep(for: .seconds(30)) }
                guard let self else { return false }
                return await self.runBackfill(id)
            }
            let updated = result.updated
            // Not marked done, so the meetings still due continue next launch.
            if result.paused { Log.info("Backfill paused after \(SummaryBackfill.maxConsecutiveFailures) failures; it continues next launch") }
            else { UserDefaults.standard.set(true, forKey: key) }
            guard let self else { return }
            let cost = self.usage.all().filter { $0.date >= began && $0.purpose == .summary && $0.callID.map(done.contains) == true }.compactMap(\.costUSD).reduce(0, +)
            Log.info("Updated \(updated) meetings" + (cost > 0 ? String(format: " (about $%.2f)", cost) : ""))
            self.refresh()
        }
    }

    private func runBackfill(_ id: String) async -> Bool {
        var ok = false
        await track { ok = await self.pipeline.backfill(id) }
        return ok
    }

    func transcribeAgain(_ id: String, speakers: Int?) {
        Task { await track { await self.pipeline.transcribeAgain(id, speakers: speakers) } }
    }

    func restorePreviousTranscript(_ id: String) {
        Task { await track { await self.pipeline.restorePreviousTranscript(id) } }
    }

    func regenerateSummary(_ id: String) {
        Task { await track { await self.pipeline.regenerateSummary(id) } }
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
            // An in-person recording owns the mic until the person stops it.
            if recorder.isManual {
                Log.info("\(platform.displayName) started during an in-person recording; it keeps recording the room")
                return
            }
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
                    self.notifier.postCannotRecord(FriendlyError(error, context: .recording), platform: platform)
                    // Only clear the status of this call, never of a newer one.
                    if case .recording(_, let since) = self.status, since == at { self.status = .idle } else { self.failedStarts.insert(at) }
                }
            }
        case .ended(let at, let trimTo):
            if recorder.isManual { return }
            Log.info("Call ended")
            guard let record = recorder.end(at: at, trimTo: trimTo) else {
                // A short call is deleted, so its row must leave the list too, or it still looks live.
                Task { @MainActor in self.refresh() }
                return
            }
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

    /// "Not a call": no more warnings for this app and reason for the rest of the day, also after a restart.
    private func quietUnconfirmed(_ call: UnconfirmedCall) {
        let now = Date()
        let until = UnconfirmedDismissals.endOfDay(after: now)
        var answers = UnconfirmedDismissals(data: UserDefaults.standard.data(forKey: "notACall"))
        answers.add(call, until: until, now: now)
        UserDefaults.standard.set(answers.data, forKey: "notACall")
        detection.dismissUnconfirmed(call, until: until)
    }

    /// Call starts whose recording failed, by start time, until the UI has seen them.
    private var failedStarts: Set<Date> = []

    private func show(_ event: DetectorEvent) {
        if case .recording(.inPerson, _) = status { return }
        switch event {
        case .started(let platform, _, let at):
            notifier.clearUnconfirmed()
            // The failure can arrive first: a recording that did not start must not show as one.
            if failedStarts.remove(at) != nil { return }
            status = .recording(platform, since: at)
            isPaused = false
            isMuted = false
            startLive(reset: true)
        case .ended:
            failedStarts.removeAll()
            updater.callEnded()
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
        runCoach()
        runCommitments()
        syncNow()
        processing -= 1
        refresh()
    }

    /// Processes calls waiting in the queue, such as a recording that arrived from the iPhone.
    func processPending() {
        guard !Rehearsal.isOn else { return }
        Task { await track { await self.pipeline.runPending() } }
    }

    private func runHousekeeping() async {
        await track { await self.pipeline.runPending() }
        // Encoding an hour of audio takes seconds, so this stays off the main actor.
        let audio = paths.audio, days = deleteRecordings ? max(1, recordingDays) : nil
        await Task.detached(priority: .utility) {
            Recording.backfill(audioRoot: audio)
            Retention.sweep(audioRoot: audio, recordingsAfterDays: days)
        }.value
        runCoach()
        runCommitments()
        syncNow()
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

    func refreshUpcoming() {
        let calendar = calendar
        calendars = calendar.calendars()
        if UserDefaults.standard.stringArray(forKey: "calendarIDs") == nil, !calendars.isEmpty {
            // The first time, read only the owner's own calendars, not shared or subscribed ones.
            chosenCalendars = CalendarInfo.defaults(calendars, ownerName: ownerName,
                                                    ownerEmail: UserDefaults.standard.string(forKey: "ownerEmail") ?? "")
            Log.info("Calendars: \(calendars.map { "\($0.title) [\($0.account)]\(chosenCalendars.contains($0.id) ? " *" : "")" }.joined(separator: "; "))")
            return
        }
        calendar.choose(UserDefaults.standard.stringArray(forKey: "calendarIDs").map(Set.init))
        Task {
            let now = Date()
            var events = await calendar.events(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(Double(UpcomingMeeting.days) * 86_400))
            // Development hook: `--sample-upcoming` adds two events, since a preview build has no Calendar access.
            if CommandLine.arguments.contains("--sample-upcoming") {
                events += [CalendarEventInfo(title: "Alex / Sam", start: now.addingTimeInterval(1500), end: now.addingTimeInterval(3300),
                                             attendees: ["Alex Rivera", "Sam Carter"], text: "https://meet.google.com/abc-defg-hij", isAllDay: false),
                           CalendarEventInfo(title: "Tech Team Monthly Sync", start: now.addingTimeInterval(86_400), end: now.addingTimeInterval(90_000),
                                             attendees: ["Jordan Lee", "Casey Brooks", "Riley Chen"], text: "", isAllDay: false)]
            }
            calendarEvents = events
        }
    }

    private func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = section.rawValue
            // No system toolbar: each page draws its own toolbar row, and the traffic lights sit in the sidebar card.
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: MainWindow().environmentObject(self).environmentObject(permissions))
            // Without this, every view update re-measures the whole window to set its size limits.
            host.sizingOptions = []
            w.contentViewController = host
            w.setContentSize(NSSize(width: 1240, height: 820))
            w.contentMinSize = NSSize(width: Chrome.windowMinWidth, height: 600)
            occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] note in
                let visible = (note.object as? NSWindow)?.occlusionState.contains(.visible) == true
                Task { @MainActor in if self?.windowVisible != visible { self?.windowVisible = visible } }
            }
            // Development hooks for screenshots: MOSSAD_WINDOW_WIDTH and MOSSAD_WINDOW_HEIGHT (points) size a preview.
            let env = CommandLine.arguments.contains("--ui-preview") ? ProcessInfo.processInfo.environment : [:]
            let previewWidth = env["MOSSAD_WINDOW_WIDTH"].flatMap(Double.init)
            let previewHeight = env["MOSSAD_WINDOW_HEIGHT"].flatMap(Double.init)
            if previewWidth != nil || previewHeight != nil {
                w.setContentSize(NSSize(width: previewWidth ?? 1240, height: previewHeight ?? 820))
            }
            w.center()
            if previewWidth == nil, previewHeight == nil {
                w.setFrameAutosaveName("MossadMain")
                // A frame saved under the older, smaller minimum comes back as it was: widen it to the new one.
                if let content = w.contentView?.frame.size, content.width < Chrome.windowMinWidth {
                    w.setContentSize(NSSize(width: Chrome.windowMinWidth, height: content.height))
                }
            }
            window = w
            trafficLights = TrafficLights(window: w) { [weak self] in
                if self?.fullScreen != $0 { self?.fullScreen = $0 }
            }
        }
        refresh()
        // A preview for screenshots stays behind the owner's windows and never takes focus.
        if CommandLine.arguments.contains("--ui-preview") {
            window?.orderBack(nil)
            return
        }
        // A normal app: the window opens in its own space and never above another app's full-screen window.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}


/// Used when no AssemblyAI key is stored: the call stays queued until a key exists.
struct MissingKeyTranscriber: Transcribing {
    let service: String

    func transcribe(file: URL, track: Track, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [Utterance] {
        throw MissingAPIKey(service: service)
    }
}

/// The live transcript, published at most four times a second: AssemblyAI sends several partial results a second.
@MainActor
final class LiveTranscriptModel: ObservableObject {
    @Published private(set) var transcript = LiveTranscript()
    /// Worked out once per update: the echo filter compares every mic line with every call line.
    @Published private(set) var visibleLines: [LiveTranscript.Line] = []
    private var pending = LiveTranscript()
    private var scheduled = false
    var fileURL: URL?
    /// One write at a time, in order, so an older copy never replaces a newer one.
    private let saves = DispatchQueue(label: "com.dwebber.mossad.live-save", qos: .utility)

    var snapshot: LiveTranscript { pending }

    func newSession() { pending.newSession() }

    /// A saved transcript, shown as is: for a preview's screenshots.
    func show(_ transcript: LiveTranscript) {
        pending = transcript
        publish()
    }

    func setNames(_ names: [String: String]) {
        pending.names = names
        publish()
    }

    func apply(_ message: Data, source: Track, at time: TimeInterval, audioOffset: TimeInterval) {
        guard pending.apply(message, source: source, at: time, audioOffset: audioOffset) else { return }
        publish()
    }

    private var saveScheduled = false

    private func publish() {
        if !scheduled {
            scheduled = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                transcript = pending
                visibleLines = pending.visibleLines
                scheduled = false
            }
        }
        // The file is for Chat and other AI apps, which can wait 2 s. It is written whole each time, so on a long
        // meeting four writes a second added up to about 1 MB/s.
        guard !saveScheduled, fileURL != nil else { return }
        saveScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            saveScheduled = false
            save()
        }
    }

    /// Writes the file now, off the main actor.
    func save() {
        guard let url = fileURL else { return }
        let snapshot = pending
        saves.async { try? snapshot.save(to: url) }
    }

    func reset() {
        pending = LiveTranscript()
        transcript = pending
        visibleLines = []
    }
}
