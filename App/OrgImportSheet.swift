import MossadCore
import SwiftUI
import UniformTypeIdentifiers

/// Imports the org chart and reviews the matches: Mossad places saved people by name and nickname, then asks
/// only about the ones it could not place. Each gets a search of the file, or "Outside the company".
struct OrgImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var org: OrgState
    let profiles: [VoiceProfile]
    let stats: [String: PersonStats]
    let owner: String

    @State private var choosing = false
    @State private var error: String?
    /// Rows the owner asked to change, which show the search again.
    @State private var changing: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(symbol: "flowchart", title: "Org chart",
                        subtitle: org.chart == nil
                            ? "A CSV export with Last Name, First Name, Position Title, and Supervisor. It stays on this Mac."
                            : "\(org.fileName) · imported \(org.imported.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "today")")
            ScrollView {
                if let chart = org.chart {
                    review(chart)
                } else {
                    chooseFirst
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: 200, maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
            SheetFooter {
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Palette.recording) }
            } trailing: {
                Button("Done") { dismiss() }.buttonStyle(.sheetPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .mossadSheet(width: 760)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            switch result {
            case .success(let url):
                do {
                    try org.importFile(url)
                    error = nil
                } catch OrgChart.ParseError.missingColumns {
                    error = "That file needs the columns Last Name, First Name, Position Title, and Supervisor."
                } catch {
                    self.error = "Mossad could not read that file."
                    Log.error("Org chart import failed: \(error)")
                }
            case .failure: break
            }
        }
        .onAppear { if org.chart == nil, org.loaded, !CommandLine.arguments.contains("--ui-preview") { choosing = true } }
    }

    private var chooseFirst: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Export the people list from your HR system (Paylocity calls it an employee roster) as CSV, then choose it here. Mossad copies it to the People folder and matches it to the people it knows by name.")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose file…") { choosing = true }.buttonStyle(.mossadFill)
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Review

    private enum MatchState { case exact, nickname, manual, outside, none }

    private func state(_ name: String) -> MatchState {
        if org.isOutside(name) { return .outside }
        guard let m = org.match(name) else { return .none }
        switch m.how {
        case .exact: return .exact
        case .nickname: return .nickname
        case .manual: return .manual
        }
    }

    private func review(_ chart: OrgChart) -> some View {
        let people = profiles.filter { !$0.name.hasPrefix("Speaker ") }
        let placed = people.filter { org.match($0.name) != nil }.count
        // Not matched first, then the guesses to check, then the owner's own choices; exact matches need nothing.
        let order: [MatchState] = [.none, .nickname, .manual, .outside]
        let rows = people.filter { state($0.name) != .exact }
            .sorted { (order.firstIndex(of: state($0.name)) ?? 0, $0.name) < (order.firstIndex(of: state($1.name)) ?? 0, $1.name) }
        let unmatched = people.filter { state($0.name) == .none }.count
        let managers = Set(chart.people.compactMap(\.managerID)).count
        let tops = chart.people.filter { $0.managerID == nil }.count
        return LabelColumnStack(spacing: Space.l) {
            LabelColumn(label: "File") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: Space.m) {
                        Text("Last Name, First Name, Position Title, Supervisor").font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Palette.ink)
                        Button("Replace CSV…") { choosing = true }.buttonStyle(.mossadFill)
                    }
                    Text("\(chart.people.count.formatted()) people · \(managers) \(managers == 1 ? "manager" : "managers") · \(tops) at the top. The supervisor is written “Last, First”. The file has no emails, so Mossad matches by name.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LabelColumn(label: "Matched") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(placed) of your \(people.count) saved people are in the org chart.")
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.ink)
                    Text("Full names first, then common nicknames: Ben for Benjamin, Zach for Zachary, Jim for James.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
            }
            if !rows.isEmpty {
                LabelColumn(label: "Check these", note: unmatched > 0 ? "\(unmatched) not matched" : nil) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows, id: \.name) { p in
                            MatchRow(org: org, chart: chart, profile: p, isOwner: p.isOwner || p.name == owner,
                                     state: state(p.name), changing: changing.contains(p.name)) { on in
                                if on { changing.insert(p.name) } else { changing.remove(p.name) }
                            }
                            .hairline()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
    }

    /// One saved person: how Mossad placed them and Change, or a search of the file and Outside the company.
    private struct MatchRow: View {
        @ObservedObject var org: OrgState
        let chart: OrgChart
        let profile: VoiceProfile
        let isOwner: Bool
        let state: MatchState
        let changing: Bool
        let setChanging: (Bool) -> Void
        @State private var search = ""
        @FocusState private var focused: Bool

        private var hits: [OrgChart.Person] {
            let words = search.split(separator: " ").map(String.init)
            guard !words.isEmpty else { return [] }
            return Array(chart.people.lazy.filter { p in
                words.allSatisfy { p.fullName.localizedCaseInsensitiveContains($0) || p.title.localizedCaseInsensitiveContains($0) }
            }.prefix(6))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Space.m) {
                    PersonMark(name: profile.name, size: 26, isOwner: isOwner)
                    Text(profile.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        if state == .none || changing { picker } else { placed }
                    }
                    .fixedSize()
                }
                if (state == .none || changing), !hits.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(hits, id: \.id) { hit in
                            Button {
                                org.setMatch(profile.name, to: hit.id)
                                search = ""
                                setChanging(false)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(hit.fullName).foregroundStyle(Palette.ink)
                                    Text(hit.title).foregroundStyle(Palette.secondary)
                                    if let m = chart.manager(of: hit.id) {
                                        Text("· reports to \(m.fullName)").foregroundStyle(Palette.tertiary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .lineLimit(1)
                                .font(.system(size: 12.5))
                                .padding(.vertical, 5).padding(.horizontal, Space.s)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Match \(profile.name) to \(hit.fullName), \(hit.title)")
                        }
                    }
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.leading, 38)
                }
            }
            .padding(.vertical, 10)
        }

        private var picker: some View {
            HStack(spacing: Space.s) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                        .accessibilityHidden(true)
                    TextField("Find in \(org.fileName)", text: $search)
                        .textFieldStyle(.plain).font(.system(size: 12.5))
                        .focused($focused)
                        .onSubmit {
                            if let first = hits.first {
                                org.setMatch(profile.name, to: first.id)
                                search = ""
                                setChanging(false)
                            }
                        }
                        .accessibilityLabel("Find \(profile.name) in the org chart")
                }
                .padding(.horizontal, 10)
                .frame(width: 200, height: 28)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button("Outside the company") {
                    org.setMatch(profile.name, to: nil)
                    search = ""
                    setChanging(false)
                }
                .buttonStyle(.mossadFill)
                if changing {
                    Button("Cancel") { search = ""; setChanging(false) }
                        .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                }
            }
            .onAppear { if changing { focused = true } }
        }

        private var placed: some View {
            HStack(spacing: Space.s) {
                if state == .nickname { Text("Matched by nickname").font(.system(size: 12)).foregroundStyle(Palette.secondary) }
                if state == .outside {
                    TagChip(text: "Outside the company")
                } else if let m = org.match(profile.name) {
                    TagChip(text: m.person.title.isEmpty ? m.person.fullName : "\(m.person.fullName) · \(m.person.title)")
                }
                Button("Change") { setChanging(true) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.accent)
                    .padding(.horizontal, 4)
                    .accessibilityLabel("Change the match for \(profile.name)")
            }
        }
    }
}
