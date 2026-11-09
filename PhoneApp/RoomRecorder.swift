import AVFoundation
import MossadCore
import SwiftUI
import UIKit

/// Records a meeting in the room through the phone's mic. The store owns it, so a recording outlives its screen.
/// `RoomRecording` decides; this class does what it says with AVFoundation. The audio goes to CAF parts that stay
/// readable if the app stops, and the outbox has the recording from its first second.
@Observable
@MainActor
final class RoomRecorder: NSObject, AVAudioRecorderDelegate {
    enum State { case idle, recording, paused }

    private(set) var rules = RoomRecording()
    /// The last second of levels, 0 to 1, for the meter.
    private(set) var levels: [Float] = Array(repeating: 0, count: 24)
    var error: FriendlyError? = PhoneStore.hook("MOSSAD_ROOM_ERROR").flatMap(ErrorPreview.sample)
    /// The meeting's name as the owner types it; here, so it outlives the screen.
    var title = ""
    /// The recording now, while there is one.
    private(set) var id: String?

    var state: State {
        switch rules.phase {
        case .recording: .recording
        case .paused: .paused
        case .idle, .stopped: .idle
        }
    }

    /// The app's own count of recorded seconds, not the recorder's `currentTime`, which reads 0 once it stopped.
    var elapsed: TimeInterval { rules.elapsed }

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private var dir = URL(fileURLWithPath: NSTemporaryDirectory())
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The last reason the system gave for a failed start or resume, for the error card.
    @ObservationIgnored private var lastFailure: Error?

    struct Stopped {
        let id: String
        let start: Date
        /// The clock time of the stop, so pauses count toward the meeting's end.
        let end: Date
        let counted: TimeInterval
        let title: String?
    }

    /// Starts a recording and returns it, or nil with the reason in `error`.
    func start(into dir: URL) async -> PhoneRecording? {
        guard state == .idle, id == nil else { return nil }
        guard await AVAudioApplication.requestRecordPermission() else {
            error = FriendlyError(kind: .microphoneDenied, context: .recording)
            return nil
        }
        do {
            try Self.prepareSession()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let now = Date()
            let id = CallID.make(now)
            recorder = try makeRecorder(url: RoomAudio.part(id, 1, in: dir))
            self.dir = dir
            self.id = id
            started = now
            error = nil
            rules = RoomRecording()
            rules.start(at: now)
            observe()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RecordingAlerts.requestPermission()
            return PhoneRecording(id: id, start: now, end: now, title: nil)
        } catch {
            Log.error("Room recording could not start: \(error)")
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            // The recorder's own wrapper names the step; the error inside it says what the system refused.
            let inner = (error as? RecorderError)?.underlying ?? error
            self.error = FriendlyError(inner, context: .recording, technical: FriendlyError.clean((error as? LocalizedError)?.errorDescription ?? "\(error)"))
            return nil
        }
    }

    struct RecorderError: LocalizedError {
        let step: String
        let underlying: Error?
        var errorDescription: String? {
            "\(step) failed" + (underlying.map { ": \(($0 as NSError).localizedDescription) (\(($0 as NSError).code))" } ?? "")
        }
    }

    /// The room recording's audio session. A setup the system refuses (OSStatus -50 on one iPhone) falls back to the
    /// next, so recording starts whenever the microphone can record at all. No Bluetooth: with AirPods connected the
    /// room would be recorded from the owner's ear, at telephone quality.
    private static func prepareSession() throws {
        let session = AVAudioSession.sharedInstance()
        let setups: [(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)] = [
            (.record, .spokenAudio, []),
            (.record, .default, []),
            (.playAndRecord, .default, [.defaultToSpeaker]),
        ]
        var last: Error?
        for (category, mode, options) in setups {
            do {
                try session.setCategory(category, mode: mode, options: options)
                try session.setActive(true)
                preferBuiltInMic()
                return
            } catch { last = error }
        }
        throw RecorderError(step: "The audio session", underlying: last)
    }

