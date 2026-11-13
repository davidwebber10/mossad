import AppKit
import MossadCore
import SwiftUI
import UniformTypeIdentifiers

/// The org chart: the owner's part of the tree by default (their manager on top, then a column for the owner and
/// each peer with direct reports stacked beneath), people outside the company apart on the right, and saved
/// people not yet placed under them. Anyone's team opens on demand.
struct OrgChartView: View {
    @EnvironmentObject var controller: AppController
    @ObservedObject var org: OrgState
    let profiles: [VoiceProfile]
    let stats: [String: PersonStats]
    let query: String
    /// Opens a saved person's profile in the list.
    let open: (String) -> Void
    let importChart: () -> Void

    /// The person whose team shows; nil is the owner.
    @State private var focus: String?
    /// Columns showing every report, not only the first few.
    @State private var expanded: Set<String> = []

    /// The canvas's 196 pt cards with their padding came out wider than its own gap allowed; 200 pt cards 16 pt
    /// apart keep four columns and the outside column inside a 1400 pt window.
    static let cardWidth: CGFloat = 200
    static let columnGap: CGFloat = 16
    static let shownReports = 8
    static let shownColumns = 6

    var body: some View {
        if let chart = org.chart {
            VStack(spacing: 0) {
                fileHeader(chart)
                content(chart)
            }
        } else if org.loaded {
            EmptyState(symbol: "flowchart", title: "No org chart yet",
                       message: "Import a CSV from your HR system with Last Name, First Name, Position Title, and Supervisor. It stays on this Mac, and Mossad matches people by name.",
                       action: ("Import org chart…", importChart))
                .overlay(alignment: .bottom) {
                    Button("Download template", action: downloadTemplate).buttonStyle(.plain)
                        .font(.system(size: Rhythm.secondarySize, weight: .medium)).foregroundStyle(Palette.accent)
                        .padding(.bottom, 20)
                }
                .frame(maxHeight: .infinity)
        } else {
            // Never an empty body: the People page loads the chart in its onAppear, and an empty view never
            // appears, so the page stayed blank with no toolbar to switch back to the list.
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Header

    private func fileHeader(_ chart: OrgChart) -> some View {
        HStack(spacing: Space.l) {
            IconImage(.note, size: 16).foregroundStyle(Palette.secondary)
                .frame(width: 32, height: 32)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                (Text(org.fileName).fontWeight(.semibold).foregroundStyle(Palette.ink)
                 + Text(" · \(chart.people.count.formatted()) people, \(chart.levels) \(chart.levels == 1 ? "level" : "levels")\(importedText)")
                    .foregroundStyle(Palette.secondary))
                    .font(.system(size: Rhythm.bodySize)).lineLimit(1)
                (Text("Columns: ") + Text("Last Name, First Name, Position Title, Supervisor").font(.system(size: Rhythm.noteSize, design: .monospaced))
                 + Text(" · people are matched to meetings by name"))
                    .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer(minLength: Space.m)
            Button("Review matches…", action: importChart).buttonStyle(.mossadFill)
            Button("Download template", action: downloadTemplate).buttonStyle(.mossadFill)
        }
        .padding(.horizontal, Detail.gutter).padding(.top, Detail.bodyTop).padding(.bottom, 14)
        .overlay(alignment: .bottom) { Hairline().padding(.horizontal, Detail.gutter) }
    }

    private var importedText: String {
        guard let d = org.imported else { return "" }
        return " · imported " + d.formatted(.dateTime.month(.abbreviated).day())
    }

    private func downloadTemplate() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "org-chart-template.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(OrgChart.templateCSV.utf8).write(to: url, options: .atomic) } catch { Log.error("Saving the org chart template failed: \(error)") }
    }

    // MARK: Content

    /// Saved people by their place in the file, and the rest split into outside and not yet placed.
    private struct Placement {
        var byID: [String: VoiceProfile] = [:]
        var outside: [VoiceProfile] = []
        var unmatched: [VoiceProfile] = []
        var ownerID: String?
    }

    private func placement(_ chart: OrgChart) -> Placement {
        var p = Placement()
        for profile in profiles {
            if let m = org.match(profile.name) {
                if p.byID[m.person.id] == nil { p.byID[m.person.id] = profile }
                if profile.isOwner { p.ownerID = m.person.id }
            } else if org.isOutside(profile.name) {
                p.outside.append(profile)
            } else if !profile.isOwner {
                p.unmatched.append(profile)
            }
        }
        if p.ownerID == nil, let m = org.match(controller.ownerName) { p.ownerID = m.person.id }
        return p
    }

    /// The owner, or the top of the file when the owner is not in it.
    private func home(_ chart: OrgChart, _ place: Placement) -> String? {
        place.ownerID ?? chart.people.filter { $0.managerID == nil }.max { chart.reports(of: $0.id).count < chart.reports(of: $1.id).count }?.id
    }

    /// A search moves the chart once to the first match: a saved person by name or email first, then anyone in
    /// the file by name or title. The chart stays free to move after that.
    private func search(_ chart: OrgChart) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        let saved = profiles.lazy.filter { $0.name.localizedCaseInsensitiveContains(q) || ($0.email?.localizedCaseInsensitiveContains(q) ?? false) }
            .compactMap { org.match($0.name)?.person.id }.first
        let found = saved
            ?? chart.people.first { $0.fullName.localizedCaseInsensitiveContains(q) }?.id
            ?? chart.people.first { $0.title.localizedCaseInsensitiveContains(q) }?.id
        if let found, found != focus { show(found) }
    }

