import MossadCore
import SwiftUI

/// An audio file that iOS handed to the app, such as a call recording from "Share Audio" in Notes.
struct IncomingAudio: Identifiable, Equatable {
    let url: URL
    let id = UUID()
}

extension View {
    /// The import screen for a handed audio file, while `shows` is true. The recorder's own screen shows it over
    /// itself, so a file shared during a room recording is not hidden behind it.
    func callImportSheet(when shows: Bool) -> some View { modifier(CallImportSheet(shows: shows)) }
}

private struct CallImportSheet: ViewModifier {
    let shows: Bool
    @Environment(PhoneProfiles.self) private var profiles

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { shows ? profiles.incomingAudio : nil },
                                    set: { if shows { profiles.incomingAudio = $0 } })) { CallImportScreen(incoming: $0) }
    }
}

/// "Add call": a shared call recording becomes a meeting with one button. The rules are `CallImport`'s; this page
/// only asks.
struct CallImportScreen: View {
    let incoming: IncomingAudio
    @Environment(PhoneStore.self) private var store
    @Environment(PhoneProfiles.self) private var profiles
    @Environment(\.dismiss) private var dismiss
    @State private var file: CallImport.File?
    /// Empty until the owner types or takes the file's name: the phone's title is the meeting's for good.
    @State private var title = ""
    @State private var suggestion = ""
    @State private var start = Date()
    @State private var sure = true
    @State private var person: CallImport.Choice?
    @State private var refusal: CallImport.Refusal?
    @State private var adding = false
    /// The import worked: the store already removed the handed file.
    @State private var added = false
    /// The profile the recording goes to: the last one chosen, the first time the one that shows.
    @State private var target: PhoneProfile?

    private var chosen: PhoneProfile { target ?? profiles.book.importDefault }