    /// The iPhone's own microphone hears the room; a wired or USB headset would hear only its wearer.
    private static func preferBuiltInMic() {
        let session = AVAudioSession.sharedInstance()
        if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }), session.preferredInput?.uid != mic.uid {
            do { try session.setPreferredInput(mic) } catch { Log.error("Room recording could not choose the built-in microphone: \(error)") }
        }
        Log.info("Room recording input: \(session.currentRoute.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", "))")
    }

    /// 16-bit PCM at 16 kHz first (what the Mac transcribes), then the microphone's own rate; the join converts.
    private func makeRecorder(url: URL) throws -> AVAudioRecorder {
        let rate = AVAudioSession.sharedInstance().sampleRate
        let choices = [RoomAudio.recordingSettings(), RoomAudio.recordingSettings(sampleRate: rate > 0 ? rate : 44_100),
                       RoomAudio.recordingSettings(sampleRate: 44_100)]
        var last: Error?
        for settings in choices {
            do {
                let r = try AVAudioRecorder(url: url, settings: settings)
                r.isMeteringEnabled = true
                r.delegate = self
                if r.record() { return r }
                r.delegate = nil
                r.deleteRecording()
            } catch { last = error }
        }
        throw RecorderError(step: "The recorder", underlying: last)
    }

    private func observe() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
                let began = type == .began, resume = options.contains(.shouldResume)
                MainActor.assumeIsolated { self?.interruption(began: began, shouldResume: resume) }
            },
            // The audio server restarted: every recorder and session setup is gone.
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    Log.error("Room recording: the audio server restarted")
                    self?.recorderDied()
                }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Self.preferBuiltInMic() }
            },
        ]
    }

    /// Compares what the recorder does with what the screen says, ten times a second.
    private func tick() {
        guard id != nil else { return }
        run(rules.tick(isRecording: recorder?.isRecording ?? false, at: Date()))
        var level: Float = 0
        if state == .recording, let recorder {
            recorder.updateMeters()
            level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 50) / 50))
        }
        levels = Array(levels.dropFirst()) + [level]
    }

    private func interruption(began: Bool, shouldResume: Bool) {
        if began { lastFailure = nil }
        run(rules.interruption(began: began, shouldResume: shouldResume))
    }

    private func recorderDied() {
        guard id != nil else { return }
        recorder?.delegate = nil
        recorder = nil
        run(rules.recorderDied())
    }

    nonisolated func audioRecorderDidFinishRecording(_ r: AVAudioRecorder, successfully flag: Bool) {
        let finished = ObjectIdentifier(r)
        Task { @MainActor in
            // Only a finish of its own: `stop()` lets go of the delegate first.
            guard let recorder = self.recorder, ObjectIdentifier(recorder) == finished else { return }
            Log.error("Room recording: the recorder finished by itself (\(flag ? "cleanly" : "with an error"))")
            self.recorderDied()
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ r: AVAudioRecorder, error: Error?) {
        let failed = ObjectIdentifier(r), text = error.map { "\($0)" } ?? "no detail"
        Task { @MainActor in
            guard let recorder = self.recorder, ObjectIdentifier(recorder) == failed else { return }
            Log.error("Room recording: the encoder failed: \(text)")
            self.recorderDied()
        }
    }

    func pause() { run(rules.ownerPause()) }

    func resume() { run(rules.ownerResume()) }

    private func run(_ actions: [RoomRecording.Action]) {
        for action in actions {
            switch action {
            case .pauseRecorder: recorder?.pause()
            case .resumeRecorder: run(rules.resumed(ok: recordAgain(), newSegment: false))
            case .newSegment: run(rules.resumed(ok: startNewSegment(), newSegment: true))
            case .notify(let alert): RecordingAlerts.notify(alert)
            case .schedule(let alert, let after): RecordingAlerts.schedule(alert, after: after)
            case .cancelAlerts:
                RecordingAlerts.cancel()
                error = nil
            case .tellOwner(let alert): tellOwner(alert)
            }
        }
    }

    /// Records again into the current part; the session may need its setup again after another app had the mic.
    private func recordAgain() -> Bool {
        guard let recorder else { return false }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if recorder.record() { return true }
        } catch { lastFailure = error }
        do {
            try Self.prepareSession()
            if recorder.record() { return true }
        } catch { lastFailure = (error as? RecorderError)?.underlying ?? error }
        return false
    }

    /// A new part, with the session set up again: what the old recorder wrote stays in its own part.
    private func startNewSegment() -> Bool {
        guard let id else { return false }
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        do {
            try Self.prepareSession()
            recorder = try makeRecorder(url: RoomAudio.part(id, rules.segments + 1, in: dir))
            Log.info("Room recording continues in part \(rules.segments + 1)")
            return true
        } catch {
            lastFailure = (error as? RecorderError)?.underlying ?? error
            Log.error("Room recording could not start a new part: \(error)")
            return false
        }
    }

    private func tellOwner(_ alert: RoomRecording.Alert) {
        let failure = lastFailure
        let kind: FriendlyError.Kind
        switch alert {
        case .paused:
            let busy = failure.map { FriendlyError($0, context: .recording).kind == .microphoneBusy } ?? false
            kind = busy ? .microphoneBusy : failure == nil ? .interrupted : .resumeFailed
        case .stopped: kind = .resumeFailed
        }
        error = FriendlyError(kind: kind, context: .recording, technical: failure.map { FriendlyError.clean("\($0)") } ?? "")
        // The pause came from the system, so a VoiceOver user hears it as well as sees it.
        UIAccessibility.post(notification: .announcement, argument: alert == .stopped ? "Recording stopped" : "Recording is paused")
    }

    /// Stops the recording and lets go of the microphone. The store decides what to keep, from the files on disk.
    func stop() -> Stopped? {
        guard let id else { return nil }
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        RecordingAlerts.cancel()
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let stopped = Stopped(id: id, start: started, end: Date(), counted: rules.elapsed, title: t.isEmpty ? nil : t)
        rules.stop()
        self.id = nil
        title = ""
        error = nil
        lastFailure = nil
        levels = Array(repeating: 0, count: levels.count)
        return stopped
    }
}

