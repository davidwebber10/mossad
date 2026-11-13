import AppKit
import MossadCore
import SwiftUI

extension AppController {
    /// A preview's look at the menu bar panel: its content in a window of its own, on a desktop-like ground, so
    /// it can be captured without opening the menu bar. Never in a normal run.
    func openPanelPreview() {
        let content = PanelPreviewBackdrop {
            MenuContent(controller: self, permissions: permissions)
                .fixedSize(horizontal: false, vertical: true)
                .mossadGlass(cornerRadius: 18)
                .shadow(color: .black.opacity(0.28), radius: 20, y: 16)
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Panel preview"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: content)
        w.center()
        w.orderBack(nil)
        panelPreviewWindow = w
    }
}

private struct PanelPreviewBackdrop<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: scheme == .dark
                           ? [Color(hex: 0x2B3440), Color(hex: 0x141A22), Color(hex: 0x0B0F15)]
                           : [Color(hex: 0xC9D6E3), Color(hex: 0x8FA7BC), Color(hex: 0x5E7A94)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            content.padding(.top, 20).padding(.trailing, 20)
        }
        .frame(width: 640, height: 760)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

extension AppController {
    /// A preview's look at the quick panel: its content in a window of its own over a dark ground, sent behind the
    /// owner's windows, so it can be captured without the floating panel or a recording icon in the menu bar.
    /// `MOSSAD_ASK_CALL=<call id>` is a made-up call that records (`MOSSAD_ASK_MINUTES` ago); `MOSSAD_ASK_STATE` is
    /// `off`, `ended`, or `answering:<question>`; `MOSSAD_ASK_PEEK=<seconds>` opens the live transcript under that
    /// time in the newest answer that has it. Never in a normal run.
    func openAskPanelPreview() {
        let env = ProcessInfo.processInfo.environment
        let panel = askPanelController
        let model = panel.model
        if let id = env["MOSSAD_ASK_CALL"] {
            let minutes = env["MOSSAD_ASK_MINUTES"].flatMap(Double.init) ?? 24
            model.previewCall = (id, Date().addingTimeInterval(-minutes * 60))
        }
        model.opened()
        model.track(self)
        let state = env["MOSSAD_ASK_STATE"] ?? ""
        if state == "off" { model.previewOff = .setting }
        if state == "ended" {
            model.previewEnded = true
            model.track(self)
        }
        let session = model.previewCall.map { liveChatSession($0.id) } ?? quickChatSession()
        if model.previewCall == nil { refreshQuickChat() }
        if state.hasPrefix("answering:") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { session.showAnswering(String(state.dropFirst("answering:".count))) }
        }
        if let seconds = env["MOSSAD_ASK_PEEK"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let answer = session.chat?.messages.last {
                    $0.role == .assistant && ChatBlocks.momentSeconds(in: ChatBlocks.linkTimes($0.text, callID: session.callID)).contains(seconds)
                }
                if let answer { model.peek = (answer.id, seconds) }
            }
        }
        let content = ZStack(alignment: .bottom) {
            Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(red: 0x12 / 255, green: 0x12 / 255, blue: 0x11 / 255, alpha: 1)
                : NSColor(red: 0xD9 / 255, green: 0xD5 / 255, blue: 0xCE / 255, alpha: 1) })
            AskPanelView(model: model, actions: AskPanelActions(hide: {}, height: { _ in }))
                .fixedSize()
                .shadow(color: .black.opacity(0.45), radius: 30, y: 20)
                .padding(.bottom, 96)
        }
        .frame(width: 1200, height: 760)
        .environmentObject(self)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Ask panel preview"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: content)
        w.center()
        w.orderBack(nil)
        panelPreviewWindow = w
    }
}
