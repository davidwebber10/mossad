import MossadCore
import SwiftUI
import UserNotifications

/// Mossad on the iPhone: the meetings the Mac recorded, read from iCloud or the owner's server, with Chat as the
/// coach, and a recorder for meetings in a room.
@main
struct MossadPhoneApp: App {
    @State private var profiles = PhoneProfiles.shared
    /// The Search tab's text, apart from the store: a keystroke redraws only what reads it.
    @State private var query = PhoneStore.searchHook
    @Environment(\.scenePhase) private var phase

    init() {
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
    }

    var body: some Scene {
        WindowGroup {
            // A switch builds a new store; the root is made again for it, so no view keeps the old one.
            PhoneRoot(query: $query)
                .environment(profiles.store)
                .id(profiles.store.context.id)
                .environment(profiles)
                .preferredColorScheme(PhoneStore.previewScheme)
                .task {
                    // The first sync does not wait for the Keychain read.
                    async let read: Void = profiles.refresh()
                    await profiles.pass()
                    await read
                }
                // The active profile left while a recording or an import ran: the switch goes once they end.
                .onChange(of: profiles.switchHeld) { _, held in
                    if !held { Task { await profiles.switchIfHeld() } }
                }
                // A shared audio file comes as a file URL, the app's own links as `mossad://`.
                .onOpenURL { url in
                    if url.isFileURL {
                        profiles.incomingAudio = IncomingAudio(url: url)
                    } else if let link = ChatLink.parse(url) {
                        profiles.store.open(link)
                    }
                }
                .onChange(of: phase) { _, now in
                    if now == .active {
                        Task {
                            await profiles.refresh()
                            await profiles.pass()
                        }
                    }
                }
                // While a recording waits for its meeting and the app stays open, look now and then.
                .task(id: phase == .active && profiles.waits) {
                    guard phase == .active, profiles.waits else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        guard !Task.isCancelled else { return }
                        await profiles.pass()
                    }
                }
        }
    }
}

/// The tabs of the profile that shows.
struct PhoneRoot: View {
    @Binding var query: String
    @Environment(PhoneStore.self) private var store

    var body: some View {
        @Bindable var store = store
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
        // Over the recorder's screen instead while it is open, so a shared file is never hidden behind it.
        .callImportSheet(when: !store.recorderScreenOpen)
        .alert("Not on this iPhone", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.notice ?? "")
        }
    }
}
