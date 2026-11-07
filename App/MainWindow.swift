import MossadCore
import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var controller: AppController
    @State private var welcoming = false

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 196, max: 240)
                // The sidebar always shows: hiding it saved nothing and lost the way around.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch controller.section {
                case .meetings: MeetingsView()
                case .commitments: CommitmentsView()
                case .chat: ChatView()
                case .people: PeopleView()
                case .analytics: AnalyticsView()
                case .settings: SettingsView()
                case .log: LogView()
                }
            }
        }
        .background { WindowBackdrop() }
        // The window's contentMinSize sets the limit. A minimum height here would apply below the toolbar, so it
        // asked for 600 pt plus the toolbar and the root grew past the window, centered, under the title bar.
        // Without any frame the content's own minimum held the window at 820 pt. So: any height, from the top.
        .frame(minWidth: 980, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .environment(\.animationsActive, controller.windowVisible)
        .sheet(isPresented: $welcoming) { WelcomeView() }
        // Development hook for screenshots: `--welcome-inline` draws the welcome in the window, not in a sheet.
        .overlay {
            if CommandLine.arguments.contains("--welcome-inline") {
                WelcomeView().background(.background, in: RoundedRectangle(cornerRadius: 16)).shadow(radius: 30)
            }
        }
        .onAppear {
            // Only a new install: someone with meetings already set Mossad up.
            // A preview opened on another page reads its meetings after this runs, so it never welcomes unasked.
            welcoming = !UserDefaults.standard.bool(forKey: "welcomeDone") && controller.meetings.isEmpty
                && !CommandLine.arguments.contains("--ui-preview")
                || CommandLine.arguments.contains("--welcome")
        }
    }
}

/// Warm paper with two soft washes, warm at the top left and cool at the bottom left, so the sidebar's glass has
/// something to carry, as in the canvas.
private struct WindowBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let dark = scheme == .dark
        Palette.window
            .overlay {
                if !reduceTransparency, !PreviewAccessibility.reduceTransparency {
                    GeometryReader { g in
                        ZStack {
                            RadialGradient(colors: [Color(light: OKLCH(lightness: 0.9, chroma: 0.06, hue: 55), dark: OKLCH(lightness: 0.42, chroma: 0.07, hue: 55))
                                .opacity(dark ? 0.55 : 0.8), .clear],
                                           center: UnitPoint(x: -0.04 * 1400 / max(g.size.width, 1), y: 0.18), startRadius: 0, endRadius: 520)
                            RadialGradient(colors: [Color(light: OKLCH(lightness: 0.9, chroma: 0.05, hue: 240), dark: OKLCH(lightness: 0.36, chroma: 0.06, hue: 240))
                                .opacity(dark ? 0.5 : 0.55), .clear],
                                           center: UnitPoint(x: 0.08 * 1400 / max(g.size.width, 1), y: 1.02), startRadius: 0, endRadius: 440)
                        }
                    }
                }
            }
            .ignoresSafeArea()
    }
}

/// The sections, with the open commitments and what needs the owner in Settings, then what Mossad is doing.
private struct Sidebar: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var permissions: PermissionsMonitor
    @State private var openCommitments = 0

    var body: some View {
        List(AppController.Section.allCases, selection: Binding(get: { controller.section }, set: { if let s = $0 { controller.section = s } })) { section in
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 18)
                Text(section.rawValue).foregroundStyle(Palette.ink)
                Spacer(minLength: 4)
                trailing(section)
            }
            .font(.system(size: 13, weight: controller.section == section ? .medium : .regular))
            .accessibilityElement(children: .combine)
            .tag(section)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarStatus() }
        .task(id: controller.commitmentsVersion) {
            openCommitments = controller.commitmentBook.visible.filter { $0.done == nil }.count
        }
    }

    @ViewBuilder
    private func trailing(_ section: AppController.Section) -> some View {
        switch section {
        case .commitments where openCommitments > 0:
            Text("\(openCommitments)")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(Palette.tertiary)
                .accessibilityLabel("\(openCommitments) open")
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
            } else if controller.processing > 0, controller.status == .idle {
                HStack(spacing: Space.s) {
                    Circle().fill(Palette.accentFill).frame(width: 7, height: 7)
                    Text("Processing \(controller.processing) \(controller.processing == 1 ? "call" : "calls")")
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 10)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .opacity(appearsActive ? 1 : 0.55)
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
        Button {
            UserDefaults.standard.set(SettingsPage.general.rawValue, forKey: "settingsPage")
            controller.section = .settings
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(Palette.accentFill).frame(width: 7, height: 7)
                    Text(permissions.problemCount == 1 ? "1 permission" : "\(permissions.problemCount) permissions")
                        .fontWeight(.semibold).foregroundStyle(Palette.ink)
                }
                // No vertical fixedSize: when the split view measures its minimum it asks the sidebar at a tiny width,
                // and a fixed-size text there grows one word per line and held the window at 820 pt.
                Text(missing).foregroundStyle(Palette.secondary).lineLimit(3)
                Text("Review…").fontWeight(.semibold).foregroundStyle(Palette.accent).padding(.top, 6)
            }
            .font(.system(size: 12))
            .lineSpacing(1.5)
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 8, trailing: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.accentTint, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(permissionsText(permissions.problemCount)): \(missing)")
        .accessibilityHint("Opens Settings")
    }
}

func permissionsText(_ count: Int) -> String {
    count == 1 ? "1 permission needs attention" : "\(count) permissions need attention"
}
