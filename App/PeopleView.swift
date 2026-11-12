import AppKit
import MossadCore
import SwiftUI

/// The People pane: the saved people and the selected person's profile, or the org chart. The toolbar's glass
/// toggle switches the two.
struct PeopleView: View {
    enum Mode: String { case list, org }

    @EnvironmentObject var controller: AppController
    @StateObject private var org = OrgState(paths: Paths.live)
    @State private var profiles: [VoiceProfile] = []
    @State private var stats: [String: PersonStats] = [:]
    @State private var loaded = false
    @State private var selection: String?
    @State private var search = ListSearchState()
    @State private var editing: VoiceProfile?
    @State private var newName = ""
    @State private var newEmail = ""
    @State private var deleting: VoiceProfile?
    @State private var confirmDeleteAll = false
    @State private var reviewingDuplicates = false
    @State private var importing = false
    @AppStorage("peopleMode") private var savedMode = Mode.list
    /// A preview's mode, kept out of the owner's saved choice.
    @State private var previewMode: Mode?
    private var mode: Mode {
        get { previewMode ?? savedMode }
        nonmutating set { previewMode = nil; savedMode = newValue }
    }
    @AppStorage("peopleSort") private var sort = PeopleSort.recent.rawValue
    /// Only people Mossad cannot recognize by voice yet.
    @AppStorage("peopleNeedsSample") private var needsSample = false
    /// Pairs the owner said are two people, by pair ID, separated by newlines.
    @AppStorage("peopleNotDuplicates") private var notDuplicates = ""

    private var duplicates: [PeopleDuplicates.Pair] {
        let dismissed = Set(notDuplicates.split(separator: "\n").map(String.init))
        // The owner's "not the same person" is kept by the ids too, so a rename does not bring a pair back.
        let people = controller.library.identity?.people.people ?? []
        return PeopleDuplicates.find(profiles).filter { !dismissed.contains($0.id) && !PeopleDuplicates.isDistinct($0, among: people) }
    }

    private var selected: VoiceProfile? { profiles.first { $0.name == selection } }

    private var matches: [String: ListMatch]? {
        PeopleSearch.matches(search.query, profiles: profiles, people: PeopleSearch.people(controller), org: org)
    }

    private func results(_ matches: [String: ListMatch]?) -> [VoiceProfile] {
        var list = (PeopleSort(rawValue: sort) ?? .recent).order(profiles, stats: stats)
        if needsSample { list = list.filter { $0.isOwner || $0.embeddings.isEmpty } }
        guard let matches else { return list }
        return list.filter { matches[$0.name] != nil }
    }

