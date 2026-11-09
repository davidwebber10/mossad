import AppKit
import MossadCore

/// A copy that started while another copy held the data folder. It only shows the meetings. It tries the lock
/// again every 30 s, and starts again as the working copy when the other copy is gone.
extension AppController {
    func waitForInstanceLock() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                // Only a look: the lock is free again at once, and the new copy takes it itself.
                guard case .held = InstanceLock.acquire(root: paths.root) else { continue }
                if await restartAsWorkingCopy() { return }
            }
        }
    }

    /// A fresh start runs the whole launch path (recovery, detection, timers) once, in its normal order.
    private func restartAsWorkingCopy() async -> Bool {
        Log.info("The other copy of Mossad is gone; starting again as the working copy")
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        // With no window open, the restart stays in the menu bar.
        config.arguments = windowVisible ? [] : ["--background"]
        do {
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
            NSApp.terminate(nil)
            return true
        } catch {
            Log.error("Could not start again as the working copy: \(error)")
            return false
        }
    }
}
