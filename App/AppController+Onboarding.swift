import AppKit
import MossadCore
import SwiftUI

/// The setup window: its own window, so it can open before the main one and come back from Settings.
@MainActor
final class OnboardingWindow {
    static let shared = OnboardingWindow()
    private var window: NSWindow?
    private var trafficLights: TrafficLights?
    private(set) var model: OnboardingModel?

    var isOpen: Bool { window?.isVisible == true }

    func show(controller: AppController) {
        let preview = CommandLine.arguments.contains("--ui-preview")
        if window == nil {
            let model = OnboardingModel(preview: preview)
            self.model = model
            let size = Self.size(preview: preview)
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = Rehearsal.isOn ? "Mossad Rehearsal Setup" : "Set Up Mossad"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            let root = OnboardingView(model: model, close: { [weak self] in self?.close() })
                .environmentObject(controller)
                .environmentObject(controller.permissions)
            let host = NSHostingController(rootView: root)
            host.sizingOptions = []
            w.contentViewController = host
            w.setContentSize(size)
            w.contentMinSize = NSSize(width: 860, height: 600)
            w.center()
            if !preview { w.setFrameAutosaveName("MossadOnboarding") }
            window = w
            trafficLights = TrafficLights(window: w) { _ in }
        }
        // A preview for screenshots stays behind the owner's windows and never takes focus.
        if preview {
            window?.orderBack(nil)
            return
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        model?.stopMic()
        window?.close()
        window = nil
        trafficLights = nil
        model = nil
    }

    /// 1000 x 700 by default; `MOSSAD_WINDOW_WIDTH` and `MOSSAD_WINDOW_HEIGHT` size a preview for screenshots.
    private static func size(preview: Bool) -> NSSize {
        let env = preview ? ProcessInfo.processInfo.environment : [:]
        return NSSize(width: env["MOSSAD_WINDOW_WIDTH"].flatMap(Double.init) ?? 1000,
                      height: env["MOSSAD_WINDOW_HEIGHT"].flatMap(Double.init) ?? 700)
    }
}

extension AppController {
    /// Whether setup is finished: the old welcome's flag counts too.
    var onboardingFinished: Bool {
        UserDefaults.standard.bool(forKey: "welcomeDone")
            || OnboardingProgress.resume(from: UserDefaults.standard.data(forKey: "onboardingProgress")).completed
    }

    func openOnboarding() {
        OnboardingWindow.shared.show(controller: self)
    }

    /// "Run setup again" in Settings: from the first step, with everything already set kept.
    func runSetupAgain() {
        OnboardingWindow.shared.close()
        UserDefaults.standard.removeObject(forKey: "onboardingProgress")
        openOnboarding()
    }

    /// The end of setup: the main window opens on Meetings.
    func finishOnboarding() {
        OnboardingWindow.shared.close()
        rebuildPipeline()
        refreshUpcoming()
        open(.meetings)
    }
}
