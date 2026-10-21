import MossadCore
import SwiftUI

/// The voice library: rename, merge, or delete people.
struct VoicesView: View {
    @EnvironmentObject var controller: AppController
    @State private var profiles: [VoiceProfile] = []
    @State private var renaming: VoiceProfile?
    @State private var newName = ""
    @State private var deleting: VoiceProfile?

    var body: some View {
        List {
            Section {
                ForEach(profiles, id: \.name) { p in
                    HStack {
                        Image(systemName: p.isOwner ? "person.crop.circle.fill" : "person.crop.circle")
                        Text(p.name)
                        if p.isOwner { Text("you").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text("\(p.embeddings.count) sample\(p.embeddings.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        Menu {
                            Button("Rename…") { newName = p.name; renaming = p }
                            Menu("Merge into") {
                                ForEach(profiles.filter { $0.name != p.name }, id: \.name) { target in
                                    Button(target.name) { edit { try controller.library.merge(p.name, into: target.name) } }
                                }
                            }
                            Divider()
                            Button("Delete", role: .destructive) { deleting = p }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton)
                            .frame(width: 30)
                    }
                }
            } header: {
                Text("Mossad recognizes these voices in new calls. Merge two entries when one person was saved twice.")
            }
        }
        .overlay {
            if profiles.isEmpty {
                ContentUnavailableView("No voices yet", systemImage: "person.wave.2",
                                       description: Text("Your voice is learned in your first call. Name other voices after a call."))
            }
        }
        .onAppear(perform: reload)
        .sheet(item: Binding(get: { renaming.map(Wrapped.init) }, set: { renaming = $0?.profile })) { item in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename \(item.profile.name)").font(.headline)
                TextField("Name", text: $newName).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }
                    Button("Save") {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty { edit { try controller.library.rename(item.profile.name, to: name) } }
                        renaming = nil
                    }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 360)
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let p = deleting { edit { try controller.library.delete(p.name) } }
                deleting = nil
            }
        } message: {
            Text("Mossad will ask for this voice's name again the next time it hears it.")
        }
    }

    private func reload() { profiles = controller.library.profiles }

    private func edit(_ change: () throws -> Void) {
        do { try change() } catch { Log.error("Voice library edit failed: \(error)") }
        reload()
    }

    private struct Wrapped: Identifiable {
        let profile: VoiceProfile
        var id: String { profile.name }
    }
}
