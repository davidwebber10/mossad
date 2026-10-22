import MossadCore
import SwiftUI

/// Mossad on the iPhone: the meetings the Mac recorded, read from iCloud. It records nothing.
@main
struct MossadPhoneApp: App {
    @StateObject private var store = PhoneStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Meetings", systemImage: "bubble.left.and.text.bubble.right") { MeetingsListView() }
                Tab("Action items", systemImage: "checklist") { ActionItemsView() }
                Tab("Coach", systemImage: "person.wave.2") { CoachView() }
            }
            .environmentObject(store)
            .task { await store.sync() }
            .onOpenURL { url in
                if let link = ChatLink.parse(url) { store.path = [link.callID] }
            }
            .onChange(of: phase) { _, now in if now == .active { Task { await store.sync() } } }
        }
    }
}
