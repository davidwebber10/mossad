import MossadCore
import SwiftUI

/// Where Search goes: a meeting, a meeting at a moment in its transcript, or a person's profile.
private enum SearchRoute: Hashable {
    case meeting(String)
    case moment(String, TimeInterval)
    case person(String)
}

/// The Search tab: one field at the bottom over meetings, people, transcript moments, decisions and action items,
/// tasks, and chats, in the engine's groups. Before typing it offers recent searches, people, and tags.
struct SearchScreen: View {
    @EnvironmentObject var store: PhoneStore
    @Binding var query: String
    @State private var results = SearchResults.empty
    /// Meetings whose "N more in this meeting" was opened, with all their moments.
    @State private var expanded: [String: [MomentHit]] = [:]
    @State private var path: [SearchRoute] = []
    @State private var hooked = false

    private var typed: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if typed { found } else { suggestions }
            }
            .listStyle(.plain)
            .overlay {
                if typed, store.searchVersion > 0, results.isEmpty, results.query == query {
                    ContentUnavailableView.search(text: query)
                }
            }
            .phonePage()
            .navigationTitle("Search")
            .task(id: "\(store.searchVersion)|\(query)") { await search() }
            .navigationDestination(for: SearchRoute.self) { route in
                switch route {
                case .meeting(let id): if let r = store.meeting(id) { MeetingView(record: r, find: query) }
                case .moment(let id, let at): if let r = store.meeting(id) { MeetingView(record: r, at: at) }
                case .person(let name): PersonView(name: name, stats: store.personStats[name] ?? PersonStats())
                }
            }
            // A profile lists its meetings by id.
            .navigationDestination(for: String.self) { id in
                if let r = store.meeting(id) { MeetingView(record: r) }
            }
        }
    }

    @concurrent
    nonisolated private static func run(_ text: String, on index: SearchIndex) async -> SearchResults { index.search(text) }

    /// Runs off the main thread on a copy of the index; a newer keystroke cancels it.
    private func search() async {
        let q = query
        guard typed else {
            results = .empty
            return
        }
        let index = store.searchIndex
        // Not detached, so a newer keystroke's cancel reaches the search and it stops early.
        let found = await Self.run(q, on: index)
        guard !Task.isCancelled else { return }
        if found.query != results.query { expanded = [:] }
        results = found
        // Development hook for screenshots: `MOSSAD_SEARCH_OPEN=moment` opens the first moment found.
        if PhoneStore.hook("MOSSAD_SEARCH_OPEN") == "moment", !hooked, let m = found.allMoments.first {
            hooked = true
            open(.moment(m.callID, m.time))
        }
    }

    // MARK: Results

    @ViewBuilder
    private var found: some View {
        ForEach(results.sections) { section in
            Section {
                if section.group == .moments {
                    ForEach(results.moments.filter { !$0.moments.isEmpty }) { momentGroup($0) }
                } else {
                    ForEach(section.hits) { row(for: $0) }
                }
            } header: {
                SearchHeader(title: section.group.title)
            }
        }
    }

    @ViewBuilder
    private func row(for hit: SearchHit) -> some View {
        switch hit {
        case .meeting(let m):
            resultButton { open(.meeting(m.callID)) } label: { MeetingHitRow(hit: m) }
        case .person(let p):
            resultButton { open(.person(p.name.text)) } label: { PersonHitRow(hit: p, isOwner: p.isOwner || p.name.text == store.owner) }
        case .moment(let m):
            resultButton { open(.moment(m.callID, m.time)) } label: { MomentHitRow(hit: m, showMeeting: true) }
        case .outcome(let o):
            resultButton {
                open(o.time.map { .moment(o.callID, $0) } ?? .meeting(o.callID))
            } label: { OutcomeHitRow(hit: o) }
        case .task(let t):
            resultButton { store.remember(search: query); store.openTask(t.commitmentID) } label: { TaskHitRow(hit: t) }
        case .chat(let c):
            resultButton { store.remember(search: query); store.openChat(c.chatID) } label: { ChatHitRow(hit: c) }
        }
    }

    /// One meeting's moments: its title, up to three turns, and "N more in this meeting" to show the rest.
    @ViewBuilder
    private func momentGroup(_ group: MomentGroup) -> some View {
        let all = expanded[group.callID]
        resultButton { open(.meeting(group.callID)) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title).textRole(.headline).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                Text(group.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .textRole(.secondary).foregroundStyle(Palette.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the meeting")
        }
        .listRowSeparator(.hidden, edges: .bottom)
        ForEach(all ?? group.moments) { m in
            resultButton(insets: EdgeInsets(top: 6, leading: Space.l + Space.m, bottom: 6, trailing: Space.l)) {
                open(.moment(m.callID, m.time))
            } label: { MomentHitRow(hit: m, showMeeting: false) }
                .listRowSeparator(.hidden)
        }
        if all == nil, group.moreCount > 0 {
            Button {
                withAnimation(.snappy) { expanded[group.callID] = store.searchIndex.moments(in: group.callID, matching: results.query) }
            } label: {
                Text("\(group.moreCount) more in this meeting")
                    .textRole(.secondary)
                    .fontWeight(.medium)
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 4, leading: Space.l + Space.m, bottom: 10, trailing: Space.l))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden, edges: .top)
            .accessibilityHint("Shows every match in \(group.title)")
        }
    }

    private func resultButton(insets: EdgeInsets = EdgeInsets(top: 10, leading: Space.l, bottom: 10, trailing: Space.l),
                              _ action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button(action: action) { label().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowInsets(insets)
    }

    private func open(_ route: SearchRoute) {
        store.remember(search: query)
        path.append(route)
    }

    // MARK: Before typing

    @ViewBuilder
    private var suggestions: some View {
        if !store.recentSearches.isEmpty {
            Section {
                ForEach(store.recentSearches, id: \.self) { recent in
                    resultButton { query = recent } label: {
                        Label { Text(recent).textRole(.body).foregroundStyle(Palette.ink) } icon: {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Palette.secondary)
                        }
                    }
                    .accessibilityHint("Searches again")
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    SearchHeader(title: "Recent")
                    Button("Clear") { withAnimation { store.clearRecentSearches() } }
                        .textRole(.secondary)
                        .foregroundStyle(Palette.accent)
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear recent searches")
                }
            }
        }
        let people = store.searchSuggestions.people.map(\.name.text)
        if !people.isEmpty {
            Section {
                FlowChips(items: people) { query = $0 }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: Space.l, bottom: 12, trailing: Space.l))
            } header: {
                SearchHeader(title: "People")
            }
        }
        let tags = store.searchSuggestions.tags
        if !tags.isEmpty {
            Section {
                FlowChips(items: tags.map { "#\($0)" }) { query = $0 }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: Space.l, bottom: 12, trailing: Space.l))
            } header: {
                SearchHeader(title: "Tags")
            }
        }
    }
}

