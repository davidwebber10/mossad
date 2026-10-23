import MossadCore
import SwiftUI

/// Every action item, newest meeting first; "Mine" shows only the owner's.
struct ActionItemsView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var mine = true

    var body: some View {
        List {
            Picker("Show", selection: $mine) {
                Text("Mine").tag(true)
                Text("Everyone").tag(false)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            ForEach(store.meetings.filter { !items($0).isEmpty }, id: \.id) { r in
                Section {
                    ForEach(Array(items(r).enumerated()), id: \.offset) { _, item in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.task)
                                if !mine, let owner = item.owner { Text(owner).font(.caption).foregroundStyle(.secondary) }
                            }
                        } icon: { Image(systemName: "circle").foregroundStyle(.tertiary) }
                    }
                } header: {
                    NavigationLink(value: r.id) {
                        Text("\(r.title) · \(r.start.formatted(.dateTime.month(.abbreviated).day()))")
                    }
                }
            }
        }
        .navigationTitle("Action items")
        .refreshable { await store.sync() }
    }

    private func items(_ r: CallRecord) -> [ActionItem] {
        mine ? r.actionItems.filter { $0.owner == store.owner } : r.actionItems
    }
}
