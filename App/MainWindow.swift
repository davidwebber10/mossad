import MossadCore
import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var controller: AppController
    @State private var welcoming = false

    var body: some View {
        NavigationSplitView {
            List(AppController.Section.allCases, selection: Binding(get: { controller.section }, set: { if let s = $0 { controller.section = s } })) { section in
                Label {
                    Text(section.rawValue)
                } icon: {
                    Image(systemName: section.symbol).foregroundStyle(Color.accentColor)
                }
                .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) { SidebarStatus() }
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
        .frame(minWidth: 980, minHeight: 600)
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
            welcoming = !UserDefaults.standard.bool(forKey: "welcomeDone") && controller.meetings.isEmpty
                || CommandLine.arguments.contains("--welcome")
        }

    }
}

/// What Mossad is doing, pinned under the sidebar. Recording, then permissions, then processing, then idle.
private struct SidebarStatus: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var permissions: PermissionsMonitor
    /// Dims with the window when another app is in front, as the system's own sidebars do.
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        HStack(spacing: 8) {
            if case .recording(_, let since) = controller.status {
                StatusDot(color: Theme.recording, pulsing: true)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text("Recording \(elapsed(since, context.date))\(controller.isMuted ? " · muted" : "")").monospacedDigit()
                }
            } else if !permissions.allGood {
                StatusDot(color: Theme.warning)
                Button(permissionsText(permissions.problemCount)) { controller.section = .settings }
                    .buttonStyle(.plain)
            } else if controller.processing > 0 {
                ProgressView().controlSize(.mini)
                Text("Processing \(controller.processing) \(controller.processing == 1 ? "call" : "calls")")
            } else {
                StatusDot(color: Theme.listening)
                Text("Waiting for a call")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .opacity(appearsActive ? 1 : 0.55)
    }
}

func permissionsText(_ count: Int) -> String {
    count == 1 ? "1 permission needs attention" : "\(count) permissions need attention"
}
