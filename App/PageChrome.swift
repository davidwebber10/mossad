import AppKit
import SwiftUI

/// The canvas's icons: 16 pt grid, 1.5 pt round strokes, as template images in the asset catalog.
enum Icon: String, CaseIterable {
    case meetings, commitments, sparkle, people, analytics, settings, log
    case mic, micRound = "mic-round", micOff = "mic-off", cloud, coach
    case viewList = "view-list", viewCalendar = "view-calendar", viewOrg = "view-org"
    case download, more, compose, copy, search
    case chevronLeft = "chevron-left", chevronRight = "chevron-right", chevronDown = "chevron-down"
    case check, checkSmall = "check-small", send, arrowUp = "arrow-up", lock, note, document, plus, merge, pencil
    case key, qr, camera, link, stop, warning, clock, waveform, play, pause, bookmark
    case sparkleLarge = "sparkle-large", qrLarge = "qr-large"

    var image: Image { Image("icon-\(rawValue)") }
}

/// An icon at the size the canvas draws it; the stroke scales with it, as in the canvas's SVGs.
struct IconImage: View {
    let icon: Icon
    var size: CGFloat = 16

    init(_ icon: Icon, size: CGFloat = 16) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        icon.image.resizable().interpolation(.high).frame(width: size, height: size).accessibilityHidden(true)
    }
}

// MARK: Window

/// Empty chrome that moves the window, as the title bar does: drag to move, double-click to zoom or minimize as
/// the owner set in System Settings.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" { window.performMiniaturize(nil) } else if action != "None" { window.performZoom(nil) }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

/// Keeps the native traffic lights inside the sidebar card, where the canvas draws them: the first light's center
/// 30 pt from the left and 36 pt from the top, 20 pt apart. AppKit lays the title bar out again on resize and
/// focus changes, so they are placed again after each.
@MainActor
final class TrafficLights {
    private static let firstCenter = CGPoint(x: 30, y: 36)
    private static let spacing: CGFloat = 20
    private weak var window: NSWindow?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(window: NSWindow) {
        self.window = window
        let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                          NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                                          NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification,
                                          NSWindow.didBecomeMainNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            }
        }
        place()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func place() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview, let container = titlebar.superview else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
        let size = close.frame.size
        // Only as wide as the lights, so the taller title bar never covers the list's or toolbar's controls.
        let height = Self.firstCenter.y * 2
        let width = Self.firstCenter.x + Self.spacing * 2 + size.width
        container.frame = NSRect(x: 0, y: window.frame.height - height, width: width, height: height)
        titlebar.frame = container.bounds
        for (i, button) in buttons.enumerated() {
            button.setFrameOrigin(NSPoint(x: Self.firstCenter.x + Self.spacing * CGFloat(i) - size.width / 2,
                                          y: height - Self.firstCenter.y - size.height / 2))
        }
    }
}

// MARK: Columns

/// A list column: its own title row (15 pt semibold, 36 pt), then the list. The trailing edge drags to resize it;
/// the width is kept per page.
struct ListColumn<Content: View>: View {
    let title: String
    @AppStorage private var width: Double
    @ViewBuilder let content: Content
    @State private var dragStart: Double?

    init(_ title: String, widthKey: String, @ViewBuilder content: () -> Content) {
        self.title = title
        _width = AppStorage(wrappedValue: Double(Chrome.listWidth), "listWidth.\(widthKey)")
        self.content = content()
    }

    private var clamped: CGFloat { min(max(CGFloat(width), Chrome.listWidthRange.lowerBound), Chrome.listWidthRange.upperBound) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .semibold)).tracking(-0.15)
                .foregroundStyle(Palette.ink)
                .padding(.leading, Chrome.listTitleLeading)
                .frame(maxWidth: .infinity, minHeight: Chrome.listTitleHeight, maxHeight: Chrome.listTitleHeight, alignment: .leading)
                .background { WindowDragArea() }
                .padding(.top, Chrome.listTop)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }.frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: clamped)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) { resizeHandle }
        .zIndex(1)
    }

    /// 8 pt over the detail column's hairline.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .offset(x: 4)
            .onHover { inside in if inside { NSCursor.columnResize.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? Double(clamped)
                        dragStart = start
                        width = Double(min(max(CGFloat(start + value.translation.width), Chrome.listWidthRange.lowerBound),
                                           Chrome.listWidthRange.upperBound))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityHidden(true)
    }
}

/// The detail column: a hairline on its left, the 62 pt toolbar row, then the page. The page stops under the row
/// rather than scrolling under a band, as in the canvas.
struct DetailColumn<Toolbar: View, Content: View>: View {
    @ViewBuilder let toolbar: Toolbar
    @ViewBuilder let content: Content

