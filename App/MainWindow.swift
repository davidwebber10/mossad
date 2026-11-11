import MossadCore
import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var controller: AppController
    @State private var width: CGFloat = .infinity

    var body: some View {
        // The canvas's chrome, drawn here rather than by a split view: the sidebar is a floating card that never
        // collapses, and each page draws its own list column and toolbar row, with no band across the window.
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: Chrome.sidebarWidth)
            Group {
                switch controller.section {
                case .meetings: MeetingsView()
                case .bookmarks: BookmarksView()
                case .screens: AllScreensView()
                case .commitments: CommitmentsView()
                case .chat: ChatView()
                case .people: PeopleView()
                case .analytics: AnalyticsView()
                case .coach: CoachView()
                case .shares: SharesView()
                case .settings: SettingsView()
                case .log: LogView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.windowWidth, width)
        .ignoresSafeArea()
        .background { WindowBackdrop() }
        // The window's contentMinSize sets the limit. A minimum height here would apply below the toolbar, so it
        // asked for 600 pt plus the toolbar and the root grew past the window, centered, under the title bar.
        // Without any frame the content's own minimum held the window at 820 pt. So: any height, from the top.
        // No minimum width here either: the window's own minimum (Chrome.windowMinWidth) keeps the content from
        // ever being wider than the window, which is what slid the sidebar off the left edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .environment(\.animationsActive, controller.windowVisible)
        .overlay(alignment: .topTrailing) { if Rehearsal.isOn { RehearsalMark().padding(.top, 16).padding(.trailing, 16) } }
        .overlay { SearchOverlay(model: controller.search) }
        // Once the first list is read (off the main thread at launch): an empty list before that is not a new install.
        .onAppear { if controller.meetingsLoaded { openSetupForANewInstall() } }
        .onChange(of: controller.meetingsLoaded) { _, loaded in if loaded { openSetupForANewInstall() } }
    }

    /// Only a new install: someone with meetings already set Mossad up. A preview never opens setup unasked,
    /// and Rehearsal opens it at launch instead.
    private func openSetupForANewInstall() {
        if !Rehearsal.isOn, Onboarding.opensAtLaunch(finished: controller.onboardingFinished, hasMeetings: !controller.meetings.isEmpty,
                                                     preview: CommandLine.arguments.contains("--ui-preview"),
                                                     forced: CommandLine.arguments.contains("--welcome"), rehearsal: false) {
            controller.openOnboarding()
        }
    }
}

/// The Command-K palette over the whole window, when it is open.
private struct SearchOverlay: View {
    @ObservedObject var model: SearchModel

    var body: some View {
        if model.isOpen {
            SearchPalette(model: model)
                .transition(.opacity)
        }
    }
}

/// Warm paper with two soft washes, warm at the top left and cool at the bottom left, so the sidebar's glass has
/// something to carry, as in the canvas.
struct WindowBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let dark = scheme == .dark
        Palette.window
            .overlay {
                if !reduceTransparency, !PreviewAccessibility.reduceTransparency {
                    // The canvas's two washes: ellipses 640 x 420 at (-4%, 18%) and 520 x 520 at (8%, 102%), each
                    // fading out at 70% of its radius.
                    GeometryReader { g in
                        ZStack(alignment: .topLeading) {
                            wash(Color(light: OKLCH(lightness: 0.9, chroma: 0.06, hue: 55), dark: OKLCH(lightness: 0.42, chroma: 0.07, hue: 55))
                                    .opacity(dark ? 0.55 : 0.8),
                                 radii: CGSize(width: 640, height: 420), at: CGPoint(x: -0.04 * g.size.width, y: 0.18 * g.size.height))
                            wash(Color(light: OKLCH(lightness: 0.9, chroma: 0.05, hue: 240), dark: OKLCH(lightness: 0.36, chroma: 0.06, hue: 240))
                                    .opacity(dark ? 0.5 : 0.55),
                                 radii: CGSize(width: 520, height: 520), at: CGPoint(x: 0.08 * g.size.width, y: 1.02 * g.size.height))
                        }
                    }
                }
            }
            .ignoresSafeArea()
    }

    private func wash(_ color: Color, radii: CGSize, at center: CGPoint) -> some View {
        EllipticalGradient(stops: [.init(color: color, location: 0), .init(color: color.opacity(0), location: 0.7)])
            .frame(width: radii.width * 2, height: radii.height * 2)
            .position(center)
    }
}

