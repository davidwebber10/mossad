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
    @Environment(PhoneStore.self) private var store

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { shows ? store.incomingAudio : nil },
                                    set: { if shows { store.incomingAudio = $0 } })) { CallImportScreen(incoming: $0) }
    }
}

/// "Add call": a shared call recording becomes a meeting with one button. The rules are `CallImport`'s; this page
/// only asks.
struct CallImportScreen: View {
    let incoming: IncomingAudio
    @Environment(PhoneStore.self) private var store
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
    }

    @ViewBuilder
    private func rows(_ file: CallImport.File) -> some View {
        HairlineRow {
            VStack(alignment: .leading, spacing: Space.s) {
                PhoneLabel("Title")
                TextField(CallImport.placeholder, text: $title)
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
                DatePicker("Started", selection: $start, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
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
                CallPersonPicker(person: $person)
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
        Button {
            Task { await add() }
        } label: {
            if adding { ProgressView().tint(Palette.onAccent) } else { Text("Add to Mossad") }
        }
        .buttonStyle(PhoneFillButtonStyle(wide: true))
        .disabled(adding)
        .padding(.top, Space.l)
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
        if let draft { refusal = await store.importRefusal(draft, from: url) }
    }

    private func add() async {
        guard let draft else { return }
        adding = true
        defer { adding = false }
        switch await store.importCall(draft, from: incoming.url) {
        case .success:
            store.tab = .meetings
            store.path = []
            dismiss()
        case .failure(let r):
            refusal = r
        }
    }

    private func close() {
        // A file that could not be saved stays where iOS put it; the inbox is cleared after a day.
        if refusal != .notSaved { store.discardIncoming(incoming.url) }
        dismiss()
    }
}

/// One person at most: a saved person, a name as typed, or nobody.
private struct CallPersonPicker: View {
    @Binding var person: CallImport.Choice?
    @Environment(PhoneStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let choices = store.importChoices(query)
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