    init(@ViewBuilder toolbar: () -> Toolbar, @ViewBuilder content: () -> Content) {
        self.toolbar = toolbar()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
        }
        .overlay(alignment: .leading) { Hairline(axis: .vertical) }
    }
}

/// The toolbar row: an optional title and subtitle on the left, the page's controls on the right, 8 pt apart.
struct PageToolbar<Leading: View, Trailing: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(title: String? = nil, subtitle: String? = nil, @ViewBuilder leading: () -> Leading = { EmptyView() },
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let title {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .semibold)).tracking(-0.15).foregroundStyle(Palette.ink)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                    }
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .layoutPriority(-1)
            }
            leading
            Spacer(minLength: 0)
            HStack(spacing: Chrome.groupGap) { trailing }
                .fixedSize()
        }
        .frame(maxHeight: .infinity)
        .padding(Chrome.toolbarInsets)
        .frame(height: Chrome.toolbarHeight)
        .frame(maxWidth: .infinity)
        .background { WindowDragArea() }
    }
}

// MARK: Glass controls

/// One glass capsule, 30 pt high with 3 pt inside, that holds segments or icon buttons.
struct ToolbarCapsule<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(.horizontal, Chrome.controlPadding)
            .frame(height: Chrome.controlHeight)
            .chromeGlass(in: Capsule())
    }
}

/// An icon cell inside a capsule, 30 x 24.
struct ToolbarIconButton: View {
    let icon: Icon
    let label: String
    var help: String?
    var size: CGFloat = 15
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            IconImage(icon, size: size)
                .frame(width: Chrome.iconCell.width, height: Chrome.iconCell.height)
                .contentShape(Capsule())
        }
        .buttonStyle(ChromeCellStyle())
        .accessibilityLabel(label)
        .help(help ?? label)
    }
}

/// A menu in an icon cell inside a capsule.
struct ToolbarMenuButton<Items: View>: View {
    let icon: Icon
    let label: String
    var help: String?
    @ViewBuilder let items: Items

    var body: some View {
        Menu { items } label: {
            IconImage(icon, size: 15)
                .frame(width: Chrome.iconCell.width, height: Chrome.iconCell.height)
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(ChromeCellStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(label)
        .help(help ?? label)
    }
}

/// Its own 30 pt glass circle, as the Log's copy and the Chat's new chat.
struct ToolbarCircleButton: View {
    let icon: Icon
    let label: String
    var help: String?
    var size: CGFloat = 15
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            IconImage(icon, size: size)
                .frame(width: Chrome.controlHeight, height: Chrome.controlHeight)
                .contentShape(Circle())
        }
        .buttonStyle(ChromeCellStyle())
        .chromeGlass(in: Circle())
        .accessibilityLabel(label)
        .help(help ?? label)
    }
}

/// Secondary ink, ink while pressed, dimmed when disabled.
struct ChromeCellStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Palette.ink : Palette.secondary)
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// The glass segmented control: the chosen segment is a white (dark: lifted) pill with a small shadow. Icon
/// segments are 32 x 24; text segments size to their words.
struct ToolbarSegmented<Value: Hashable>: View {
    struct Option {
        let value: Value
        let label: String
        var icon: Icon?
    }

    @Binding var selection: Value
    let options: [Option]
    var accessibilityLabel: String

    var body: some View {
        ToolbarCapsule {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button { selection = option.value } label: {
                    Group {
                        if let icon = option.icon {
                            IconImage(icon, size: 15).frame(width: Chrome.segment.width, height: Chrome.segment.height)
                        } else {
                            Text(option.label)
                                .font(.system(size: 12, weight: on ? .semibold : .regular))
                                .padding(.horizontal, 12)
                                .frame(height: Chrome.segment.height)
                        }
                    }
                    .foregroundStyle(on ? Palette.ink : Palette.secondary)
                    .background {
                        if on {
                            Capsule().fill(Palette.segmentOn).shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(on ? .isSelected : [])
                .help(option.label)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// A page's search ("Search titles and transcripts") as a 240 x 30 glass capsule; ⌘F focuses it and Esc clears it.
struct ToolbarSearchField: View {
    let prompt: String
    @Binding var query: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            IconImage(.search, size: 14).foregroundStyle(Palette.tertiaryMark)
            TextField(prompt, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .focused($focused)
                .onExitCommand { query = ""; focused = false }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.tertiaryMark)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(width: Chrome.searchWidth, height: Chrome.controlHeight)
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .chromeGlass(in: Capsule())
        .background {
            Button("Search") { focused = true }.keyboardShortcut("f").opacity(0).accessibilityHidden(true)
        }
    }
}