    var body: some View {
        Group {
            if loaded, profiles.isEmpty {
                DetailColumn { toolbar } content: {
                    EmptyState(symbol: "person.2", title: "No people yet",
                               message: "Mossad learns your voice in your first call. Name the other voices after a call and they show here.")
                        .frame(maxHeight: .infinity)
                }
            } else if mode == .org {
                DetailColumn { toolbar } content: {
                    OrgChartView(org: org, profiles: profiles, stats: stats, query: search.query,
                                 open: { name in mode = .list; select(name) }, importChart: { importing = true })
                }
            } else {
                listAndProfile
            }
        }
        .onReceive(controller.$meetings) { _ in Task { await reload() } }
        .onChange(of: controller.personRequests) { _, _ in Task { await reload() } }
        .onAppear {
            org.reload()
            let env = ProcessInfo.processInfo.environment
            if CommandLine.arguments.contains("--ui-preview") {
                // Development hooks for screenshots: MOSSAD_PEOPLE_MODE=list|org, MOSSAD_ORG_IMPORT opens the import.
                if let m = env["MOSSAD_PEOPLE_MODE"].flatMap(Mode.init) { previewMode = m }
                if env["MOSSAD_ORG_IMPORT"] != nil { importing = true }
                // MOSSAD_PEOPLE_QUERY types into the list's search.
                if let q = env["MOSSAD_PEOPLE_QUERY"] { search.query = q }
            }
        }
        .sheet(item: Binding(get: { editing.map(Wrapped.init) }, set: { editing = $0?.profile })) { item in editSheet(item.profile) }
        .sheet(isPresented: $importing) { OrgImportSheet(org: org, profiles: profiles, stats: stats, owner: controller.ownerName) }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let p = deleting {
                    controller.forgetPersona(named: p.name)
                    edit { try controller.library.delete(p.name) }
                }
                deleting = nil
            }
        } message: {
            Text("Mossad will ask for this voice's name again the next time it hears it.")
        }
        .sheet(isPresented: $reviewingDuplicates) {
            PeopleDuplicatesSheet(pairs: duplicates, stats: stats,
                                  emails: Dictionary(profiles.compactMap { p in p.email.map { (p.name, $0) } }, uniquingKeysWith: { a, _ in a }),
                                  merge: { from, into in
                                      guard let p = profiles.first(where: { $0.name == from }),
                                            let target = profiles.first(where: { $0.name == into }) else { return }
                                      merge(p, into: target)
                                  },
                                  notSame: { pair in
                                      notDuplicates += (notDuplicates.isEmpty ? "" : "\n") + pair.id
                                      controller.markDistinct(pair)
                                  })
        }
        .onChange(of: duplicates.isEmpty) { _, empty in
            if empty { reviewingDuplicates = false }
            // Development hook for screenshots: MOSSAD_DUPLICATES opens the review once the pairs load.
            else if CommandLine.arguments.contains("--ui-preview"), ProcessInfo.processInfo.environment["MOSSAD_DUPLICATES"] != nil {
                reviewingDuplicates = true
            }
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

    private var subtitle: String {
        if mode == .org, let chart = org.chart {
            return "Org chart from \(org.fileName) · \(chart.people.count.formatted()) people"
        }
        let others = profiles.filter { !$0.isOwner }.count
        return others == 1 ? "1 person" : "\(others) people"
    }

    private var listAndProfile: some View {
        let matches = matches, results = results(matches)
        return HStack(spacing: 0) {
            ListColumn("People", widthKey: "people", search: $search, searchPrompt: PeopleSearch.prompt) {
                if !duplicates.isEmpty {
                    DuplicatesBanner(count: duplicates.count) { reviewingDuplicates = true }
                }
                PeopleList(owner: results.filter(\.isOwner), people: results.filter { !$0.isOwner }, stats: stats,
                           selection: $selection, sort: $sort, needsSample: $needsSample, query: search.trimmed, matches: matches ?? [:],
                           rename: startEditing, delete: { deleting = $0 })
            }
            DetailColumn { toolbar } content: {
                VStack(spacing: 0) {
                    Group {
                        if let p = selected {
                            PersonProfileView(profile: p, stats: stats[p.name] ?? PersonStats(),
                                              org: org.match(p.name), chart: org.chart,
                                              others: profiles.filter { $0.name != p.name },
                                              rename: { startEditing(p) }, merge: { merge(p, into: $0) },
                                              delete: { deleting = p }, select: select)
                                .id(p.name)
                        } else {
                            EmptyState(symbol: "person.crop.circle", title: "Select a person",
                                       message: "Their profile shows the coach's read, how much they talk, and who they meet with.")
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    footer
                }
            }
        }
    }

    /// List or org chart, and More. The org chart has no list column, so the row names the chart and holds its search.
    private var toolbar: some View {
        PageToolbar(title: mode == .org ? "People" : nil, subtitle: mode == .org ? subtitle : nil,
                    search: mode == .org ? $search : nil, searchPrompt: "Search the org chart") {
            ToolbarSegmented(selection: Binding(get: { mode }, set: { mode = $0 }), options: [
                .init(value: .list, label: "List", icon: .viewList),
                .init(value: .org, label: "Org chart", icon: .viewOrg),
            ], accessibilityLabel: "View")
            ToolbarCapsule {
                ToolbarMenuButton(icon: .more, label: "More", help: "More for People") {
                    Button("Import org chart…", systemImage: "square.and.arrow.down") { importing = true }
                    if !duplicates.isEmpty {
                        Button("Review possible duplicates…", systemImage: "person.2") { reviewingDuplicates = true }
                    }
                    Divider()
                    Button("Delete all saved voices…", systemImage: "trash", role: .destructive) { confirmDeleteAll = true }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Space.s) {
            IconImage(.lock, size: 12)
            Text("Voice fingerprints are biometric data. They stay on this Mac in the Voices folder and are never uploaded.")
                // Two lines in a narrow window rather than cutting the promise that the voices stay here.
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.m)
            Button("Delete all saved voices…") { confirmDeleteAll = true }
                .buttonStyle(.plain)
                .fontWeight(.medium)
                .foregroundStyle(Palette.recording)
                .fixedSize()
        }
        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
        .padding(.horizontal, 36).padding(.vertical, 6)
        .frame(minHeight: 40)
        .overlay(alignment: .top) { Hairline() }
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
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(icon: .pencil, title: "Edit \(p.name)", subtitle: "Mossad uses the email to match calendar invites.")
            VStack(alignment: .leading, spacing: 10) {
                TextField("Name", text: $newName).textFieldStyle(SheetFieldStyle())
                TextField("Email (optional)", text: $newEmail).textFieldStyle(SheetFieldStyle())
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            SheetFooter {
                Button("Cancel") { editing = nil }.buttonStyle(.sheetSecondary).keyboardShortcut(.cancelAction)
                Button("Save") { save(p) }.buttonStyle(.sheetPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .mossadSheet(width: 400)
    }

    private func save(_ p: VoiceProfile) {
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
        profiles = PeopleSort.recent.order(controller.library.profiles, stats: computed)
        loaded = true
        if let wanted = controller.personToOpen {
            controller.personToOpen = nil
            if profiles.contains(where: { $0.name == wanted }) {
                selection = wanted
                mode = .list
            }
        }
        if selected == nil { selection = profiles.first?.name }
    }

    private func edit(_ change: () throws -> Void) {
        do { try change() } catch { Log.error("Voice library edit failed: \(error)") }
        Task { await reload() }
    }
}

/// "3 possible duplicates · Review": a quiet line at the top of the list that opens the review.
private struct DuplicatesBanner: View {
    let count: Int
    let review: () -> Void

    var body: some View {
        Button(action: review) {
            HStack(spacing: Space.s) {
                Image(systemName: "person.2").foregroundStyle(Palette.accent).accessibilityHidden(true)
                Text("\(count) possible \(count == 1 ? "duplicate" : "duplicates")").fontWeight(.semibold).foregroundStyle(Palette.ink)
                Spacer()
                Text("Review").fontWeight(.semibold).foregroundStyle(Palette.accent)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10).padding(.vertical, Space.s)
            .background(Palette.accentTint, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(EdgeInsets(top: Space.s, leading: 10, bottom: Space.xs, trailing: 14))
    }
}

extension PeopleSort {
    var title: String {
        switch self {
        case .recent: "Most recent"
        case .mostMet: "Most met with"
        case .talkTime: "Most talk time"
        case .newest: "Newest"
        case .firstName: "First name"
        case .lastName: "Last name"
        }
    }
}

/// The list column: "You", then everyone else in the sort's order. The arrow keys move the selection.
private struct PeopleList: View {
    @EnvironmentObject var controller: AppController
    let owner: [VoiceProfile]
    let people: [VoiceProfile]
    let stats: [String: PersonStats]
    @Binding var selection: String?
    @Binding var sort: String
    @Binding var needsSample: Bool
    let query: String
    /// Why each row is in a searched list; empty with no search.
    let matches: [String: ListMatch]
    let rename: (VoiceProfile) -> Void
    let delete: (VoiceProfile) -> Void
    @FocusState private var focused: Bool

    private var order: [String] { (owner + people).map(\.name) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !owner.isEmpty {
                        header(Text("You"))
                        ForEach(owner, id: \.name) { row($0) }
                    }
                    HStack {
                        header(Text(needsSample ? "Needs a voice sample · \(people.count)" : "People · \(people.count)"))
                        Spacer()
                        sortMenu
                    }
                    .padding(.top, owner.isEmpty ? 0 : 4)
                    ForEach(people, id: \.name) { row($0) }
                    if people.isEmpty {
                        Text(!query.isEmpty ? "No one matches “\(query)”." : needsSample ? "Everyone has a voice sample." : "Name voices after a call and they show here.")
                            .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                            .padding(.horizontal, 10).padding(.top, Space.xs)
                    }
                }
                .padding(.leading, 4).padding(.trailing, Space.s).padding(.bottom, Space.m)
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, proxy) }
            .onKeyPress(.upArrow) { move(-1, proxy) }
            // Return or Down Arrow in the search field, or its close, gives the keys back to the list.
            .onChange(of: controller.listFocusRequest) { _, _ in
                focused = true
                if selection.map({ !order.contains($0) }) ?? true, let first = order.first { selection = first }
            }
        }
    }

    private func header(_ text: Text) -> some View {
        text.textRole(.label).foregroundStyle(Palette.tertiary)
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    /// The canvas's quiet "Most recent ⌄" beside the group label, opening the sort choices and the filter.
    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(PeopleSort.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Toggle("Needs a voice sample", isOn: $needsSample)
        } label: {
            HStack(spacing: 4) {
                Text((PeopleSort(rawValue: sort) ?? .recent).title + (needsSample ? " · Needs a sample" : ""))
                IconImage(.chevronDown, size: 9)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(needsSample ? Palette.accent : Palette.secondary)
            .padding(.leading, Space.s).padding(.trailing, 6)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.top, 6)
        .accessibilityLabel("Sort people")
        .accessibilityValue((PeopleSort(rawValue: sort) ?? .recent).title)
    }

    private func row(_ p: VoiceProfile) -> some View {
        PersonRow(profile: p, stats: stats[p.name], selected: selection == p.name, match: matches[p.name]) {
            selection = p.name
            focused = true
        }
        .id(p.name)
        .contextMenu {
            Button("Edit…") { rename(p) }
            if !p.isOwner { Button("Delete…", role: .destructive) { delete(p) } }
        }
    }

    private func move(_ by: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !order.isEmpty else { return .ignored }
        let index = selection.flatMap { order.firstIndex(of: $0) }.map { min(max($0 + by, 0), order.count - 1) } ?? 0
        selection = order[index]
        proxy.scrollTo(order[index])
        return .handled
    }
}

/// The avatar, the name, the email (or the owner's totals), and the meetings and last day on the right.
private struct PersonRow: View {
    let profile: VoiceProfile
    let stats: PersonStats?
    let selected: Bool
    var match: ListMatch?
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                PersonMark(name: profile.name, size: 28, isOwner: profile.isOwner)
                VStack(alignment: .leading, spacing: 2) {
                    Text(match?.title.boldMatches(size: 13) ?? AttributedString(profile.name))
                        .font(.system(size: 13, weight: profile.isOwner || selected ? .semibold : .medium))
                        .foregroundStyle(Palette.ink)
                    if let match, match.context != nil {
                        ListMatchLine(match: match, lines: 1)
                    } else if let sub {
                        Text(sub).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    } else if profile.embeddings.isEmpty {
                        Text("Needs a voice sample").font(.system(size: 12)).foregroundStyle(Palette.accent)
                    }
                }
                .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    if !profile.isOwner { Text(meetingsText(stats?.meetings.count ?? 0)) }
                    if let last = stats?.lastHeard { Text(shortDay(last)) }
                }
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(Palette.secondary)
            }
            .padding(.vertical, Space.s).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.selection : hovering ? Palette.fill.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var sub: String? {
        if profile.isOwner {
            let s = stats ?? PersonStats()
            return "\(meetingsText(s.meetings.count)) · \(talkText(s.totalTalk))"
        }
        return profile.email
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
