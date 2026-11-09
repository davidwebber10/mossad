import AppKit
import MossadCore

/// A copy that started while another copy held the data folder. It only shows the meetings. It looks at the lock
/// every 30 s, so the menu can say when the other copy is gone. It never takes over by itself: a quit of the other
/// copy can be the middle of an update, so the owner decides with "Restart Mossad".
extension AppController {
    func waitForInstanceLock() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                // Only a look: the lock is free again at once.
                var free = false
                if case .held = InstanceLock.acquire(root: paths.root) { free = true }
                if free != otherCopyQuit { otherCopyQuit = free }
            }
        }
    }

    /// Starts this copy again with the same arguments and environment (so a `MOSSAD_ROOT` copy stays in its
    /// folder), then quits. The new copy takes the lock in its normal launch.
    func restartAsWorkingCopy() {
        guard isSecondCopy else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = Array(CommandLine.arguments.dropFirst())
        config.environment = ProcessInfo.processInfo.environment
        Log.info("Restarting as the working copy")
        Task {
            do {
                _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
                NSApp.terminate(nil)
            } catch {
                Log.error("Could not restart as the working copy: \(error)")
            }
        }
    }
}
