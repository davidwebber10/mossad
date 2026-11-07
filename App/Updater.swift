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
    /// The newer version Sparkle found, for the sidebar's card. Cleared when the owner skips it.
    @Published private(set) var available: AvailableUpdate?
    /// The owner chose to install the found update; Sparkle is downloading or installing it.
    @Published private(set) var installing = false
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

    /// Development hook, in a preview only: `MOSSAD_UPDATE_PREVIEW=1` shows a found update in the sidebar, and
    /// `MOSSAD_UPDATE_PREVIEW=waiting` shows it accepted and waiting for the call to end.
    func applyPreview(_ value: String) {
        available = AvailableUpdate(version: "1.9.0", notes: ReleaseNotes(lines: [
            "Pages match the new design, with more room", "Update card in the sidebar", "Faster People search",
            "Log keeps errors in view", "Fixes for sync"]))
        waitingForCall = value == "waiting"
    }

    /// "Update now": Sparkle's own install, which shows its progress and waits for a call to end.
    func installAvailable() {
        installing = true
        controller.checkForUpdates(nil)
    }

    /// Called by the app when a call ends: an update that waited for it installs now.
    func callEnded() {
        guard let install = pendingInstall else { return }
        pendingInstall = nil
        waitingForCall = false
        install()
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let found = AvailableUpdate(version: item.displayVersionString, notes: ReleaseNotes(html: item.itemDescription))
        MainActor.assumeIsolated { available = found }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { available = nil; installing = false }
    }

    nonisolated func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
                             state: SPUUserUpdateState) {
        MainActor.assumeIsolated {
            switch choice {
            case .skip: available = nil; installing = false
            case .install: installing = true
            default: installing = false
            }
        }
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

struct AvailableUpdate: Equatable {
    let version: String
    let notes: ReleaseNotes
}

private struct InstallHandler: @unchecked Sendable {
    let run: () -> Void
}
