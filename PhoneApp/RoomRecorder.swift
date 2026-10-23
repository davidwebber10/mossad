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

/// The full-screen recorder: a big timer, a live level meter, pause, and stop.
struct RecordingView: View {
    @EnvironmentObject var store: PhoneStore
    @StateObject private var recorder = RoomRecorder()
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @FocusState private var naming: Bool

    var body: some View {
        VStack(spacing: 28) {
            HStack {
                Button("Cancel") { dismiss() }.opacity(recorder.state == .idle ? 1 : 0).disabled(recorder.state != .idle)
                Spacer()
            }
            Spacer()
            VStack(spacing: 8) {
                Label(recorder.state == .paused ? "Paused" : recorder.state == .recording ? "Recording in the room" : "Ready",
                      systemImage: recorder.state == .recording ? "record.circle" : "mic")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(recorder.state == .recording ? Color.red : Color.secondary)
                    .symbolEffect(.pulse, isActive: recorder.state == .recording)
                Text(coachClock(recorder.elapsed))
                    .font(.system(size: 64, weight: .light, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
            }
            HStack(alignment: .center, spacing: 4) {
                ForEach(Array(recorder.levels.enumerated()), id: \.offset) { _, l in
                    Capsule().fill(recorder.state == .recording ? Color.red.opacity(0.8) : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6 + CGFloat(l) * 70)
                }
            }
            .frame(height: 80)
            .animation(.linear(duration: 0.1), value: recorder.levels)
            TextField("What is this meeting? (optional)", text: $title)
                .multilineTextAlignment(.center).font(.title3).focused($naming)
                .padding(.horizontal, 24)
            if let error = recorder.error { Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
            Spacer()
            controls
            Text("Keep the phone on the table, near the people talking. Mossad on your Mac writes the notes.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
        }
        .padding()
        .interactiveDismissDisabled(recorder.state != .idle)
        .task { if recorder.state == .idle { await recorder.start(into: store.recordingsFolder) } }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 40) {
            Button {
                recorder.state == .paused ? recorder.resume() : recorder.pause()
            } label: {
                Image(systemName: recorder.state == .paused ? "play.fill" : "pause.fill").font(.title2).frame(width: 64, height: 64)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .disabled(recorder.state == .idle)
            .accessibilityLabel(recorder.state == .paused ? "Resume" : "Pause")
            Button {
                if let (rec, url) = recorder.stop(title: title) { store.send(rec, audio: url) }
                dismiss()
            } label: {
                Image(systemName: "stop.fill").font(.title).frame(width: 84, height: 84)
            }
            .buttonStyle(.glassProminent).buttonBorderShape(.circle).tint(.red)
            .disabled(recorder.state == .idle)
            .accessibilityLabel("Stop and send to your Mac")
            .sensoryFeedback(.success, trigger: recorder.state == .idle)
        }
    }
}
