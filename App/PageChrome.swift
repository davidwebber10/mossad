import AppKit
import MossadCore
import SwiftUI

extension EnvironmentValues {
    /// The main window's width, so a list column can leave the detail its minimum.
    @Entry var windowWidth: CGFloat = .infinity
    /// Opens the search of everything (Command-K); the toolbar row's last button. Nil outside the main window.
    @Entry var openGlobalSearch: (@MainActor () -> Void)?
}

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

/// Empty chrome that moves the window, as the title bar does: drag to move, double-click as the owner set in System
/// Settings ("Double-click a window's title bar to" zoom, fill, or minimize).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else { window.performDrag(with: event); return }
            switch DoubleClickAction(defaultsValue: UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")) {
            case .zoom: window.performZoom(nil)
            case .fill: WindowFill.toggle(window)
            case .minimize: window.performMiniaturize(nil)
            case .none: break
            }
        }
    }
}

/// The system's Fill: the window takes the screen's whole visible area, and a second double-click puts it back.
@MainActor
enum WindowFill {
    private static var before: [ObjectIdentifier: NSRect] = [:]

    static func toggle(_ window: NSWindow) {
        guard let screen = window.screen else { return }
        let id = ObjectIdentifier(window)
        if window.frame == screen.visibleFrame, let previous = before[id] {
            before[id] = nil
            window.setFrame(previous, display: true, animate: true)
        } else {
            before[id] = window.frame
            window.setFrame(screen.visibleFrame, display: true, animate: true)
        }
    }
}

/// Keeps the native traffic lights inside the sidebar card, where the canvas draws them: the first light's center
/// 30 pt from the left and 36 pt from the top, 20 pt apart. AppKit lays the title bar out again on many occasions
/// (resize, focus, minimize and restore, a display or backing change, an appearance change, full screen), and not
/// all of them post a window notification, so the lights are also placed again whenever the title bar's views
/// change frame. Placing compares first, so it never sets a frame that is already right.
@MainActor
final class TrafficLights {
    private static let firstCenter = CGPoint(x: 30, y: 36)
    private static let spacing: CGFloat = 20
    private weak var window: NSWindow?
    private let onFullScreen: (Bool) -> Void
    nonisolated(unsafe) private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    nonisolated(unsafe) private var frameObservers: [NSObjectProtocol] = []
    private var appearance: NSKeyValueObservation?
    private weak var watchedContainer: NSView?
    private var scheduled = false

    init(window: NSWindow, onFullScreen: @escaping (Bool) -> Void) {
        self.window = window
        self.onFullScreen = onFullScreen
        let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                          NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                          NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                                          NSWindow.didChangeScreenNotification, NSWindow.didDeminiaturizeNotification,
                                          NSWindow.didChangeBackingPropertiesNotification, NSWindow.didExitFullScreenNotification]
        for name in names { observe(name, of: window) { $0.placeSoon() } }
        observe(NSWindow.willEnterFullScreenNotification, of: window) { $0.onFullScreen(true) }
        observe(NSWindow.didEnterFullScreenNotification, of: window) { $0.onFullScreen(true) }
        observe(NSWindow.willExitFullScreenNotification, of: window) { $0.onFullScreen(false) }
        observe(NSApplication.didChangeScreenParametersNotification, of: nil) { $0.placeSoon() }
        // Reduce Transparency and Increase Contrast.
        observe(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, of: nil, in: NSWorkspace.shared.notificationCenter) { $0.placeSoon() }
        appearance = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.placeSoon() }
        }
        onFullScreen(window.styleMask.contains(.fullScreen))
        place()
    }

    deinit {
        observers.forEach { $0.0.removeObserver($0.1) }
        frameObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func observe(_ name: Notification.Name, of object: AnyObject?, in center: NotificationCenter = .default,
                         _ run: @escaping @MainActor (TrafficLights) -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { run(self) } }
        }
        observers.append((center, token))
    }

    /// Now, and once more after AppKit's own layout pass, which can follow the notification.
    private func placeSoon() {
        // Also catches a full-screen attempt that failed after willEnter.
        if let window { onFullScreen(window.styleMask.contains(.fullScreen)) }
        place()
        placeLater()
    }

    func place() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview, let container = titlebar.superview else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
        let size = close.frame.size
        // Only as wide as the lights, so the taller title bar never covers the list's or toolbar's controls.
        let height = Self.firstCenter.y * 2
        let width = Self.firstCenter.x + Self.spacing * 2 + size.width
        let frame = NSRect(x: 0, y: window.frame.height - height, width: width, height: height)
        if container.frame != frame { container.frame = frame }
        if titlebar.frame != container.bounds { titlebar.frame = container.bounds }
        for (i, button) in buttons.enumerated() {
            let origin = NSPoint(x: Self.firstCenter.x + Self.spacing * CGFloat(i) - size.width / 2,
                                 y: height - Self.firstCenter.y - size.height / 2)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
        watchFrames(of: [container, titlebar] + buttons, container: container)
    }

    /// AppKit can swap the title bar's views (after full screen, for example), so the watch follows the container.
    private func watchFrames(of views: [NSView], container: NSView) {
        guard container !== watchedContainer else { return }
        watchedContainer = container
        frameObservers.forEach(NotificationCenter.default.removeObserver)
        frameObservers = views.map { view in
            view.postsFrameChangedNotifications = true
            return NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                // Later, not inside AppKit's layout, and once however many views moved.
                MainActor.assumeIsolated { self?.placeLater() }
            }
        }
    }

    private func placeLater() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = false
                self?.place()
            }
        }
    }
}

