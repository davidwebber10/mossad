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
    /// Runs right before Sparkle installs and relaunches: the workers of the other profiles stop first.
    private let beforeInstall: () -> Void
    /// Runs when the install did not end the app after `beforeInstall`: the workers come back.
    private let afterNoInstall: () -> Void
    /// `beforeInstall` ran, and Sparkle has not yet relaunched or given up.
    private var stoppedForInstall = false
    @Published private(set) var canCheck = false
    @Published private(set) var waitingForCall = false
    /// The newer version Sparkle found, for the sidebar's card. Cleared when the owner skips it.
    @Published private(set) var available: AvailableUpdate?
    /// "Update now" from click to the end of Sparkle's session.
    @Published private(set) var progress = UpdateProgress()
    /// Why the last check or download did not finish, for Settings. "No update" is not a problem.
    @Published private(set) var problem: FriendlyError?
    private var observation: AnyCancellable?

    init(start: Bool, isRecording: @escaping () -> Bool, beforeInstall: @escaping () -> Void, afterNoInstall: @escaping () -> Void) {
        self.isRecording = isRecording
        self.beforeInstall = beforeInstall
        self.afterNoInstall = afterNoInstall
        super.init()
        // Sparkle's hosts keep the standard defaults they find when made: in a profile, the Mac's own domain.
        var macOwn = false
        controller = MacDefaults.handOver {
            macOwn = UserDefaults.standard === MacDefaults.store
            assert(macOwn, "Sparkle must be made with the Mac's own settings")
            return SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: self, userDriverDelegate: nil)
        }
        Log.info("Updates: Sparkle uses the Mac's own settings: \(macOwn)")
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

    func checkForUpdates() {
        // A preview never asks the update server.
        guard !AppIdentity.current.isPreview else { return }
        problem = nil
        controller.checkForUpdates(nil)
    }

    nonisolated private static func problem(_ error: Error) -> FriendlyError? {
        let ns = error as NSError
        if ns.domain == SUSparkleErrorDomain, ns.code == Int(SUError.noUpdateError.rawValue) { return nil }
        let friendly = FriendlyError(error, context: .checkingUpdates, service: "the update server")
        return friendly.shouldShow(failures: 1) ? friendly : nil
    }

    /// Development hook, in a preview only: `MOSSAD_UPDATE_PREVIEW=1` shows a found update in the sidebar, and
    /// `MOSSAD_UPDATE_PREVIEW=waiting` shows it accepted and waiting for the call to end.
    func applyPreview(_ value: String) {
        available = AvailableUpdate(version: "1.9.0", notes: ReleaseNotes(lines: [
            "Pages match the new design, with more room", "Update card in the sidebar", "Faster People search",
            "Log keeps errors in view", "Fixes for sync"]))
        waitingForCall = value == "waiting"
        if value == "error" { problem = FriendlyError(URLError(.cannotFindHost), context: .checkingUpdates, service: "the update server") }
    }

    /// "Update now": Sparkle's own install, which shows its progress and waits for a call to end.
    /// A VoiceOver press on a card that shows "Installs after this call" or "Installing…" does nothing.
    func installAvailable() {
        guard canCheck, progress.canStart, !waitingForCall, !AppIdentity.current.isPreview else { return }
        progress.clicked()
        controller.checkForUpdates(nil)
    }

    /// Called by the app when a call ends: an update that waited for it installs now.
    func callEnded() {
        guard let install = pendingInstall else { return }
        pendingInstall = nil
        waitingForCall = false
        stopForInstall()
        install()
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let found = AvailableUpdate(version: item.displayVersionString, notes: ReleaseNotes(html: item.itemDescription))
        MainActor.assumeIsolated { available = found; problem = nil; progress.found() }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { available = nil; problem = nil; progress.notFound() }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Log.error("Update check stopped: \(error)")
        let problem = Self.problem(error)
        MainActor.assumeIsolated { self.problem = problem; progress.aborted(); after(.aborted) }
    }

    /// Sparkle relaunches the app now: the workers stay stopped, and the quit ends them.
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { after(.willRelaunch) }
    }

    private func stopForInstall() {
        stoppedForInstall = true
        beforeInstall()
    }

    /// An install that stopped the workers and then did not end the app (an error, a cancelled authorization, no
    /// relaunch) brings them back.
    private func after(_ event: WorkerLaunch.UpdateEvent) {
        let resumes = WorkerLaunch.resumesAfter(event, stoppedForInstall: stoppedForInstall)
        if event == .willRelaunch || resumes { stoppedForInstall = false }
        if resumes {
            Log.info("Updates: the install did not go on; the background work starts again")
            afterNoInstall()
        }
    }

    nonisolated func userDidCancelDownload(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { progress.downloadEnded() }
    }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        Log.error("Update download failed: \(error)")
        let problem = Self.problem(error)
        MainActor.assumeIsolated { self.problem = problem; progress.downloadEnded() }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        MainActor.assumeIsolated { progress.cycleFinished(); after(.cycleEnded) }
    }

    nonisolated func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
                             state: SPUUserUpdateState) {
        MainActor.assumeIsolated {
            if choice == .skip { available = nil }
            progress.chose(install: choice == .install)
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // Sparkle calls this on the main thread; the box carries its handler into main-actor state.
        let handler = InstallHandler(run: installHandler)
        return MainActor.assumeIsolated {
            guard isRecording() else {
                stopForInstall()
                return false
            }
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