/// A group's name in caps over its results.
private struct SearchHeader: View {
    let title: String

    var body: some View {
        PhoneLabel(title)
            .padding(.top, Space.s)
    }
}

// MARK: Rows

/// "Nov 6 · 4:30 PM"
private func when(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day()) + " · " + date.formatted(date: .omitted, time: .shortened)
}

private struct MeetingHitRow: View {
    let hit: MeetingHit

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            PlatformDot(platform: hit.platform).padding(.top, 6).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title.attributed).textRole(.headline).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                Text("\(when(hit.start)) · \(hit.platform.shortName)").textRole(.secondary).foregroundStyle(Palette.secondary)
                if let context = hit.context {
                    Text(context.attributed).textRole(.secondary).foregroundStyle(Palette.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(shortLength(hit.end.timeIntervalSince(hit.start))).textRole(.secondary).foregroundStyle(Palette.secondary).fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the meeting")
    }
}

private struct PersonHitRow: View {
    let hit: PersonHit
    let isOwner: Bool

    var body: some View {
        HStack(spacing: Space.m) {
            PersonMark(name: hit.name.text, size: 32, isOwner: isOwner)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.name.attributed).textRole(.headline).foregroundStyle(Palette.ink)
                Text(detail).textRole(.secondary).foregroundStyle(Palette.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens their profile")
    }

    private var detail: String {
        var parts = ["\(hit.meetings) \(hit.meetings == 1 ? "meeting" : "meetings")"]
        if let last = hit.lastMet { parts.append("last \(shortDay(last))") }
        if isOwner { parts.insert("You", at: 0) }
        return parts.joined(separator: " · ")
    }
}

private struct MomentHitRow: View {
    let hit: MomentHit
    let showMeeting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showMeeting {
                Text(hit.meetingTitle).textRole(.headline).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
            }
            HStack(spacing: 6) {
                Text(hit.speaker).fontWeight(.medium).foregroundStyle(Palette.ink)
                Text(clock(hit.time)).monospacedDigit().foregroundStyle(Palette.accent)
                if showMeeting { Text(shortDay(hit.meetingStart)).foregroundStyle(Palette.secondary) }
            }
            .textRole(.secondary)
            Text(hit.snippet.attributed).textRole(.body).foregroundStyle(Palette.secondary).multilineTextAlignment(.leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the transcript at \(clock(hit.time))")
    }
}

private struct OutcomeHitRow: View {
    let hit: OutcomeHit

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: hit.kind == .decision ? "checkmark.seal" : "checklist")
                .foregroundStyle(Palette.accent)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.text.attributed).textRole(.body).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                Text("\(hit.kind == .decision ? "Decision" : "Action item") · \(hit.meetingTitle) · \(shortDay(hit.meetingStart))")
                    .textRole(.secondary).foregroundStyle(Palette.secondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TaskHitRow: View {
    let hit: TaskHit

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: hit.isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(hit.isDone ? Palette.ok : Palette.secondary)
                .frame(width: 20)
                .accessibilityLabel(hit.isDone ? "Done" : "Open")
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.text.attributed).textRole(.body).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                if !detail.isEmpty { Text(detail).textRole(.secondary).foregroundStyle(Palette.secondary).lineLimit(2) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the task in Tasks")
    }

    private var detail: String {
        var parts: [String] = []
        if let to = hit.to { parts.append("To \(to)") }
        if let due = hit.due { parts.append("Due \(shortDay(due))") }
        if let title = hit.callTitle { parts.append(title) }
        return parts.joined(separator: " · ")
    }
}

private struct ChatHitRow: View {
    let hit: ChatHit

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image("tab-sparkle")
                .resizable()
                .frame(width: 18, height: 18)
                .foregroundStyle(Palette.accent)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title.attributed).textRole(.headline).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                if let snippet = hit.snippet {
                    Text(snippet.attributed).textRole(.secondary).foregroundStyle(Palette.secondary).lineLimit(3)
                }
                Text(shortDay(hit.updated)).textRole(.secondary).foregroundStyle(Palette.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the chat")
    }
}

/// Quiet chips that wrap: tags to search for, follow-up questions.
struct FlowChips: View {
    let items: [String]
    let pick: (String) -> Void

    var body: some View {
        FlowLayout(spacing: Space.s) {
            ForEach(items, id: \.self) { item in
                Button { pick(item) } label: {
                    Text(item)
                        .textRole(.secondary)
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Palette.fill, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Lays children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            row = max(row, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