/// The sections, with the open commitments and what needs the owner in Settings, then what Mossad is doing: a
/// floating glass card inset from the window, with the traffic lights inside it.
private struct Sidebar: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var permissions: PermissionsMonitor
    @State private var openCommitments = 0
    @State private var hovered: AppController.Section?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The native traffic lights sit here (TrafficLights places them); the row also moves the window. In full
            // screen the lights live in the hidden title bar, so the row goes.
            if !controller.fullScreen {
                WindowDragArea().frame(height: Chrome.lightsRow + Chrome.lightsToNav)
            }
            VStack(alignment: .leading, spacing: Chrome.navRowGap) {
                ForEach(AppController.Section.topLevel) { section in
                    switch section {
                    case .meetings:
                        // Meetings opens in place: its pages show under it while it or one of them is open. A click
                        // on Meetings itself opens the list of meetings.
                        SidebarItemGroup(expanded: controller.sidebarOpen(.meetings),
                                         children: AppController.Section.underMeetings.map { page in
                                             page == .commitments
                                                 ? SidebarChild(id: page, title: page.rawValue, count: openCommitments, countLabel: "\(openCommitments) open")
                                                 : SidebarChild(id: page, title: page.rawValue) },
                                         selection: controller.section.isUnderMeetings ? controller.section : nil,
                                         select: { controller.section = $0 }) { row(section) }
                    case .coach:
                        // Coach opens in place on its first page: its pages show under it while it is open.
                        SidebarItemGroup(expanded: controller.sidebarOpen(.coach),
                                         children: CoachPage.allCases.map { SidebarChild(id: $0, title: $0.title, count: $0 == .findings ? controller.findings.count : nil) },
                                         selection: controller.section == .coach ? controller.coachPage : nil,
                                         select: { controller.go(to: SidebarNav.Spot(item: .section(.coach), child: .coach($0))) }) { row(section) }
                    default:
                        row(section)
                    }
                }
            }
            Spacer(minLength: Space.m)
            SidebarStatus()
        }
        .padding(Chrome.sidebarPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .chromeGlass(in: RoundedRectangle(cornerRadius: Chrome.sidebarRadius, style: .continuous), fill: Palette.sidebar, shadow: .card)
        .padding(Chrome.sidebarInset)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.home) { go(SidebarNav.first(AppController.sidebarItems, at: controller.sidebarSpot)) }
        .onKeyPress(.end) { go(SidebarNav.last(AppController.sidebarItems, at: controller.sidebarSpot)) }
        .onKeyPress(characters: .letters) { press in
            // Only plain letters: a Command or Option shortcut is not a page name.
            guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
            return jump(to: AppController.Section.typeSelect(press.characters, from: controller.section)) }
        .task(id: controller.commitmentsVersion) {
            openCommitments = controller.commitmentBook.visible.filter { $0.done == nil }.count
        }
    }

    private func row(_ section: AppController.Section) -> some View {
        let on = controller.section == section
        return Button {
            controller.go(to: section)
        } label: {
            HStack(spacing: Chrome.navIconGap) {
                IconImage(section.icon, size: Chrome.navIcon).foregroundStyle(Palette.accent)
                Text(section.rawValue).foregroundStyle(on ? Palette.ink : Palette.navText).lineLimit(1)
                Spacer(minLength: 4)
                trailing(section)
            }
            .font(.system(size: 13, weight: on ? .medium : .regular))
            .padding(.horizontal, Chrome.navRowPadding)
            .frame(height: Chrome.navRowHeight)
            .background(on ? Palette.selection : hovered == section ? Palette.fill.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: Chrome.navRowRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Chrome.navRowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? section : (hovered == section ? nil : hovered) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func jump(to section: AppController.Section?) -> KeyPress.Result {
        guard let section else { return .ignored }
        controller.go(to: section)
        return .handled
    }

    /// The arrow keys go through the rows that show: the sections and the pages of the open one.
    private func move(_ by: Int) -> KeyPress.Result {
        go(SidebarNav.step(AppController.sidebarItems, from: controller.sidebarSpot, by: by))
    }

    private func go(_ spot: SidebarNav.Spot?) -> KeyPress.Result {
        guard let spot else { return .ignored }
        controller.go(to: spot)
        return .handled
    }

    @ViewBuilder
    private func trailing(_ section: AppController.Section) -> some View {
        switch section {
        // The open tasks show on Meetings while Tasks is hidden under it, as Coach shows its cards.
        case .meetings where openCommitments > 0 && !controller.sidebarOpen(.meetings):
            Text("\(openCommitments)")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(Palette.tertiary)
                .accessibilityLabel("\(openCommitments) open tasks")
        case .coach where !controller.findings.isEmpty && !controller.sidebarOpen(.coach):
            Text("\(controller.findings.count)")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(Palette.tertiary)
                .accessibilityLabel("\(controller.findings.count) to review")
        case .settings where !permissions.allGood:
            Text("\(permissions.problemCount)")
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Palette.onAccent)
                .padding(.horizontal, 6)
                .frame(minWidth: 18, minHeight: 18)
                .background(Palette.accentFill, in: Capsule())
                .accessibilityLabel(permissionsText(permissions.problemCount))
        default:
            EmptyView()
        }
    }
}

/// What Mossad is doing, pinned under the sidebar: a call being recorded, then permissions that need the owner as
/// a card, then calls being processed. Nothing when all is well, so the sidebar stays quiet.
private struct SidebarStatus: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var permissions: PermissionsMonitor
    /// Dims with the window when another app is in front, as the system's own sidebars do.
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if case .recording(_, let since) = controller.status {
                HStack(spacing: Space.s) {
                    StatusDot(color: Palette.recording, size: 7, pulsing: !controller.isPaused)
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text("Recording \(elapsed(since, context.date))\(controller.isMuted ? " · muted" : "")").monospacedDigit()
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
            }
            if !permissions.allGood {
                PermissionsCard()
            }
            UpdateCard(updater: controller.updater)
            if permissions.allGood, controller.processing > 0, controller.status == .idle {
                HStack(spacing: Space.s) {
                    Circle().fill(Palette.accentFill).frame(width: 7, height: 7)
                    Text("Processing \(controller.processing) \(controller.processing == 1 ? "call" : "calls")")
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 10)
            }
        }
        .opacity(appearsActive ? 1 : 0.55)
    }
}

