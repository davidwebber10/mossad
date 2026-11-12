import AppKit
import Combine
import MossadCore
import SwiftUI

/// Back and Forward in the main window. Each change of where the window is (the section, its page, the item, the
/// tab, the list's search, the Meetings filter) is taken a moment later as one place, so the changes of one move go
/// in as one step. A link, a search result, the Go menu, or a notification marks its move as a jump; a row clicked
/// in the list that shows is a refinement and takes the place of the current step (`NavigationHistory`).
@MainActor
final class NavigationModel: ObservableObject {
    /// What a page that keeps its own state says of itself: its mode or view, the item open, and its search text.
    struct Part: Equatable {
        var page: String?
        var item: String?
        var search: String?
    }

    @Published private(set) var history = NavigationHistory()
    /// Bumped when Back or Forward shows a place, so the page on screen takes its part.
    @Published private(set) var restoreTick = 0
    /// The place that Back or Forward shows, until the window shows it: no change meanwhile is a step.
    private(set) var pending: NavigationPlace?
    private var pendingSince = Date.distantPast
    private var parts: [AppController.Section: Part] = [:]
    private var jump = false
    private var noting: Task<Void, Never>?
    private var observers: [AnyCancellable] = []
    private var monitor: Any?
    private weak var controller: AppController?

    func part(_ section: AppController.Section) -> Part? { parts[section] }

    var canGoBack: Bool { controller.map { c in history.canGoBack(resolve: c.resolve) } ?? false }
    var canGoForward: Bool { controller.map { c in history.canGoForward(resolve: c.resolve) } ?? false }

    /// The places behind and ahead with their titles, the nearest first, for the buttons' menus.
    func backMenu() -> [String] { titles(history.backPlaces) }
    func forwardMenu() -> [String] { titles(history.forwardPlaces) }

    private func titles(_ places: [NavigationPlace]) -> [String] {
        guard let c = controller else { return [] }
        return places.prefix(15).compactMap { c.resolve($0).map(c.title(of:)) }
    }

    func attach(_ controller: AppController) {
        self.controller = controller
        let poke: (Any) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.note() } }
        observers = [
            controller.$section.sink(receiveValue: poke),
            controller.$coachPage.sink(receiveValue: poke),
            controller.$selectedMeetingID.sink(receiveValue: poke),
            controller.$meetingQuery.sink(receiveValue: poke),
            controller.meetingFilter.$filter.sink(receiveValue: poke),
            controller.series.$selected.sink(receiveValue: poke),
            // The tabs and Settings' page are the owner's saved choices (AppStorage).
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main).sink(receiveValue: poke),
        ]
        installMonitor()
    }

    /// The next step is a jump: another meeting from a link is a step even when Meetings is open.
    func jumpNext() {
        jump = true
        note()
    }

    func report(_ section: AppController.Section, _ part: Part) {
        guard parts[section] != part else { return }
        parts[section] = part
        note()
    }

    private func note() {
        guard noting == nil else { return }
        noting = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self?.record()
        }
    }

    private func record() {
        noting = nil
        guard let c = controller else { return }
        let place = c.currentPlace
        let step: NavigationHistory.Step = jump ? .jump : .refine
        jump = false
        if let target = pending {
            // A page that loads its list a moment later settles into the place; until it does, nothing is a step.
            if place == target || Date().timeIntervalSince(pendingSince) > 1 { pending = nil }
            if pending != nil || place == target { return }
        }
        history.visit(place, step)
    }

    func back(steps: Int = 1) {
        guard let c = controller, let place = history.goBack(steps: steps, resolve: c.resolve) else { return }
        show(place)
    }

    func forward(steps: Int = 1) {
        guard let c = controller, let place = history.goForward(steps: steps, resolve: c.resolve) else { return }
        show(place)
    }

    private func show(_ place: NavigationPlace) {
        noting?.cancel()
        noting = nil
        jump = false
        pending = place
        pendingSince = Date()
        controller?.apply(place)
        restoreTick += 1
    }

    /// Mouse buttons 4 and 5, and the three-finger swipe between pages, in the main window. The findings deck has
    /// its own swipe, so a swipe over it is left to it.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .swipe]) { [weak self] event in
            let type = event.type, button = event.buttonNumber, dx = event.deltaX
            let window = event.window.map(ObjectIdentifier.init)
            let handled = MainActor.assumeIsolated { self?.handle(type, button: button, deltaX: dx, in: window) ?? false }
            return handled ? nil : event
        }
    }

    private func handle(_ type: NSEvent.EventType, button: Int, deltaX: CGFloat, in window: ObjectIdentifier?) -> Bool {
        guard let c = controller, let main = c.mainWindow, window == ObjectIdentifier(main), main.attachedSheet == nil,
              !c.search.isOpen else { return false }
        switch type {
        case .otherMouseDown where button == 3: back()
        case .otherMouseDown where button == 4: forward()
        case .swipe where !c.showsFindingsDeck && deltaX != 0: deltaX > 0 ? back() : forward()
        default: return false
        }
        return true
    }
}