    private var draft: CallImport.Draft? {
        file.map { CallImport.Draft(file: $0, title: title, start: start, person: person) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let refusal, refusal != .notSaved {
                        refused(refusal)
                    } else if let file {
                        rows(file)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, Space.xl)
                    }
                }
                .padding(.horizontal, Space.l)
            }
            .phonePage()
            .navigationTitle("Add call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { close() }.tint(Palette.ink).disabled(adding)
                }
            }
        }
        .interactiveDismissDisabled(adding)
        .task(id: incoming.id) { await read() }
        // Every way out but a success (Cancel, Close, a swipe, a newer file in its place) deletes the app's copy.
        .onDisappear { discardUnlessAdded() }
    }

    /// Only with two profiles or more: which profile the recording goes to.
    @ViewBuilder
    private var profileRow: some View {
        if profiles.book.showsProfiles {
            HairlineRow {
                VStack(alignment: .leading, spacing: Space.s) {
                    PhoneLabel("Profile")
                    Menu {
                        ForEach(profiles.book.listed) { p in
                            Button {
                                choose(p)
                            } label: {
                                if p.id == chosen.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                            }
                        }
                    } label: {
                        HStack(spacing: Space.s) {
                            ProfileDot(color: chosen.color, size: 10)
                            Text(chosen.name).textRole(.body).foregroundStyle(Palette.ink)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(Palette.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(PhoneProfileWords.label(chosen.name))
                }
            }
        }
    }

    /// A change of profile: the person goes (an id of one profile never travels in another), the new profile's
    /// people are read, and the file is checked again against that profile.
    private func choose(_ p: PhoneProfile) {
        guard p.id != chosen.id else { return }
        target = p
        person = nil
        Task {
            await profiles.uploader(for: p)?.loadPeople()
            if let draft { refusal = await profiles.importRefusal(draft, from: incoming.url, for: p) }
        }
    }

    @ViewBuilder
    private func rows(_ file: CallImport.File) -> some View {
        profileRow
        HairlineRow {
            VStack(alignment: .leading, spacing: Space.s) {
                PhoneLabel("Title")
                TextField(CallImport.placeholder, text: $title)
                    .accessibilityLabel("Title")
                    .textRole(.body)
                    .submitLabel(.done)
                if title.isEmpty, !suggestion.isEmpty {
                    Button("Use \u{201C}\(suggestion)\u{201D}") { title = suggestion }
                        .textRole(.secondary)
                        .tint(Palette.accent)
                        .frame(minHeight: 44, alignment: .leading)
                }
            }
        }
        HairlineRow {
            VStack(alignment: .leading, spacing: Space.s) {
                PhoneLabel("When")
                // No start whose end is after now: the plan would move it back with no word.
                DatePicker("Started", selection: $start, in: ...Date().addingTimeInterval(-(file.length ?? 0)),
                           displayedComponents: [.date, .hourAndMinute])
                    .textRole(.body)
                if let length = file.length {
                    Text("Length \(duration(length))").textRole(.secondary).foregroundStyle(Palette.secondary)
                }
                if !sure {
                    Text("Check the time. The file does not say when the call started.")
                        .textRole(.secondary).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        HairlineRow(divided: false) {
            NavigationLink {
                CallPersonPicker(person: $person, profile: chosen)
            } label: {
                VStack(alignment: .leading, spacing: Space.s) {
                    PhoneLabel("Who was on the call")
                    HStack {
                        Text(person?.name ?? "Optional")
                            .textRole(.body)
                            .foregroundStyle(person == nil ? Palette.secondary : Palette.ink)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Palette.tertiary).accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        if refusal == .notSaved {
            Text(CallImport.Refusal.notSaved.message)
                .textRole(.secondary).foregroundStyle(Palette.recording)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.m)
        }
        if profiles.uploader(for: chosen) == nil {
            Text(PhoneProfileWords.cannotOpen).textRole(.secondary).foregroundStyle(Palette.recording).padding(.top, Space.l)
        } else {
            Button {
                Task { await add() }
            } label: {
                if adding { ProgressView().tint(Palette.onAccent) } else { Text("Add to Mossad") }
            }
            .accessibilityLabel(adding ? "Adding to Mossad" : "Add to Mossad")
            .buttonStyle(PhoneFillButtonStyle(wide: true))
            .disabled(adding)
            .padding(.top, Space.l)
        }
    }

    private func refused(_ refusal: CallImport.Refusal) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(refusal.message)
                .textRole(.body).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button("Close") { close() }
                .buttonStyle(PhoneFillButtonStyle(wide: true))
        }
        .padding(.top, Space.xl)
    }

    private func read() async {
        let url = incoming.url
        let f = await Task.detached { await CallImport.read(url) }.value
        let found = CallImport.start(metadata: f.metadataDate, file: f.fileDate, length: f.length ?? 0, now: Date())
        suggestion = CallImport.title(fileName: f.name)
        start = found.date
        sure = found.sure
        file = f
        #if DEBUG
        // `MOSSAD_IMPORT_PROFILE=<id>` picks a listed profile for the import.
        if let id = PhoneStore.hook("MOSSAD_IMPORT_PROFILE"), let p = profiles.book.listed.first(where: { $0.id == id }) { target = p }
        #endif
        await profiles.uploader(for: chosen)?.loadPeople()
        if let draft { refusal = await profiles.importRefusal(draft, from: url, for: chosen) }
        #if DEBUG
        // Development hooks for a check with no taps: `MOSSAD_IMPORT_PERSON=<name>` names the person as typed, and
        // `MOSSAD_IMPORT_ADD=1` taps "Add to Mossad".
        if let name = PhoneStore.hook("MOSSAD_IMPORT_PERSON") { person = CallImport.typed(name, among: profiles.importChoices(name, for: chosen)) }
        if refusal == nil, PhoneStore.hook("MOSSAD_IMPORT_ADD") == "1" { await add() }
        #endif
    }

    private func add() async {
        guard let draft else { return }
        adding = true
        defer { adding = false }
        let into = chosen
        switch await profiles.importCall(draft, from: incoming.url, for: into) {
        case .success:
            added = true
            profiles.remember(importTarget: into.id)
            profiles.discardIncoming(incoming.url)
            // The list changes only when the recording is in the profile that shows.
            if into.id == store.context.id {
                store.tab = .meetings
                store.path = []
            }
            dismiss()
        case .failure(let r):
            refusal = r
        }
    }

    private func close() { dismiss() }

    private func discardUnlessAdded() {
        // A newer share of the same file in its place keeps it for that screen.
        guard !added, profiles.incomingAudio.map({ $0.id != incoming.id && $0.url == incoming.url }) != true else { return }
        profiles.discardIncoming(incoming.url)
    }
}

/// One person at most: a saved person, a name as typed, or nobody.
private struct CallPersonPicker: View {
    @Binding var person: CallImport.Choice?
    let profile: PhoneProfile
    @Environment(PhoneProfiles.self) private var profiles
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let choices = profiles.importChoices(query, for: profile)
        List {
            if let typed = CallImport.typed(query, among: choices), !choices.contains(typed) {
                Button("Use \u{201C}\(typed.name)\u{201D}") { pick(typed) }
            }
            ForEach(choices, id: \.self) { c in
                Button { pick(c) } label: {
                    HStack {
                        Text(c.name).foregroundStyle(Palette.ink)
                        Spacer()
                        if c == person { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
                    }
                }
                .accessibilityAddTraits(c == person ? .isSelected : [])
            }
            Button("Nobody") { pick(nil) }.foregroundStyle(Palette.secondary)
        }
        .searchable(text: $query, prompt: "Name")
        .navigationTitle("Who was on the call")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pick(_ choice: CallImport.Choice?) {
        person = choice
        dismiss()
    }
}
