import AVFoundation
import MossadCore
import SwiftUI

/// Records a meeting in the room through the phone's mic. The file stays on the phone until iCloud has it.
@MainActor
final class RoomRecorder: ObservableObject {
    enum State { case idle, recording, paused }

    @Published private(set) var state = State.idle
    @Published private(set) var elapsed: TimeInterval = 0
    /// The last second of levels, 0 to 1, for the meter.
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 24)
    @Published var error: String?

    private var recorder: AVAudioRecorder?
    private var started = Date()
    private var id = ""
    private var timer: Timer?

    func start(into dir: URL) async {
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Mossad needs the microphone. Turn it on in Settings, Privacy & Security, Microphone."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .spokenAudio, options: [.allowBluetoothHFP])
            try session.setActive(true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            started = Date()
            id = CallID.make(started)
            let r = try AVAudioRecorder(url: dir.appendingPathComponent("\(id).m4a"), settings: PhoneRecording.settings)
            r.isMeteringEnabled = true
            guard r.record() else { throw RecorderError() }
            recorder = r
            state = .recording
            NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        } catch {
            self.error = "Recording could not start: \(error.localizedDescription)"
        }
    }

    struct RecorderError: Error {}

    private func tick() {
        guard let recorder else { return }
        elapsed = recorder.currentTime
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        levels = Array(levels.dropFirst()) + [state == .recording ? max(0, min(1, (db + 50) / 50)) : 0]
    }

    /// A phone call pauses the recording; it does not end it.
    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor in self.pause() }
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        recorder?.record()
        state = .recording
    }

    /// Stops and returns the recording to send, or nil when it was too short to keep.
    func stop(title: String) -> (PhoneRecording, URL)? {
        guard let recorder else { return nil }
        let length = recorder.currentTime, url = recorder.url
        recorder.stop()
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        self.recorder = nil
        state = .idle
        elapsed = 0
        guard length >= ProcessingQueue.minimumCallDuration else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (PhoneRecording(id: id, start: started, end: started.addingTimeInterval(length), title: t.isEmpty ? nil : t), url)
    }
}

/// The full-screen recorder as the canvas draws it: the red status capsule, a large timer, the room's level as
/// bars, and one big stop button between pause and the meeting's name. The Mac transcribes after; the audio
/// stays here until it has it.
struct RecordingView: View {
    @EnvironmentObject var store: PhoneStore
    @StateObject private var recorder = RoomRecorder()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var title = ""
    @FocusState private var naming: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 52

    var body: some View {
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
                        TextField("What is this meeting? (optional)", text: $title)
                            .textRole(.body)
                            .focused($naming)
                            .padding(.horizontal, Space.m).padding(.vertical, 11)
                            .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    }
                    if let error = recorder.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .textRole(.secondary).foregroundStyle(Palette.recording)
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
        .task { if recorder.state == .idle, PhoneStore.hook("MOSSAD_ROOM") == nil { await recorder.start(into: store.recordingsFolder) } }
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
                if let (rec, url) = recorder.stop(title: title) { store.send(rec, audio: url) }
                dismiss()
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
    }
}