extension ListSearchState {
    /// The search text of a place: the field shows while it holds text.
    mutating func show(_ text: String?) {
        query = text ?? ""
        if text == nil { isOpen = false }
    }
}

extension EnvironmentValues {
    /// The main window's Back and Forward; nil outside it, where the toolbar shows no buttons.
    @Entry var navigation: NavigationModel?
}

extension View {
    /// The page's own part of the place, reported as it changes; `restore` takes the page back to a place that
    /// Back or Forward shows.
    func navigationPart(_ section: AppController.Section, _ part: NavigationModel.Part,
                        restore: @escaping (NavigationPlace) -> Void) -> some View {
        modifier(NavigationPartModifier(section: section, part: part, restore: restore))
    }
}

private struct NavigationPartModifier: ViewModifier {
    @EnvironmentObject var controller: AppController
    let section: AppController.Section
    let part: NavigationModel.Part
    let restore: (NavigationPlace) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                takePending()
                controller.navigation.report(section, part)
            }
            .onChange(of: part) { _, p in controller.navigation.report(section, p) }
            .onReceive(controller.navigation.$restoreTick.dropFirst()) { _ in takePending() }
    }

    private func takePending() {
        if let p = controller.navigation.pending, p.section == section.rawValue { restore(p) }
    }
}

/// Back and Forward at the leading edge of the window's toolbar: a click goes one step, a long press or a
/// right-click lists the places by title, as in Safari. Only the column at the window's leading edge shows them.
struct HistoryButtons: View {
    @ObservedObject var model: NavigationModel

    var body: some View {
        ToolbarCapsule {
            button(back: true)
            button(back: false)
        }
        .fixedSize()
    }

    private func button(back: Bool) -> some View {
        let enabled = back ? model.canGoBack : model.canGoForward
        let label = back ? "Back" : "Forward"
        return Menu {
            ForEach(Array((back ? model.backMenu() : model.forwardMenu()).enumerated()), id: \.offset) { i, title in
                Button(title) { back ? model.back(steps: i + 1) : model.forward(steps: i + 1) }
            }
        } label: {
            Image(systemName: back ? "chevron.backward" : "chevron.forward")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: Chrome.iconCell.width, height: Chrome.iconCell.height)
                .contentShape(Capsule())
        } primaryAction: {
            back ? model.back() : model.forward()
        }
        .menuStyle(.button)
        .buttonStyle(ChromeCellStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// The buttons, for the column at the window's leading edge, right of the sidebar (`leadsWindow`).
struct HistorySlot: View {
    @Environment(\.navigation) private var navigation

    var body: some View {
        if let navigation { HistoryButtons(model: navigation).padding(.trailing, 2) }
    }
}

extension View {
    /// Whether this column starts at the window's leading edge, right of the sidebar: only that column's row holds
    /// Back and Forward.
    func leadsWindow(_ leads: Binding<Bool>) -> some View {
        onGeometryChange(for: Bool.self, of: { $0.frame(in: .global).minX < Chrome.sidebarWidth + 2 }) { leads.wrappedValue = $0 }
    }
}
