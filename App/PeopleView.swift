import MossadCore
import SwiftUI

/// The People pane: a list of saved people on the left and the selected person's profile on the right.
struct PeopleView: View {
    @EnvironmentObject var controller: AppController
    @State private var profiles: [VoiceProfile] = []
    @State private var stats: [String: PersonStats] = [:]
    @State private var loaded = false
    @State private var selection: String?
    @State private var query = ""
    @State private var editing: VoiceProfile?
    @State private var newName = ""
    @State private var newEmail = ""
    @State private var deleting: VoiceProfile?
    @State private var confirmDeleteAll = false

    private var selected: VoiceProfile? { profiles.first { $0.name == selection } }

    private var results: [VoiceProfile] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return profiles }
        return profiles.filter { $0.name.localizedCaseInsensitiveContains(q) || ($0.email?.localizedCaseInsensitiveContains(q) ?? false) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if loaded, profiles.isEmpty {
                listHeader
                Divider()
                ContentUnavailableView("No people yet", systemImage: "person.2",
                                       description: Text("Your voice is learned in your first call. Name other voices after a call."))
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        listHeader
                        PeopleList(profiles: results, stats: stats, selection: $selection, color: color(for:),
                                   rename: startEditing, delete: { deleting = $0 })
                    }
                    .frame(width: 330)
                    Divider()
                    Group {
                        if let p = selected {
                            PersonProfileView(profile: p, stats: stats[p.name] ?? PersonStats(), color: color(for: p),
                                              others: profiles.filter { $0.name != p.name },
                                              rename: { startEditing(p) }, merge: { merge(p, into: $0) },
                                              delete: { deleting = p }, select: select)
                                .id(p.name)
                        } else {
                            ContentUnavailableView("Select a person", systemImage: "person.2")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            footer
        }
        .background(Theme.background)
        .onReceive(controller.$meetings) { _ in Task { await reload() } }
        .sheet(item: Binding(get: { editing.map(Wrapped.init) }, set: { editing = $0?.profile })) { item in editSheet(item.profile) }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let p = deleting { edit { try controller.library.delete(p.name) } }
                deleting = nil
            }
        } message: {
            Text("Mossad will ask for this voice's name again the next time it hears it.")
        }
        .confirmationDialog("Delete every saved voice?", isPresented: $confirmDeleteAll) {
            Button("Delete all voices", role: .destructive) {
                controller.deleteAllVoices()
                Task { await reload() }
            }
        } message: {
            Text("Mossad forgets every voice it learned, including yours. Meeting notes keep their names.")
        }
    }

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People").font(.system(size: 18, weight: .bold)).kerning(-0.3)
            SearchField(text: $query, prompt: "Search names and emails")
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 8, trailing: 12))
        .frame(maxWidth: 330, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "lock")
            Text("Voice fingerprints are biometric data. They stay on this Mac in the Voices folder and are never uploaded.")
            Spacer()
            Button("Delete all saved voices") { confirmDeleteAll = true }
                .buttonStyle(.link).foregroundStyle(.red)
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .padding(EdgeInsets(top: 10, leading: 20, bottom: 12, trailing: 20))
    }

    private func color(for p: VoiceProfile) -> Color {
        let i = profiles.firstIndex { $0.name == p.name } ?? 0
        return Theme.speakerPalette[i % Theme.speakerPalette.count]
    }

    private func select(_ name: String) {
        if profiles.contains(where: { $0.name == name }) { selection = name }
    }

    private func merge(_ p: VoiceProfile, into target: VoiceProfile) {
        edit { try controller.library.merge(p.name, into: target.name) }
        controller.renamePerson(p.name, to: target.name)
        selection = target.name
    }

    private func editSheet(_ p: VoiceProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit \(p.name)").font(.headline)
            TextField("Name", text: $newName).textFieldStyle(.roundedBorder)
            TextField("Email (optional)", text: $newEmail).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { editing = nil }
                Button("Save") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    let email = newEmail.trimmingCharacters(in: .whitespaces)
                    edit {
                        if !name.isEmpty, name != p.name { try controller.library.rename(p.name, to: name) }
                        try controller.library.setEmail(email.isEmpty ? nil : email, for: name.isEmpty ? p.name : name)
                    }
                    if !name.isEmpty, name != p.name {
                        controller.renamePerson(p.name, to: name)
                        selection = name
                    }
                    controller.relinkEmails()
                    editing = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func startEditing(_ p: VoiceProfile) {
        newName = p.name
        newEmail = p.email ?? ""
        editing = p
    }

    /// Stats first, then profiles: a list does not redraw its rows when the stats arrive after them.
    private func reload() async {
        let records = controller.meetings
        let computed = await Task.detached(priority: .utility) { PersonStatistics.compute(records) }.value
        stats = computed
        profiles = controller.library.profiles.sorted { a, b in
            if a.isOwner != b.isOwner { return a.isOwner }
            let la = computed[a.name]?.lastHeard ?? .distantPast, lb = computed[b.name]?.lastHeard ?? .distantPast
            return la != lb ? la > lb : a.name < b.name
        }
        loaded = true
        if selected == nil { selection = profiles.first?.name }
    }

    private func edit(_ change: () throws -> Void) {
        do { try change() } catch { Log.error("Voice library edit failed: \(error)") }
        Task { await reload() }
    }
}

/// The left column: "You", then everyone else by most recent meeting.
private struct PeopleList: View {
    let profiles: [VoiceProfile]
    let stats: [String: PersonStats]
    @Binding var selection: String?
    let color: (VoiceProfile) -> Color
    let rename: (VoiceProfile) -> Void
    let delete: (VoiceProfile) -> Void

    var body: some View {
        List(selection: $selection) {
            section("You", profiles.filter(\.isOwner))
            section("People", profiles.filter { !$0.isOwner })
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [VoiceProfile]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items, id: \.name) { p in
                    PersonRow(profile: p, stats: stats[p.name], color: color(p))
                        .tag(p.name)
                        .contextMenu {
                            Button("Rename…") { rename(p) }
                            if !p.isOwner { Button("Delete…", role: .destructive) { delete(p) } }
                        }
                }
            } header: {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct PersonRow: View {
    let profile: VoiceProfile
    let stats: PersonStats?
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let email = profile.email {
                    Text(email).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(meetingsText(stats?.meetings.count ?? 0))
                if let last = stats?.lastHeard { Text(dayWord(last)) }
            }
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

func meetingsText(_ count: Int) -> String { count == 1 ? "1 meeting" : "\(count) meetings" }

private struct Wrapped: Identifiable {
    let profile: VoiceProfile
    var id: String { profile.name }
}

extension VoiceProfile: @retroactive Identifiable {
    public var id: String { name }
}