// MARK: Columns

/// A list column: its own title row (15 pt semibold, 36 pt), then the list. The trailing edge drags to resize it;
/// the width is kept per page. A list with a search has the magnifying glass at the end of the title row, and its
/// field comes down under the row.
struct ListColumn<Accessory: View, Content: View>: View {
    let title: String
    @AppStorage private var width: Double
    private let search: Binding<ListSearchState>?
    private let searchPrompt: String
    /// A small control at the trailing end of the title row, such as the Meetings filter.
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content
    @State private var dragStart: Double?
    @State private var leads = false

    init(_ title: String, widthKey: String, search: Binding<ListSearchState>? = nil, searchPrompt: String = "Search",
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        _width = AppStorage(wrappedValue: Double(Chrome.listWidth), "listWidth.\(widthKey)")
        self.search = search
        self.searchPrompt = searchPrompt
        self.accessory = accessory()
        self.content = content()
    }

    @Environment(\.windowWidth) private var windowWidth

    /// The saved width, narrowed while the window is too small for it so the detail keeps its minimum.
    private func fitted(_ value: Double) -> CGFloat {
        CGFloat(ColumnWidth.list(saved: value, range: Double(Chrome.listWidthRange.lowerBound)...Double(Chrome.listWidthRange.upperBound),
                                 window: Double(windowWidth), sidebar: Double(Chrome.sidebarWidth), detailMin: Double(Chrome.detailMinWidth)))
    }

    private var clamped: CGFloat { fitted(width) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s) {
                if leads { HistorySlot() }
                Text(title)
                    .font(.system(size: 15, weight: .semibold)).tracking(-0.15)
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    if let search { ListSearchToggle(state: search) }
                    accessory
                }
            }
            .padding(.leading, Chrome.listTitleLeading)
            .padding(.trailing, Space.m)
            .frame(maxWidth: .infinity, minHeight: Chrome.listTitleHeight, maxHeight: Chrome.listTitleHeight, alignment: .leading)
            .background { WindowDragArea() }
            .padding(.top, Chrome.listTop)
            if let search, search.wrappedValue.isShown {
                ListSearchField(prompt: searchPrompt, state: search)
                    .padding(.leading, 10).padding(.trailing, Space.m).padding(.bottom, Space.xs)
            }
            VStack(spacing: 0) { content }.frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: clamped)
        .frame(maxHeight: .infinity)
        .leadsWindow($leads)
        .overlay(alignment: .trailing) { resizeHandle }
        .zIndex(1)
    }

    /// 8 pt just right of the edge, over the detail column's hairline, so it never covers the list's scroll bar.
    /// The system sets and resets the cursor, so it cannot stick.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .offset(x: 8)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? Double(clamped)
                        dragStart = start
                        width = Double(fitted(start + value.translation.width))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityHidden(true)
    }
}

