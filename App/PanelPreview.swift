import AppKit
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
