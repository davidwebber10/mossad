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
    /// The content's height as the view last reported it, also while hidden: an open with the same content gets no
    /// new report, so it must not depend on one.
    private var contentHeight: CGFloat?
    /// Set while Mossad moves the panel itself, so only the owner's drag is remembered.
    private var adjusting = false
    private static let originKey = "askPanelOrigin"

    init(controller: AppController) {
        self.controller = controller
    }

    var isVisible: Bool { panel?.isVisible == true }
    /// The panel's window number, for a preview's capture.
    var windowNumber: Int? { panel?.windowNumber }
    /// Whether it has the keyboard, for a preview's check.
    var isKey: Bool { panel?.isKeyWindow == true }

    func toggle() {
        if isVisible { hide() } else { show(.shortcut) }
    }

    /// Only on the owner's action: the shortcut or the menu. A preview shows it without the keyboard, and then it
    /// can never become key (`AskPanelKeys`).
    func show(_ action: AskPanelKeys.Show) {
        let panel = panel ?? makePanel()
        let opened = AskPanelKeys.opened(by: action)
        panel.opened = opened
        model.keyboard = opened
        let takeKeyboard = AskPanelKeys.canBecomeKey(opened)
        if !controller.isRecording { controller.refreshQuickChat() }
        // Before the first draw: an old share value never shows the chat (`AskPanelCover`).
        if !panel.isVisible { controller.shareCheckForPanel() }
        model.opened()
        model.track(controller)
        if !panel.isVisible {
            hosting?.layoutSubtreeIfNeeded()
            let measured = hosting.map { $0.intrinsicContentSize.height }.flatMap { $0 > 0 ? $0 : nil }
            let height = contentHeight ?? measured
            place(content: height, bottomLeft: startOrigin(height: height ?? minimum), on: panel)
        }
        if takeKeyboard {
            panel.makeKeyAndOrderFront(nil)
            startKeys()
        } else {
            panel.orderFrontRegardless()
        }
        // Once more after the first layout of this open, from the size the content has now.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            self.hosting?.layoutSubtreeIfNeeded()
            let measured = self.hosting.map { $0.intrinsicContentSize.height }.flatMap { $0 > 0 ? $0 : nil }
            self.place(content: self.contentHeight ?? measured, bottomLeft: panel.frame.origin, on: panel)
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        stopKeys()
        panel.orderOut(nil)
        panel.opened = nil
        model.keyboard = nil
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
        // Asks the system to keep it out of screen captures. Since macOS 15, ScreenCaptureKit (which the call apps
        // use to share) may still capture it, so this is no promise; the panel covers its chat itself while it
        // sees a share (`ownerSharing`). Mossad's own frames never see it: they capture the call app's window alone.
        // A preview's panel can be captured, to check it.
        panel.sharingType = DevHooks.preview ? .readOnly : .none
        panel.title = "Ask Mossad"
        let view = AskPanelView(model: model, actions: actions)
            .environmentObject(controller)
        let hosting = NSHostingView(rootView: AnyView(view))
        // Its own height only, to read; never the window's least or largest size.
        hosting.sizingOptions = [.intrinsicContentSize]
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

    /// The header, the field, and the keys; a notice in place of the chat needs less.
    private var minimum: CGFloat {
        switch model.mode(controller) {
        case .call, .quick: AskPanelSizing.minimum(chips: false)
        case .noTranscript, .ended: 100
        }
    }

    /// Each change of the content: the bottom edge, where the field is, stays put; the panel grows up, and moves
    /// down only to stay on screen.
    private func fit(height: CGFloat) {
        guard height > 0 else { return }
        contentHeight = height
        guard let panel, panel.isVisible else { return }
        place(content: height, bottomLeft: panel.frame.origin, on: panel)
    }

    private func place(content: CGFloat?, bottomLeft: NSPoint, on panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(bottomLeft) } ?? panel.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let frame = AskPanelSizing.frame(content: content, minimum: minimum, bottomLeft: bottomLeft, visible: visible)
        guard frame != panel.frame else { return }
        adjusting = true
        panel.setFrame(frame, display: panel.isVisible)
        adjusting = false
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
        guard !adjusting, !controller.isInert, let panel, panel.isVisible else { return }
        UserDefaults.standard.set("\(panel.frame.minX),\(panel.frame.minY)", forKey: Self.originKey)
    }

    // MARK: Keys

    /// Escape hides, Command-Return opens the chat in the window. A local monitor sees them before the text field.
    private func startKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // By key code and the four modifiers only, so Caps Lock and the function key change nothing.
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let code = event.keyCode
            let number = event.window?.windowNumber
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel, number == panel.windowNumber else { return false }
                return self.handleKey(code, mods, in: panel)
            }
            return handled ? nil : event
        }
    }

    /// Escape hides (not while an input method composes), Command-Return opens the window, Command-W hides, and
    /// Command-N starts a new quick chat. Mossad's other menu keys would bring the main window forward and take
    /// the call app out of full screen, so the panel takes them and does nothing; the text keys still work.
    private func handleKey(_ code: UInt16, _ mods: NSEvent.ModifierFlags, in panel: NSPanel) -> Bool {
        let composing = (panel.firstResponder as? NSTextView)?.hasMarkedText() == true
        if code == 53, mods.isEmpty { if composing { return false }; hide(); return true }
        guard mods.contains(.command) else { return false }
        let plain = mods == .command
        if plain, code == 36 || code == 76 {
            controller.openAskInWindow(model.mode(controller))
        } else if plain, code == 13 {
            hide()
        } else if plain, code == 45 {
            if model.mode(controller) == .quick, controller.quickChat?.running != true {
                controller.quickChat?.newChat()
                controller.rememberQuickChat(nil)
                model.focusRequest += 1
            }
        } else if [0, 6, 7, 8, 9, 0x33, 0x7B, 0x7C, 0x7D, 0x7E].contains(code) {
            // Select all, undo and redo, cut, copy, paste, and the text moves.
            return false
        }
        return true
    }

    private func stopKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// A borderless panel that takes the keyboard while the app it belongs to stays in the background.
final class AskPanelWindow: NSPanel {
    /// How the panel was opened this time; nil while hidden.
    var opened: AskPanelKeys.Opened?
    override var canBecomeKey: Bool { AskPanelKeys.canBecomeKey(opened) }
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
    /// Published, so the hidden panel's quick questions stop reading the transcript each second.
    @Published private(set) var isOpen = false
    /// The text typed in the field, for the call and for the quick chat apart, so a change of state keeps it.
    @Published var drafts: [String: String] = [:]
    /// The owner chose to see the chat during this share; until the panel hides.
    @Published var showDuringShare = false
    @Published var shownCall: String?
    /// The call's start, and when it ended while the panel showed it, for "Ended, 47 min".
    @Published var since: Date?
    @Published var endedAt: Date?
    /// The moment shown inline: the message whose chip was clicked and its seconds.
    @Published var peek: (message: UUID, seconds: Int)?
    @Published var focusRequest = 0
    /// How the panel was opened: only an open by the owner focuses the field.
    @Published var keyboard: AskPanelKeys.Opened?
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
        showDuringShare = false
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
