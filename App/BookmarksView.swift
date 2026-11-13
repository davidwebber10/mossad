import MossadCore
import SwiftUI

/// Every bookmark of all meetings, under Meetings: grouped by meeting, the newest meeting first, each with its time,
/// its note, and what was said at that moment. Play opens the meeting there.
struct BookmarksView: View {
    @EnvironmentObject var controller: AppController
    @State private var search = ListSearchState()
    private var query: String { search.query }
    @State private var groups: [BookmarkIndex.Group] = []
    /// All bookmarks, also the ones the search hides, for the subtitle and the empty states.
    @State private var total = 0
    @State private var loaded = false

    var body: some View {
        DetailColumn {
            PageToolbar(title: "Bookmarks", subtitle: subtitle, search: total > 0 ? $search : nil, searchPrompt: "Search notes and what was said") {}
        } content: {
            page
        }
        .task(id: "\(controller.meetingsVersion)|\(query)") {
            // Off the main thread: a search reads the lines of each meeting that has a bookmark.
            let records = controller.meetings, q = query
            let (all, shown) = await Task.detached(priority: .userInitiated) {
                let all = BookmarkIndex.groups(records)
                return (BookmarkIndex.count(all), q.trimmingCharacters(in: .whitespaces).isEmpty ? all : BookmarkIndex.groups(records, query: q))
            }.value
            guard !Task.isCancelled else { return }
            total = all
            groups = shown
            loaded = true
        }
        .navigationPart(.bookmarks, .init(search: search.query)) { search.show($0.search) }
    }

    private var subtitle: String? {
        guard total > 0 else { return nil }
        let shown = BookmarkIndex.count(groups)
        let noun = total == 1 ? "bookmark" : "bookmarks"
        return query.trimmingCharacters(in: .whitespaces).isEmpty ? "\(total) \(noun) in \(groups.count) \(groups.count == 1 ? "meeting" : "meetings")"
            : "\(shown) of \(total) \(noun)"
    }

    @ViewBuilder
    private var page: some View {
        if !loaded {
            Color.clear
        } else if total == 0 {
            EmptyState(symbol: "bookmark", title: "No bookmarks yet",
                       message: "During a call, choose Bookmark at the top of the meeting, or press Control-Option-B in any app. Later, choose Add bookmark in a meeting's player. Each bookmark shows here with its time and note.",
                       action: ("Go to Meetings", { controller.open(.meetings) }))
                .pageCentered()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if groups.isEmpty {
                        Text("No bookmark matches “\(query.trimmingCharacters(in: .whitespaces))”.")
                            .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.secondary)
                    }
                    ForEach(Array(groups.enumerated()), id: \.element.id) { i, group in
                        MomentGroupHeading(title: group.title, start: group.start, count: group.bookmarks.count, noun: "bookmark") {
                            controller.openMeeting(group.callID)
                        }
                        .padding(.top, i == 0 ? 0 : 32)
                        ForEach(group.bookmarks) { mark in
                            BookmarkRow(mark: mark, query: query) { controller.openMeeting(mark.callID, at: mark.offset) }
                        }
                    }
                }
                .frame(maxWidth: Detail.listMax, alignment: .leading)
                .padding(.horizontal, Detail.gutter).padding(.top, Detail.bodyTop).padding(.bottom, Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A meeting above its bookmarks or screens: the title, which opens the meeting, then the day and time.
struct MomentGroupHeading: View {
    let title: String
    let start: Date
    let count: Int
    let noun: String
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Button(action: open) {
                Text(title).font(.system(size: Rhythm.headingSize, weight: .semibold)).foregroundStyle(Palette.ink).underline(hovered).lineLimit(1)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help("Open the meeting")
            Text(start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary).lineLimit(1)
            Spacer(minLength: Space.m)
            Text("\(count) \(count == 1 ? noun : noun + "s")").font(.system(size: Rhythm.secondarySize)).monospacedDigit().foregroundStyle(Palette.tertiary)
        }
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One bookmark: play, the time of day and the place in the call, the note, and the line that was said then.
private struct BookmarkRow: View {
    let mark: BookmarkIndex.Entry
    /// The search, whose words show in bold.
    var query = ""
    let play: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Button(action: play) {
                IconImage(.play, size: 12).foregroundStyle(Palette.onAccent)
                    .frame(width: 26, height: 26)
                    .background(Palette.accentFill, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Play from \(clock(mark.offset))")
            .accessibilityLabel("Play from \(clock(mark.offset))")
            VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                HStack(spacing: Space.s) {
                    BookmarkFlag().fill(Palette.accentFill).frame(width: 8, height: 10).accessibilityHidden(true)
                    Text(mark.time.formatted(date: .omitted, time: .shortened)).font(.system(size: Rhythm.bodySize, weight: .medium)).foregroundStyle(Palette.ink)
                    Text("at \(clock(mark.offset))").font(.system(size: Rhythm.secondarySize)).monospacedDigit().foregroundStyle(Palette.tertiary)
                }
                if let note = mark.note {
                    Text(SearchText.marking(note, query: query).boldMatches(size: 13))
                        .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                }
                if let said = mark.said {
                    Text("\(Text(said.speaker + ":").fontWeight(.medium)) “\(Text(SearchText.marking(said.text, query: query).boldMatches(size: 12.5)))”")
                        .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.secondary).lineLimit(2)
                } else if mark.note == nil {
                    Text("No note").font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background(hovered ? Palette.fill.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .padding(.horizontal, -10)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2, perform: play)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Play", play)
    }
}
