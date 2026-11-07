import MossadCore
import SwiftUI

/// Mossad on the iPhone: the meetings the Mac recorded, read from iCloud or the owner's server, with Chat as the
/// coach, and a recorder for meetings in a room.
@main
struct MossadPhoneApp: App {
    @StateObject private var store = PhoneStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            TabView(selection: $store.tab) {
                Tab(value: .meetings) { MeetingsListView() } label: { Label("Meetings", systemImage: "list.bullet.rectangle").environment(\.symbolVariants, .none) }
                Tab(value: .commitments) { CommitmentsScreen() } label: { Label("Tasks", systemImage: "checkmark.circle").environment(\.symbolVariants, .none) }
                Tab(value: .chat) { ChatScreen() } label: { Label("Chat", systemImage: "sparkle").environment(\.symbolVariants, .none) }
                Tab(value: .people) { PeopleScreen() } label: { Label("People", systemImage: "person.2").environment(\.symbolVariants, .none) }
                Tab(value: .analytics) { AnalyticsScreen() } label: { Label("Analytics", systemImage: "chart.bar.xaxis").environment(\.symbolVariants, .none) }
            }
            // The canvas draws the tabs as outlines, the selected one in the accent.
            .tabBarMinimizeBehavior(.onScrollDown)
            .tint(Palette.accent)
            .environmentObject(store)
            .preferredColorScheme(PhoneStore.previewScheme)
            .task { await store.sync() }
            .onOpenURL { url in if let link = ChatLink.parse(url) { store.open(link) } }
            .onChange(of: phase) { _, now in if now == .active { Task { await store.sync() } } }
        }
    }
}
