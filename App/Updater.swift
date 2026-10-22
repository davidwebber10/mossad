import Combine
import Foundation
import MossadCore
import Sparkle

/// Checks the latest GitHub release for a new version and offers to install it. A release is installed only
/// when its signature matches the public key in Info.plist. An update accepted during a call waits until the
/// call ends, so the recording never splits.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    /// Set when an update is ready while a call records; run once the call ends.
    private var pendingInstall: (() -> Void)?
    private let isRecording: () -> Bool
    @Published private(set) var canCheck = false
    @Published private(set) var waitingForCall = false
    private var observation: AnyCancellable?

    init(start: Bool, isRecording: @escaping () -> Bool) {
        self.isRecording = isRecording
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: self, userDriverDelegate: nil)
        observation = controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).sink { [weak self] in self?.canCheck = $0 }
    }

    var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    var automaticallyInstalls: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    /// Called by the app when a call ends: an update that waited for it installs now.
    func callEnded() {
        guard let install = pendingInstall else { return }
        pendingInstall = nil
        waitingForCall = false
        install()
    }

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // Sparkle calls this on the main thread; the box carries its handler into main-actor state.
        let handler = InstallHandler(run: installHandler)
        return MainActor.assumeIsolated {
            guard isRecording() else { return false }
            pendingInstall = handler.run
            waitingForCall = true
            Log.info("Update \(item.displayVersionString) waits for the call to end")
            return true
        }
    }
}

private struct InstallHandler: @unchecked Sendable {
    let run: () -> Void
}