    private func content(_ chart: OrgChart) -> some View {
        let place = placement(chart)
        let center = focus ?? home(chart, place)
        return ScrollView([.vertical, .horizontal]) {
            // The outside column starts level with the first row of columns, as the canvas places it.
            HStack(alignment: .orgRow, spacing: Space.xl) {
                if let center {
                    tree(chart.team(around: center), chart: chart, place: place, home: home(chart, place))
                }
                if !place.outside.isEmpty || !place.unmatched.isEmpty {
                    sideColumn(place)
                }
            }
            .padding(.horizontal, Detail.gutter).padding(.top, Space.xl).padding(.bottom, Space.xxl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: query) { _, _ in search(chart) }
        .onAppear { search(chart) }
    }

    private func tree(_ team: OrgChart.Team, chart: OrgChart, place: Placement, home: String?) -> some View {
        // A manager with dozens of reports would build dozens of columns; the rest wait behind "N more".
        let allPeers = expanded.contains("peers:" + team.focus)
        let columns = allPeers ? team.columns : Array(team.columns.prefix(Self.shownColumns))
        let hidden = team.columns.count - columns.count
        let width = CGFloat(max(columns.count, 1)) * Self.cardWidth + CGFloat(max(columns.count - 1, 0)) * Self.columnGap
        let showsNav = !(team.focus == home && team.top.flatMap({ chart.manager(of: $0.id) }) == nil && hidden == 0 && !allPeers)
        return VStack(spacing: 0) {
            if showsNav {
                // Laid over the tree's own width, so a narrow team does not shift its top card.
                Color.clear.frame(width: width, height: 26)
                    .overlay(alignment: .leading) {
                        HStack(spacing: Space.s) {
                            if let top = team.top, let up = chart.manager(of: top.id) {
                                Button { show(up.id) } label: { Label { Text("Up a level") } icon: { IconImage(.arrowUp, size: 13) } }
                                    .buttonStyle(.mossadFill)
                                    .help("Show \(up.fullName)'s team")
                            }
                            if hidden > 0 || allPeers && team.columns.count > Self.shownColumns {
                                Button(hidden > 0 ? "\(hidden) more on this level" : "Show fewer") {
                                    withAnimation(.smooth) {
                                        if allPeers { expanded.remove("peers:" + team.focus) } else { expanded.insert("peers:" + team.focus) }
                                    }
                                }
                                .buttonStyle(.mossadFill)
                            }
                            if let home, team.focus != home {
                                Button { show(nil) } label: { Label(place.ownerID == nil ? "Back to the top" : "Back to you", systemImage: "arrow.uturn.backward") }
                                    .buttonStyle(.mossadFill)
                            }
                        }
                        .fixedSize()
                    }
                    .padding(.bottom, Space.l)
            }
            if let top = team.top {
                card(top, chart: chart, place: place)
            }
            if !columns.isEmpty {
                Connector(columns: columns.count, cardWidth: Self.cardWidth, gap: Self.columnGap)
                    .stroke(Palette.ring, style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
                    .frame(width: width, height: 26)
                    .accessibilityHidden(true)
                HStack(alignment: .top, spacing: Self.columnGap) {
                    ForEach(columns, id: \.head.id) { column in
                        columnView(column, chart: chart, place: place)
                    }
                }
                .alignmentGuide(.orgRow) { $0[.top] }
            }
        }
        .fixedSize()
    }

    private func columnView(_ column: OrgChart.Team.Column, chart: OrgChart, place: Placement) -> some View {
        let open = expanded.contains(column.head.id)
        let shown = open ? column.reports : Array(column.reports.prefix(Self.shownReports))
        return VStack(spacing: Space.m) {
            card(column.head, chart: chart, place: place)
            if !column.reports.isEmpty {
                VStack(spacing: Space.m) {
                    ForEach(shown, id: \.id) { card($0, chart: chart, place: place) }
                    if column.reports.count > Self.shownReports {
                        Button(open ? "Show fewer" : "\(column.reports.count - Self.shownReports) more") {
                            withAnimation(.smooth) {
                                if open { expanded.remove(column.head.id) } else { expanded.insert(column.head.id) }
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: Rhythm.secondarySize, weight: .medium)).foregroundStyle(Palette.accent)
                        .padding(.vertical, 2)
                        .background(Palette.window)
                    }
                }
                .padding(.top, 4)
                // The line from the head down its reports shows in the gaps between the cards.
                .background(alignment: .top) {
                    Rectangle().fill(Palette.ring).frame(width: 1.25).padding(.top, -16).padding(.bottom, 28)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: Self.cardWidth)
    }

    private func card(_ person: OrgChart.Person, chart: OrgChart, place: Placement) -> some View {
        let saved = place.byID[person.id]
        let count = saved.map { stats[$0.name]?.meetings.count ?? 0 }
        let hasTeam = !chart.reports(of: person.id).isEmpty
        return OrgCard(name: saved?.name ?? person.fullName, title: person.title,
                       meta: count.map(meetingsText) ?? "not met", metaColor: Palette.tertiary,
                       isOwner: saved?.isOwner == true, hollow: saved == nil) {
            if let saved { open(saved.name) } else { show(person.id) }
        }
        .contextMenu {
            if let saved { Button("Open \(saved.name)") { open(saved.name) } }
            if hasTeam || chart.manager(of: person.id) != nil {
                Button("Show \(person.first)'s team") { show(person.id) }
            }
        }
        .accessibilityAction(named: "Show team") { show(person.id) }
        .help(saved == nil ? "Show \(person.fullName)'s team" : "Open \(saved!.name)")
    }

    private func show(_ id: String?) {
        withAnimation(.smooth) {
            focus = id
            expanded = []
        }
    }

    // MARK: Outside the company

    private func sideColumn(_ place: Placement) -> some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            if !place.outside.isEmpty {
                group("Outside the company · \(place.outside.count)") {
                    ForEach(place.outside, id: \.name) { p in
                        OrgCard(name: p.name, title: CompanyName.from(email: p.email) ?? "Outside",
                                meta: meetingsText(stats[p.name]?.meetings.count ?? 0), metaColor: Palette.tertiary,
                                isOwner: false, hollow: false) { open(p.name) }
                    }
                }
            }
            if !place.unmatched.isEmpty {
                group("Not placed · \(place.unmatched.count)") {
                    ForEach(place.unmatched, id: \.name) { p in
                        OrgCard(name: p.name, title: meetingsText(stats[p.name]?.meetings.count ?? 0),
                                meta: "Match", metaColor: Palette.accent, isOwner: false, hollow: true, action: importChart)
                            .help("Find \(p.name) in the org chart, or mark them outside the company")
                    }
                }
            }
        }
        .frame(width: Self.cardWidth, alignment: .leading)
        .padding(.leading, 20)
        .overlay(alignment: .leading) { Hairline(axis: .vertical) }
        .alignmentGuide(.orgRow) { $0[.top] }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).textRole(.label).foregroundStyle(Palette.tertiary)
                .padding(.bottom, Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Hairline() }
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

/// A person on the chart: their mark, name, title, and how often you meet. White on the paper in light mode; an
/// opaque raised tone in dark mode, so the connecting lines never show through.
private struct OrgCard: View {
    let name: String
    let title: String
    let meta: String
    let metaColor: Color
    let isOwner: Bool
    let hollow: Bool
    let action: () -> Void
    @State private var hovering = false

    static let surface = Color(light: 0xFFFFFF, dark: 0x2A2927)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            HStack(spacing: Space.m) {
                PersonMark(name: name, size: 32, isOwner: isOwner, hollow: hollow)
                VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                    HStack(spacing: Space.s) {
                        Text(name).font(.system(size: Rhythm.bodySize, weight: .semibold))
                            .foregroundStyle(hollow ? Palette.secondary : Palette.ink)
                        if isOwner {
                            Text("You").font(.system(size: Rhythm.noteSize, weight: .semibold)).foregroundStyle(Palette.secondary)
                                .padding(.horizontal, 6).frame(height: 16)
                                .background(Palette.fill, in: Capsule())
                        }
                    }
                    (Text(title.isEmpty ? "" : "\(title) ") + Text("· \(meta)").foregroundStyle(metaColor))
                        .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary)
                }
                .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10).padding(.trailing, 12)
            .frame(width: OrgChartView.cardWidth, height: 56, alignment: .leading)
            .background(hovering ? Palette.fill : .clear, in: shape)
            .background(Self.surface, in: shape)
            .overlay {
                shape.strokeBorder(isOwner ? Palette.ink : Palette.hairline, lineWidth: isOwner ? 1.5 : 1)
            }
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name)\(isOwner ? ", you" : ""), \(title), \(meta)")
    }
}

