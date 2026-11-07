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
                // The design's thin icons as templates; the selected tab takes the accent.
                Tab("Meetings", image: "tab-meetings", value: .meetings) { MeetingsListView() }
                Tab("Tasks", image: "tab-commitments", value: .commitments) { CommitmentsScreen() }
                Tab("Chat", image: "tab-sparkle", value: .chat) { ChatScreen() }
                Tab("Analytics", image: "tab-analytics", value: .analytics) { AnalyticsScreen() }
                Tab("Search", image: "tab-search", value: .search, role: .search) { SearchScreen(query: $store.searchQuery) }
            }
            // The canvas draws the tabs as outlines, the selected one in the accent.
            .tabBarMinimizeBehavior(.onScrollDown)
            // On the TabView, not inside the tab: that is what sets Search apart from the tabs as its own circle and
            // turns it into the field, focused as soon as the tab is chosen.
            .searchable(text: $store.searchQuery, prompt: "Meetings, people, transcripts")
            .tabViewSearchActivation(.searchTabSelection)
            .onSubmit(of: .search) { store.remember(search: store.searchQuery) }
            .tint(Palette.accent)
            .environmentObject(store)
            .preferredColorScheme(PhoneStore.previewScheme)
            .task { await store.sync() }
            .onOpenURL { url in if let link = ChatLink.parse(url) { store.open(link) } }
            .onChange(of: phase) { _, now in if now == .active { Task { await store.sync() } } }
        }
    }
}
