import MossadCore
import SwiftUI

/// Mossad on the iPhone: the meetings the Mac recorded, read from iCloud, with Chat as the coach. It records nothing.
@main
struct MossadPhoneApp: App {
    @StateObject private var store = PhoneStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            TabView(selection: $store.tab) {
                Tab("Meetings", systemImage: "bubble.left.and.text.bubble.right", value: .meetings) { MeetingsListView() }
                Tab("Commitments", systemImage: "checkmark.circle", value: .commitments) { CommitmentsScreen() }
                    .badge(store.commitments.visible.filter { $0.status() == .overdue }.count)
                Tab("Chat", systemImage: "sparkles", value: .chat) { ChatScreen() }
                Tab("People", systemImage: "person.2", value: .people) { PeopleScreen() }
                Tab("Analytics", systemImage: "chart.bar.xaxis", value: .analytics) { AnalyticsScreen() }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .environmentObject(store)
            .task { await store.sync() }
            .onOpenURL { url in if let link = ChatLink.parse(url) { store.open(link) } }
            .onChange(of: phase) { _, now in if now == .active { Task { await store.sync() } } }
        }
    }
}
