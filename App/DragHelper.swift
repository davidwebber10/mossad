import AppKit
import MossadCore
import SwiftUI

/// A small floating panel under the System Settings window. It holds the Mossad icon,
/// which you drag into a privacy list to add Mossad to it.
@MainActor
final class DragHelper {
    private var panel: NSPanel?
    private var follow: Timer?
    private var kind: PermissionKind?
    private var shownAt = Date()
    private let size = CGSize(width: 340, height: 84)

    func show(for kind: PermissionKind, title: String) {
        close()
        self.kind = kind
        shownAt = Date()
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: DragHelperView(title: title) { [weak self] in self?.close() })
        self.panel = panel
        follow = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
        reposition()
    }

    func closeIfGranted(_ states: [PermissionKind: PermissionState]) {
        if let kind, states[kind] == .granted { close() }
    }

    func close() {
        follow?.invalidate()
        follow = nil
        panel?.orderOut(nil)
        panel = nil
        kind = nil
    }

    private func reposition() {
        guard let panel else { return }
        let settings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first
        guard let settings else {
            // Give System Settings time to open; close when it quits.
            if Date().timeIntervalSince(shownAt) > 10 { close() }
            return
        }
        guard settings.isActive, let bounds = Self.largestWindow(of: settings.processIdentifier),
              let primary = NSScreen.screens.first else {
            panel.orderOut(nil)
            return
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: bounds.midX, y: primary.frame.height - bounds.midY)) } ?? primary
        let frame = Permissions.helperFrame(settingsWindow: bounds, primaryScreenHeight: primary.frame.height,
                                            visible: screen.visibleFrame, size: size)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    /// Window bounds come without Screen Recording permission; only window titles need it.
    private static func largestWindow(of pid: pid_t) -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { info -> CGRect? in
                guard let b = info[kCGWindowBounds as String] else { return nil }
                return CGRect(dictionaryRepresentation: b as! CFDictionary)
            }
            .max { $0.width * $0.height < $1.width * $1.height }
    }
}

private struct DragHelperView: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            DraggableAppIcon()
                .frame(width: 52, height: 52)
                .help("Drag into the list")
            VStack(alignment: .leading, spacing: 3) {
                Text("Drag Mossad into the list above")
                    .font(.headline)
                Text("Then turn on the switch for \(title).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
    }
}

/// The app icon as a drag source that carries the Mossad.app file URL, as Finder does.
private struct DraggableAppIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { IconView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class IconView: NSImageView, NSDraggingSource {
        init() {
            super.init(frame: .zero)
            image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            imageScaling = .scaleProportionallyUpOrDown
            unregisterDraggedTypes() // An image view also takes drops; this one only gives.
        }

        required init?(coder: NSCoder) { fatalError() }

        override func mouseDown(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
            item.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}