/// From the top card down to each column: a short stem, then a bracket with rounded corners into every column.
private struct Connector: Shape {
    let columns: Int
    let cardWidth: CGFloat
    let gap: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midX, bar = rect.height / 2, r: CGFloat = 8
        let centers = (0..<columns).map { CGFloat($0) * (cardWidth + gap) + cardWidth / 2 }
        path.move(to: CGPoint(x: mid, y: 0))
        path.addLine(to: CGPoint(x: mid, y: bar))
        for x in centers {
            if abs(x - mid) < 1 {
                path.move(to: CGPoint(x: mid, y: 0))
                path.addLine(to: CGPoint(x: x, y: rect.height))
                continue
            }
            let d: CGFloat = x > mid ? 1 : -1
            let radius = min(r, abs(x - mid) / 2)
            path.move(to: CGPoint(x: mid, y: bar))
            path.addLine(to: CGPoint(x: x - d * radius, y: bar))
            path.addQuadCurve(to: CGPoint(x: x, y: bar + radius), control: CGPoint(x: x, y: bar))
            path.addLine(to: CGPoint(x: x, y: rect.height))
        }
        return path
    }
}

private extension VerticalAlignment {
    /// The top of the chart's first row of columns.
    enum OrgRow: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[.top] }
    }
    static let orgRow = VerticalAlignment(OrgRow.self)
}