extension ListColumn where Accessory == EmptyView {
    init(_ title: String, widthKey: String, search: Binding<ListSearchState>? = nil, searchPrompt: String = "Search",
         @ViewBuilder content: () -> Content) {
        self.init(title, widthKey: widthKey, search: search, searchPrompt: searchPrompt, accessory: { EmptyView() }, content: content)
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
            OverflowRight { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .overlay(alignment: .leading) { Hairline(axis: .vertical) }
    }
}

/// Centers its content at the top, as a frame does, but content wider than the space starts at the leading edge, so
/// it overflows to the right rather than under the list.
struct OverflowRight: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(bounds.size))
            let x = size.width > bounds.width ? bounds.minX : bounds.midX - size.width / 2
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// The toolbar row: an optional title and subtitle on the left, the page's controls on the right, 8 pt apart, and
/// the search of everything last. A page whose list fills the detail (Tasks, Bookmarks) has its list search beside
/// the title, and the field comes down under the row.
struct PageToolbar<Leading: View, Trailing: View>: View {
    var title: String?
    var subtitle: String?
    var search: Binding<ListSearchState>?
    var searchPrompt = "Search"
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @Environment(\.openGlobalSearch) private var openGlobalSearch
    @State private var leads = false

    init(title: String? = nil, subtitle: String? = nil, search: Binding<ListSearchState>? = nil, searchPrompt: String = "Search",
         @ViewBuilder leading: () -> Leading = { EmptyView() }, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.search = search
        self.searchPrompt = searchPrompt
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if let search, search.wrappedValue.isShown {
                ListSearchField(prompt: searchPrompt, state: search)
                    .frame(maxWidth: Chrome.searchWidth + 96)
                    .padding(.leading, Chrome.toolbarInsets.leading - 10)
                    .padding(.trailing, Chrome.toolbarInsets.trailing)
                    .padding(.top, 2).padding(.bottom, Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            // At the list title's inset, so the buttons stay under the pointer from a list page to a full page.
            if leads { HistorySlot().padding(.leading, Chrome.listTitleLeading - Chrome.toolbarInsets.leading) }
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
            if let search { ListSearchToggle(state: search).padding(.leading, title == nil ? -6 : -4) }
            leading
            Spacer(minLength: 0)
            // Sized before the title: each control keeps its size.
            ToolbarTrailing {
                trailing
                if let openGlobalSearch { GlobalSearchButton(open: openGlobalSearch) }
            }
            .layoutPriority(1)
        }
        .frame(maxHeight: .infinity)
        .padding(Chrome.toolbarInsets)
        .frame(height: Chrome.toolbarHeight)
        .frame(maxWidth: .infinity)
        .leadsWindow($leads)
        .background { WindowDragArea() }
    }
}

/// The toolbar's trailing controls, 8 pt apart, at their own sizes; they never shrink or clip.
private struct ToolbarTrailing: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = self.widths(for: proposal.width, subviews)
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: widths.reduce(0, +) + gaps(subviews), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(for: bounds.width, subviews)) {
            let height = subview.sizeThatFits(.unspecified).height
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: height))
            x += width + Chrome.groupGap
        }
    }

    private func gaps(_ subviews: Subviews) -> CGFloat { CGFloat(max(subviews.count - 1, 0)) * Chrome.groupGap }

    private func widths(for available: CGFloat?, _ subviews: Subviews) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(.unspecified).width }
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

/// The search of everything: a glass circle at the end of every toolbar row. Command-K opens it from anywhere.
struct GlobalSearchButton: View {
    let open: @MainActor () -> Void

    var body: some View {
        ToolbarCircleButton(icon: .search, label: "Search everything", help: "Search meetings, transcripts, people, and tasks (⌘K)", action: open)
    }
}
