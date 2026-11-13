import AppKit
import MossadCore
import SwiftUI

/// The quick panel's window: Spotlight style, over every app and full-screen space. It takes the keyboard without
/// making Mossad the active app, so the call app stays in front and in full screen. Its field stays where it is on
/// the screen and the panel grows upward as the chat appears. Escape, the shortcut, the close button, or a click
/// outside hides it; the chat stays.
@MainActor
final class AskPanelController {
    private unowned let controller: AppController
    let model = AskPanelModel()
    private var panel: AskPanelWindow?
    private var hosting: NSHostingView<AnyView>?
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private static let originKey = "askPanelOrigin"

    init(controller: AppController) {
        self.controller = controller
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    /// Only on the owner's action: the shortcut or the menu.
    func show() {
        let panel = panel ?? makePanel()
        if !controller.isRecording { controller.refreshQuickChat() }
        model.opened()
        model.track(controller)
        if !panel.isVisible {
            hosting?.layoutSubtreeIfNeeded()
            let height = max(hosting?.fittingSize.height ?? 160, 100)
            panel.setFrame(NSRect(origin: startOrigin(height: height), size: NSSize(width: AskPanelView.width, height: height)), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        startKeys()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        stopKeys()
        panel.orderOut(nil)
        model.closed()
    }

    // MARK: Window

    private func makePanel() -> AskPanelWindow {
        let panel = AskPanelWindow(contentRect: NSRect(x: 0, y: 0, width: AskPanelView.width, height: 160),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        // Kept out of screen sharing and screenshots: the owner's questions stay the owner's. Mossad's own frames
        // never see it anyway, as they capture the call app's window alone.
        panel.sharingType = .none
        panel.title = "Ask Mossad"
        let view = AskPanelView(model: model, actions: actions)
            .environmentObject(controller)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            // A click outside: in another app, on the desktop, or in Mossad's own window.
            MainActor.assumeIsolated { self?.hide() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveOrigin() }
        })
        return panel
    }

    private var actions: AskPanelActions {
        AskPanelActions(
            hide: { [weak self] in self?.hide() },
            height: { [weak self] h in self?.fit(height: h) })
    }

    /// The bottom edge, where the field is, stays put; the panel grows up, and moves down only to stay on screen.
    private func fit(height: CGFloat) {
        guard let panel, height > 0, abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.size.height = height
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame, frame.maxY > visible.maxY {
            frame.origin.y = max(visible.minY, visible.maxY - height)
        }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    /// Where the owner left it, while that is on a screen; else low in the middle of the screen with the pointer.
    private func startOrigin(height: CGFloat) -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: Self.originKey)?.split(separator: ","), saved.count == 2,
           let x = Double(saved[0]), let y = Double(saved[1]) {
            let point = NSPoint(x: x, y: y)
            let field = NSRect(x: x, y: y, width: AskPanelView.width, height: 60)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(field) }) {
                return clamped(point, height: height)
            }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return .zero }
        return clamped(NSPoint(x: visible.midX - AskPanelView.width / 2, y: visible.minY + visible.height * 0.16), height: height)
    }

    private func clamped(_ p: NSPoint, height: CGFloat) -> NSPoint {
        guard let visible = (NSScreen.screens.first { $0.visibleFrame.contains(p) } ?? NSScreen.main)?.visibleFrame else { return p }
        return NSPoint(x: p.x, y: min(p.y, max(visible.minY, visible.maxY - height)))
    }

    private func saveOrigin() {
        guard let panel, panel.isVisible else { return }
        UserDefaults.standard.set("\(panel.frame.minX),\(panel.frame.minY)", forKey: Self.originKey)
    }

    // MARK: Keys

    /// Escape hides, Command-Return opens the chat in the window. A local monitor sees them before the text field.
    private func startKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let code = event.keyCode
            let number = event.window?.windowNumber
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel, number == panel.windowNumber else { return false }
                if code == 53, mods.isEmpty {
                    self.hide()
                    return true
                }
                if [36, 76].contains(code), mods == .command {
                    self.controller.openAskInWindow(self.model.mode(self.controller))
                    return true
                }
                return false
            }
            return handled ? nil : event
        }
    }

    private func stopKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// A borderless panel that takes the keyboard while the app it belongs to stays in the background.
final class AskPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// What the panel's view asks of its window.
struct AskPanelActions {
    let hide: () -> Void
    let height: (CGFloat) -> Void
}

/// The panel's state over its opens: the call it showed (to say when that call ends), the moment open in the
/// peek, and the requests to focus the field and scroll to the newest message.
@MainActor
final class AskPanelModel: ObservableObject {
    private(set) var isOpen = false
    @Published var shownCall: String?
    /// The call's start, and when it ended while the panel showed it, for "Ended, 47 min".
    @Published var since: Date?
    @Published var endedAt: Date?
    /// The moment shown inline: the message whose chip was clicked and its seconds.
    @Published var peek: (message: UUID, seconds: Int)?
    @Published var focusRequest = 0
    @Published var scrollRequest = 0
    /// A preview's made-up call that records, so no recording icon joins the owner's menu bar.
    var previewCall: (id: String, since: Date)?
    var previewOff: LiveOffReason?
    var previewEnded = false

    func opened() {
        isOpen = true
        focusRequest += 1
        scrollRequest += 1
    }

    func closed() {
        isOpen = false
        shownCall = nil
        endedAt = nil
        peek = nil
    }

    /// The call that records now, from the controller (or a preview's).
    func recording(_ controller: AppController) -> (id: String, since: Date)? {
        if let previewCall { return previewEnded ? nil : previewCall }
        guard case .recording(_, let since) = controller.status else { return nil }
        return (CallRecorder.callID(for: since), since)
    }

    func mode(_ controller: AppController) -> AskPanelMode {
        AskPanelRules.mode(recording: recording(controller)?.id, liveOff: previewCall != nil ? previewOff : controller.liveOff,
                           shownCall: shownCall)
    }

    /// Keeps the call the panel shows, so its end shows as such while the panel stays open.
    func track(_ controller: AppController) {
        guard isOpen else { return }
        if let call = recording(controller) {
            if shownCall != call.id { shownCall = call.id; since = call.since; endedAt = nil; peek = nil }
        } else if shownCall != nil, endedAt == nil {
            endedAt = Date()
            peek = nil
        }
    }
}
