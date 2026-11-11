import AppKit
import MossadCore
import SwiftUI

/// Setup's state on the Mac: where the owner is (saved after each step), the key checks, and the audio check.
/// The steps' settings are the real ones, the same that Settings shows.
@MainActor
final class OnboardingModel: ObservableObject {
    enum ToneState: Equatable {
        case idle, playing, heard, silent
        case failed(String)
    }

    @Published private(set) var progress: OnboardingProgress
    @Published private(set) var micHeard: Bool?
    @Published private(set) var tone: ToneState = .idle
    @Published private(set) var micRunning = false
    @Published private(set) var micProblem: String?
    /// Moves the content back to the top when the step changes.
    @Published private(set) var stepToken = 0

    let micCheck = MicLevelCheck()
    /// The AI step's key checks, the same ones Settings › AI runs.
    let keys = KeyChecker()
    private let saves: Bool
    private static let progressKey = "onboardingProgress"
    private static let micKey = "onboardingMicHeard"
    private static let toneKey = "onboardingToneHeard"

    /// A UI preview never saves: it shares the real app's settings and only looks.
    init(preview: Bool) {
        saves = !preview
        let defaults = UserDefaults.standard
        progress = OnboardingProgress.resume(from: preview ? nil : defaults.data(forKey: Self.progressKey))
        if !preview {
            micHeard = defaults.object(forKey: Self.micKey) as? Bool
            if defaults.bool(forKey: Self.toneKey) { tone = .heard }
        }
        if preview { applyPreviewHooks() }
    }

    var step: OnboardingStep { progress.current }

    // MARK: Moving

    func advance() { change { $0.advance() } }
    func skip() { change { $0.skip() } }
    func back() { change { $0.back() } }
    func jump(to step: OnboardingStep) { change { $0.jump(to: step) } }

    func finish() {
        change { $0.finish() }
        if saves { UserDefaults.standard.set(true, forKey: "welcomeDone") }
    }

    /// Back to the first step; the settings already made stay.
    func restart() {
        stopMic()
        keys.reset()
        micHeard = nil
        tone = .idle
        if saves {
            UserDefaults.standard.removeObject(forKey: Self.micKey)
            UserDefaults.standard.removeObject(forKey: Self.toneKey)
            UserDefaults.standard.removeObject(forKey: "welcomeDone")
        }
        change { $0.restart() }
    }

    private func change(_ edit: (inout OnboardingProgress) -> Void) {
        let before = progress.current
        withAnimation(.smooth(duration: 0.25)) { edit(&progress) }
        if progress.current != before {
            stepToken += 1
            if before == .check { stopMic() }
        }
        save()
    }

    private func save() {
        guard saves, let data = progress.encoded() else { return }
        UserDefaults.standard.set(data, forKey: Self.progressKey)
    }

    // MARK: Facts

    func facts(controller: AppController, permissions: PermissionsMonitor) -> OnboardingFacts {
        OnboardingFacts(ownerName: controller.ownerName,
                        granted: Set(permissions.items.filter { $0.state.isGood }.map(\.kind)),
                        transcriptionKeySet: controller.transcriptionProvider.key.map(controller.hasKey),
                        aiKeySet: controller.aiProvider.key.map(controller.hasKey) ?? false || !controller.aiProvider.requiresKey,
                        chosenCalendars: controller.chosenCalendars.count,
                        micHeard: micHeard,
                        systemAudioHeard: tone == .heard ? true : tone == .silent ? false : nil,
                        googleConnected: controller.googleConnected)
    }

    // MARK: The audio check

    func startMic() {
        guard !micRunning else { return }
        micRunning = true
        micProblem = nil
        let check = micCheck
        CaptureQueue.queue.async {
            do {
                try check.start()
            } catch {
                Log.error("The setup mic check could not start: \(error)")
                Task { @MainActor in
                    self.micRunning = false
                    self.micProblem = FriendlyError(error, context: .recording).title
                }
            }
        }
    }

    func stopMic() {
        guard micRunning else { return }
        micRunning = false
        let check = micCheck
        CaptureQueue.queue.async { check.stop() }
    }

    /// Called as the meter redraws: the first level loud enough counts as heard.
    func noteMicLevels(_ levels: [Float]) {
        guard micHeard != true, AudioCheck.heardVoice(levels) else { return }
        micHeard = true
        if saves { UserDefaults.standard.set(true, forKey: Self.micKey) }
    }

    func playTone() {
        guard tone != .playing else { return }
        tone = .playing
        Task.detached(priority: .userInitiated) {
            let result = await AudioCheck.runToneCheck()
            await MainActor.run {
                switch result {
                case .heard: self.tone = .heard
                case .silent: self.tone = .silent
                case .failed(let reason):
                    Log.error("The setup tone check failed: \(reason)")
                    self.tone = .failed(reason)
                }
                if self.saves { UserDefaults.standard.set(self.tone == .heard, forKey: Self.toneKey) }
            }
        }
    }

    // MARK: Preview

    /// Development hooks for screenshots: `MOSSAD_ONBOARDING_STEP=1...8` opens that step, and
    /// `MOSSAD_ONBOARDING_CHECK=pass|fail` shows the audio check's results without listening.
    private func applyPreviewHooks() {
        let env = ProcessInfo.processInfo.environment
        if let n = env["MOSSAD_ONBOARDING_STEP"].flatMap(Int.init), OnboardingStep.allCases.indices.contains(n - 1) {
            let target = OnboardingStep.allCases[n - 1]
            // The steps before it count as seen, as they would on the way there.
            while progress.current != target { progress.advance() }
        }
        switch env["MOSSAD_ONBOARDING_CHECK"] {
        case "pass":
            micHeard = true
            tone = .heard
            [0.004, 0.02, 0.05, 0.08, 0.03, 0.06, 0.1, 0.04, 0.02, 0.07, 0.05, 0.03].forEach(micCheck.meter.record)
        case "fail":
            micHeard = false
            tone = .silent
        default: break
        }
    }
}
