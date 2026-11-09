import MossadCore
import SwiftUI
import UserNotifications

/// Mossad on the iPhone: the meetings the Mac recorded, read from iCloud or the owner's server, with Chat as the
/// coach, and a recorder for meetings in a room.
@main
struct MossadPhoneApp: App {
    @State private var store = PhoneStore()
    /// The Search tab's text, apart from the store: a keystroke redraws only what reads it.
    @State private var query = PhoneStore.searchHook
    @Environment(\.scenePhase) private var phase

    init() {
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $store.tab) {
                // The design's thin icons as templates; the selected tab takes the accent.
                Tab("Meetings", image: "tab-meetings", value: .meetings) { MeetingsListView() }
                Tab("Tasks", image: "tab-commitments", value: .commitments) { CommitmentsScreen() }
                Tab("Chat", image: "tab-sparkle", value: .chat) { ChatScreen() }
                Tab("Analytics", image: "tab-analytics", value: .analytics) { AnalyticsScreen() }
                Tab("Search", image: "tab-search", value: .search, role: .search) { SearchScreen(query: $query) }
            }
            // The canvas draws the tabs as outlines, the selected one in the accent.
            .tabBarMinimizeBehavior(.onScrollDown)
            // On the TabView, not inside the tab: that is what sets Search apart from the tabs as its own circle and
            // turns it into the field, focused as soon as the tab is chosen.
            .searchable(text: $query, prompt: "Meetings, people, transcripts")
            .tabViewSearchActivation(.searchTabSelection)
            .onSubmit(of: .search) { store.remember(search: query) }
            .tint(Palette.accent)
            .environment(store)
            .preferredColorScheme(PhoneStore.previewScheme)
            .task { await store.sync() }
            .onOpenURL { url in if let link = ChatLink.parse(url) { store.open(link) } }
            .onChange(of: phase) { _, now in if now == .active { Task { await store.sync() } } }
            // While a room recording waits for its meeting and the app stays open, look now and then.
            .task(id: phase == .active && store.waitsForTheMac) {
                guard phase == .active, store.waitsForTheMac else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled else { return }
                    await store.sync()
                }
            }
            .alert("Not on this iPhone", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.notice ?? "")
            }
        }
    }
}
