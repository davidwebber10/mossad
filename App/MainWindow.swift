import MossadCore
import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        NavigationSplitView {
            List(AppController.Section.allCases, selection: Binding(get: { controller.section }, set: { if let s = $0 { controller.section = s } })) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch controller.section {
            case .meetings: MeetingsView()
            case .voices: VoicesView()
            case .settings: SettingsView()
            case .log: LogView()
            }
        }
        .frame(minWidth: 860, minHeight: 540)
    }
}