/// The full-screen recorder as the canvas draws it: the red status capsule, a large timer, the room's level as
/// bars, and one big stop button between pause and the meeting's name. The Mac transcribes after; the audio
/// stays here until it has it.
struct RecordingView: View {
    @State private var confirmShortStop = false
    @Environment(PhoneStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var naming: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 52

    private var recorder: RoomRecorder { store.recorder }

    var body: some View {
        @Bindable var bound = store.recorder
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.l) {
                    status
                    Text(coachClock(recorder.elapsed))
                        .font(.system(size: timerSize, weight: .semibold)).monospacedDigit()
                        .tracking(-timerSize * 0.02)
                        .foregroundStyle(Palette.ink)
                        .contentTransition(.numericText())
                        .accessibilityLabel("Recorded \(duration(recorder.elapsed))")
                    Text(recorder.state == .paused ? "Paused. Nothing is recorded until you resume."
                         : "Keep the iPhone near the people talking.")
                        .textRole(.secondary).foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.center)
                    meter
                    controls.padding(.vertical, Space.s)
                    VStack(alignment: .leading, spacing: Space.s) {
                        PhoneLabel("Meeting name")
                        TextField("What is this meeting? (optional)", text: $bound.title)
                            .textRole(.body)
                            .focused($naming)
                            .padding(.horizontal, Space.m).padding(.vertical, 11)
                            .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    }
                    if let error = recorder.error {
                        ErrorCard(error: error, retryTitle: recorder.state == .paused ? "Resume" : "Try again", retry: !error.canRetry ? nil : recorder.state == .idle ? {
                            recorder.error = nil
                            Task { await store.startRecording() }
                        } : recorder.state == .paused ? { recorder.resume() } : nil)
                    }
                    Text("Mossad on your Mac writes the notes: the transcript, who said what, and the summary.")
                        .textRole(.secondary).foregroundStyle(Palette.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, Space.s)
                }
                .padding(.horizontal, Space.l)
                .padding(.top, Space.s)
            }
            .scrollDismissesKeyboard(.interactively)
            .phonePage()
            .navigationTitle("In-person meeting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if recorder.state == .idle {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.tint(Palette.ink) }
                }
            }
        }
        .interactiveDismissDisabled(recorder.state != .idle)
        .task { if recorder.state == .idle, PhoneStore.hook("MOSSAD_ROOM") == nil { await store.startRecording() } }
    }

    private var status: some View {
        let live = recorder.state == .recording
        return HStack(spacing: 6) {
            Image(systemName: "circle.fill").font(.system(size: 7))
                .foregroundStyle(live ? Palette.recording : Palette.tertiaryMark)
                .symbolEffect(.pulse, isActive: live && !reduceMotion)
                .accessibilityHidden(true)
            Text(live ? "Recording the room" : recorder.state == .paused ? "Paused" : "Ready")
        }
        .textRole(.secondary)
        .fontWeight(.semibold)
        .foregroundStyle(live ? Palette.recording : Palette.secondary)
        .padding(.horizontal, Space.m).padding(.vertical, 5)
        .background(live ? Palette.recordingTint : Palette.fill, in: Capsule())
    }

    /// The last second of the room's level, newest on the right.
    private var meter: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(recorder.levels.enumerated()), id: \.offset) { _, l in
                Capsule()
                    .fill(recorder.state == .recording ? Palette.recording.opacity(0.85) : Palette.bar)
                    .frame(maxWidth: 6)
                    .frame(height: 6 + CGFloat(l) * 34)
            }
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: recorder.levels)
        .accessibilityHidden(true)
    }

    private var controls: some View {
        HStack(spacing: Space.xl) {
            Button {
                recorder.state == .paused ? recorder.resume() : recorder.pause()
            } label: {
                Image(systemName: recorder.state == .paused ? "play.fill" : "pause.fill")
                    .font(.title3).foregroundStyle(Palette.ink)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
            .mossadGlass(in: Circle(), interactive: true)
            .disabled(recorder.state == .idle)
            .accessibilityLabel(recorder.state == .paused ? "Resume" : "Pause")
            Button {
                // Under a minute the Mac does not keep a meeting, so say so instead of dropping it in silence.
                if recorder.elapsed < ProcessingQueue.minimumCallDuration, PhoneStore.hook("MOSSAD_ROOM") == nil {
                    confirmShortStop = true
                } else {
                    finish(discard: false)
                }
            } label: {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white)
                    .frame(width: 26, height: 26)
                    .frame(width: 78, height: 78)
                    .background(Palette.recording, in: Circle())
                    .padding(5)
                    .background(Palette.recordingTint, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(recorder.state == .idle && PhoneStore.hook("MOSSAD_ROOM") == nil)
            .accessibilityLabel("Stop and send to your Mac")
            .sensoryFeedback(.success, trigger: recorder.state == .idle)
            // Balances pause, so the stop button sits in the middle.
            Color.clear.frame(width: 52, height: 52)
        }
        .confirmationDialog("This recording is under a minute", isPresented: $confirmShortStop, titleVisibility: .visible) {
            Button("Keep recording", role: .cancel) {}
            Button("Discard recording", role: .destructive) { finish(discard: true) }
        } message: {
            Text("Mossad writes notes for meetings of a minute or more. Keep recording, or discard this one.")
        }
    }

    private func finish(discard: Bool) {
        store.stopRecording(discard: discard)
        dismiss()
    }
}
