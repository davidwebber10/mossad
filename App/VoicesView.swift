import MossadCore
import SwiftUI

/// The voice library as a table: rename (with email), merge, or delete people.
struct VoicesView: View {
    @EnvironmentObject var controller: AppController
    @State private var profiles: [VoiceProfile] = []
    @State private var stats: [String: VoiceStats] = [:]
    @State private var selection: String?
    @State private var editing: VoiceProfile?
    @State private var newName = ""
    @State private var newEmail = ""
    @State private var deleting: VoiceProfile?
    @State private var confirmDeleteAll = false

    private var selected: VoiceProfile? { profiles.first { $0.name == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Voices").font(.system(size: 18, weight: .bold)).kerning(-0.3)
                Spacer()
                Button("Rename") { if let p = selected { startEditing(p) } }.disabled(selected == nil)
                Menu("Merge") {
                    Section("Merge into") {
                        ForEach(profiles.filter { $0.name != selection }, id: \.name) { target in
                            Button(target.name) {
                                if let p = selected { edit { try controller.library.merge(p.name, into: target.name) } }
                            }
                        }
                    }
                }
                .fixedSize()
                .disabled(selected == nil || selected?.isOwner == true)
                Button("Delete", role: .destructive) { deleting = selected }
                    .foregroundStyle(.red)
                    .disabled(selected == nil || selected?.isOwner == true)
            }
            .controlSize(.small)
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 10, trailing: 20))

            if profiles.isEmpty {
                ContentUnavailableView("No voices yet", systemImage: "person.2",
                                       description: Text("Your voice is learned in your first call. Name other voices after a call."))
            } else {
                table
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.separator))
                    .padding(.horizontal, 20)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "lock")
                Text("Voice fingerprints are biometric data. They stay on this Mac in the Voices folder and are never uploaded.")
                Spacer()
                Button("Delete all saved voices") { confirmDeleteAll = true }
                    .buttonStyle(.link).foregroundStyle(.red)
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(EdgeInsets(top: 14, leading: 20, bottom: 16, trailing: 20))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await reload() }
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

    private var table: some View {
        let showEmail = profiles.contains { $0.email != nil }
        return Table(of: VoiceProfile.self, selection: $selection) {
            TableColumn("Name") { p in
                HStack(spacing: 8) {
                    Circle().fill(color(for: p)).frame(width: 8, height: 8)
                    Text(p.isOwner ? "\(p.name) (you)" : p.name).fontWeight(.medium)
                }
            }
            .width(ideal: 180)
            if showEmail {
                TableColumn("Email") { p in Text(p.email ?? "").opacity(0.75) }.width(ideal: 200)
            }
            TableColumn("Meetings") { p in Text("\(stats[p.name]?.meetings ?? 0)").monospacedDigit() }
                .width(ideal: 80)
            TableColumn("Last heard") { p in Text(stats[p.name]?.lastHeard.map(dayWord) ?? "").opacity(0.75) }
                .width(ideal: 120)
        } rows: {
            ForEach(profiles, id: \.name) { p in
                TableRow(p).contextMenu {
                    Button("Rename…") { startEditing(p) }
                    if !p.isOwner { Button("Delete…", role: .destructive) { deleting = p } }
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { names in
            if let name = names.first, let p = profiles.first(where: { $0.name == name }) { startEditing(p) }
        }
    }

    private func color(for p: VoiceProfile) -> Color {
        let i = profiles.firstIndex { $0.name == p.name } ?? 0
        return Theme.speakerPalette[i % Theme.speakerPalette.count]
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

    /// Profiles first (owner on top), then meeting counts computed off the main actor.
    private func reload() async {
        // The counts come first: the table does not redraw its cells when they arrive after the rows.
        let records = controller.meetings
        stats = await Task.detached(priority: .utility) { VoiceStatistics.compute(records) }.value
        profiles = controller.library.profiles.sorted { ($0.isOwner ? 0 : 1, $0.name) < ($1.isOwner ? 0 : 1, $1.name) }
    }

    private func edit(_ change: () throws -> Void) {
        do { try change() } catch { Log.error("Voice library edit failed: \(error)") }
        Task { await reload() }
    }
}

private struct Wrapped: Identifiable {
    let profile: VoiceProfile
    var id: String { profile.name }
}

extension VoiceProfile: @retroactive Identifiable {
    public var id: String { name }
}
