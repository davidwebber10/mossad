import Foundation
import MossadCore
import SwiftUI

/// Owns detection and exposes app state to the menu.
@MainActor
final class AppController: ObservableObject {
    enum Status: Equatable {
        case idle
        case inCall(Platform, since: Date)
    }

    @Published private(set) var status: Status = .idle

    private let detection = DetectionService(mic: MicUsageProbe(), tabs: BrowserTabProbe(), windows: WindowTitleProbe())

    init() {
        try? Paths.live.ensureDirectories()
        Log.directory = Paths.live.logs
        WindowTitleProbe.requestAccess()
        detection.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        detection.start()
        Log.info("Mossad started")
    }

    private func handle(_ event: DetectorEvent) {
        switch event {
        case .started(let platform, let bundleID, let at):
            Log.info("Call started: \(platform.displayName) (\(bundleID))")
            status = .inCall(platform, since: at)
        case .ended(let at, let trimTo):
            Log.info("Call ended at \(at), trimTo \(String(describing: trimTo))")
            status = .idle
        }
    }
}