/// The sidebar's call to act, as the canvas draws it: an accent-tinted card with a dot and a semibold title, quiet
/// lines under it, and the action in accent.
private struct SidebarCard<Lines: View>: View {
    let title: String
    let action: String
    var actionEnabled = true
    let perform: () -> Void
    @ViewBuilder let lines: Lines

    var body: some View {
        Button(action: perform) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(Palette.accentFill).frame(width: 7, height: 7)
                    Text(title).fontWeight(.semibold).foregroundStyle(Palette.ink)
                }
                // No vertical fixedSize: when the window measures its minimum it asks the sidebar at a tiny width,
                // and a fixed-size text there grows one word per line and held the window at 820 pt.
                lines.foregroundStyle(Palette.secondary)
                Text(action).fontWeight(.semibold).foregroundStyle(actionEnabled ? Palette.accent : Palette.secondary)
                    .padding(.top, 6)
            }
            .font(.system(size: 12))
            .lineSpacing(1.5)
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 8, trailing: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.accentTint, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        // Not disabled: a disabled button fades the whole card, and a waiting update still needs to read clearly.
        // VoiceOver reads it as text then, with no action to offer.
        .allowsHitTesting(actionEnabled)
        .accessibilityRemoveTraits(actionEnabled ? [] : .isButton)
        .accessibilityAddTraits(actionEnabled ? [] : .isStaticText)
    }
}

/// "3 permissions / Microphone, system audio, calendars / Review…": the accent means the owner needs to act.
private struct PermissionsCard: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var permissions: PermissionsMonitor

    private var missing: String {
        let names = permissions.items.filter { !$0.state.isGood }.map(\.title)
        guard let first = names.first else { return "" }
        return ([first] + names.dropFirst().map { $0.prefix(1).lowercased() + $0.dropFirst() }).joined(separator: ", ")
    }

    var body: some View {
        SidebarCard(title: permissions.problemCount == 1 ? "1 permission" : "\(permissions.problemCount) permissions",
                    action: "Review…") {
            UserDefaults.standard.set(SettingsPage.general.rawValue, forKey: "settingsPage")
            controller.section = .settings
        } lines: {
            Text(missing).lineLimit(3)
        }
        .accessibilityLabel("\(permissionsText(permissions.problemCount)): \(missing)")
        .accessibilityHint("Opens Settings")
    }
}

/// "Update available / Mossad 1.9.0 / what it brings / Update now", in the permissions card's look. An update
/// accepted during a call waits for the call to end, and the card says so.
private struct UpdateCard: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if let update = updater.available { card(update) }
    }

    private var action: String {
        if updater.waitingForCall { return "Installs after this call" }
        switch updater.progress.phase {
        case .idle: return "Update now"
        case .opening: return "Opening…"
        case .installing: return "Installing…"
        }
    }

    // canCheck is false while Sparkle has a session of its own open; a click then would do nothing.
    private var enabled: Bool { updater.canCheck && !updater.waitingForCall && updater.progress.canStart }

    private func card(_ update: AvailableUpdate) -> some View {
        let preview = update.notes.preview
        return SidebarCard(title: "Update available", action: action,
                    actionEnabled: enabled) {
            updater.installAvailable()
        } lines: {
            VStack(alignment: .leading, spacing: 0) {
                Text("Mossad \(update.version)")
                ForEach(Array(preview.lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("·")
                        Text(line).lineLimit(2)
                    }
                }
                if let more = preview.more { Text(more).foregroundStyle(Palette.tertiary).padding(.leading, 9) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Update available: Mossad \(update.version). \(preview.lines.joined(separator: ". "))\(enabled ? "" : ". \(action)")")
        .accessibilityHint(enabled ? "Installs the update" : "")
        .accessibilityRemoveTraits(enabled ? [] : .isButton)
    }
}

func permissionsText(_ count: Int) -> String {
    count == 1 ? "1 permission needs attention" : "\(count) permissions need attention"
}
