import AppKit
import MossadCore

/// A moment of the call that records, to show in its live transcript in the main window.
struct LiveJumpRequest: Equatable {
    let callID: String
    let at: TimeInterval
    let id = UUID()
}

/// The quick panel: its shortcut, its chat when no call records, and the ways from it to the main window.
extension AppController {
    static let askShortcutKey = "askShortcut"
    private static let quickChatKey = "quickChatID"

    /// The owner's shortcut for the quick panel: Option-Command-M until they change it; nil once they clear it.
    var askShortcut: HotKeyShortcut? {
        guard let saved = UserDefaults.standard.string(forKey: Self.askShortcutKey) else { return .askDefault }
        return HotKeyShortcut(saved: saved)
    }

    /// Registered all the time, as the owner chose, so it opens the quick chat with no call too.
    func registerAskShortcut() {
        guard let shortcut = askShortcut else {
            askShortcutFailed = false
            return hotKeys.unregister(.ask)
        }
        askShortcutFailed = !hotKeys.register(.ask, shortcut) { [weak self] in self?.toggleAskPanel() }
    }

    /// The shortcut that works now, for the menu and the panel's keys; nil when cleared or not registered.
    var activeAskShortcut: HotKeyShortcut? { askShortcutFailed ? nil : askShortcut }

    /// Sets the quick panel's shortcut, or clears it with nil. Gives the problem when it cannot be set; the shortcut
    /// before stays then.
    func setAskShortcut(_ shortcut: HotKeyShortcut?) -> HotKeyShortcut.Problem? {
        if let problem = shortcut?.problem { return problem }
        if let shortcut, !isInert {
            guard hotKeys.register(.ask, shortcut, action: { [weak self] in self?.toggleAskPanel() }) else {
                registerAskShortcut()
                return .taken
            }
        }
        // A preview shares the app's settings: it changes nothing there.
        if !isInert { UserDefaults.standard.set(shortcut?.saved ?? "", forKey: Self.askShortcutKey) }
        if shortcut == nil { hotKeys.unregister(.ask) }
        askShortcutFailed = false
        objectWillChange.send()
        return nil
    }

    /// While Settings records a new shortcut, the old one must not open the panel.
    func pauseAskShortcut(_ paused: Bool) {
        guard !isInert else { return }
        if paused { hotKeys.unregister(.ask) } else { registerAskShortcut() }
    }

    /// Whether this call is the one that records now.
    func isRecording(callID: String) -> Bool {
        guard case .recording(_, let since) = status else { return false }
        return CallRecorder.callID(for: since) == callID
    }

    // MARK: The panel

    var askPanelController: AskPanelController {
        if let askPanel { return askPanel }
        let panel = AskPanelController(controller: self)
        askPanel = panel
        return panel
    }

    /// The shortcut: shows the panel, or hides it when it shows.
    func toggleAskPanel() {
        askPanelController.toggle()
    }

    /// The menu's "Ask about this call…".
    func showAskPanel() {
        askPanelController.show()
    }

    // MARK: The quick chat

    func quickChatSession() -> ChatSession {
        if let quickChat { return quickChat }
        let session = ChatSession(callID: nil)
        quickChat = session
        return session
    }

    /// On each open with no call: the quick chat goes on unless the owner started a new one or a call started
    /// since. Read off the main thread.
    func refreshQuickChat() {
        let session = quickChatSession()
        guard !session.running else { return }
        let id = UserDefaults.standard.string(forKey: Self.quickChatKey).flatMap(UUID.init(uuidString:))
        let lastCall = meetings.filter { !$0.isNotesOnly }.map(\.start).max()
        let store = chats
        Task {
            let found = await Task.detached(priority: .userInitiated) { id.flatMap { try? store.load($0) } }.value
            session.adopt(QuickChatRule.continues(found, lastCallStart: lastCall) ? found : nil)
        }
    }

    /// The session that writes this chat, when one does: the quick panel's chat, or the chat of the call that
    /// records. The Chat page asks through it, so one writer saves the file. `create` makes the quick session.
    func session(answering chat: Chat, create: Bool) -> ChatSession? {
        if let callID = chat.callID {
            guard isRecording(callID: callID), let session = liveChatSessions[callID], session.chat?.id == chat.id else { return nil }
            return session
        }
        let remembered = UserDefaults.standard.string(forKey: Self.quickChatKey).flatMap(UUID.init(uuidString:))
        guard quickChat?.chat?.id == chat.id || remembered == chat.id else { return nil }
        return create ? quickChatSession() : quickChat
    }

    /// The quick chat the panel continues next time.
    func rememberQuickChat(_ id: UUID?) {
        guard !isInert else { return }
        UserDefaults.standard.set(id?.uuidString, forKey: Self.quickChatKey)
    }

    // MARK: To the main window

    /// Command-Return and the panel's arrows: the same chat in the main window.
    func openAskInWindow(_ mode: AskPanelMode) {
        askPanel?.hide()
        switch mode {
        case .call(let id), .noTranscript(let id, _):
            liveChatFocus = id
            openMeeting(id)
        case .ended(let id):
            UserDefaults.standard.set(MeetingDetailView.Tab.chat.rawValue, forKey: "detailTab")
            openMeeting(id)
        case .quick:
            if let id = quickChat?.chat?.id {
                chatToOpen = id
                open(.chat)
            } else {
                startChat()
            }
        }
    }

    /// Command-click on a time in the panel: the live transcript at that line, as the Chat tab shows it.
    func showLiveMoment(callID: String, at: TimeInterval) {
        askPanel?.hide()
        liveJumpRequest = LiveJumpRequest(callID: callID, at: at)
        openMeeting(callID)
    }

    /// "Turn on…": the Settings page that turns the live transcript on.
    func openSettings(for fix: LiveOffFix) {
        askPanel?.hide()
        let page: SettingsPage = switch fix {
        case .recordingSettings: .recording
        case .aiSettings: .ai
        }
        UserDefaults.standard.set(page.rawValue, forKey: "settingsPage")
        open(.settings)
    }
}
