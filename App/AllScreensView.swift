import MossadCore
import SwiftUI

/// Every kept shared screen of all meetings, under Meetings: a grid for each meeting, the newest meeting first,
/// searchable by the text read from the screens. A click opens the meeting's Screens tab on that frame. The small
/// pictures decode off the main thread when they come into view (`FrameThumbnail`).
struct AllScreensView: View {
    @EnvironmentObject var controller: AppController
    @State private var search = ListSearchState()
    private var query: String { search.query }
    @State private var groups: [ScreenIndex.Group] = []
    @State private var total = 0
    @State private var loaded = false

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        DetailColumn {
            PageToolbar(title: "Screens", subtitle: subtitle, search: total > 0 ? $search : nil, searchPrompt: "Search text on screens") {}
        } content: {
            page
        }
        .task(id: "\(controller.meetingsVersion)|\(query)") {
            let records = controller.meetings, q = query
            let (all, shown) = await Task.detached(priority: .userInitiated) {
                let all = ScreenIndex.groups(records)
                return (ScreenIndex.count(all), q.trimmingCharacters(in: .whitespaces).isEmpty ? all : ScreenIndex.groups(records, query: q))
            }.value
            guard !Task.isCancelled else { return }
            total = all
            groups = shown
            loaded = true
        }
        .navigationPart(.screens, .init(search: search.query)) { search.show($0.search) }
    }

    private var subtitle: String? {
        guard total > 0 else { return nil }
        let noun = total == 1 ? "screen" : "screens"
        return trimmed.isEmpty ? "\(total) \(noun) in \(groups.count) \(groups.count == 1 ? "meeting" : "meetings")"
            : "\(ScreenIndex.count(groups)) of \(total) \(noun)"
    }

    @ViewBuilder
    private var page: some View {
        if !loaded {
            Color.clear
        } else if total == 0 {
            empty.pageCentered()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if groups.isEmpty {
                        Text("No screen has that text.").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    }
                    ForEach(Array(groups.enumerated()), id: \.element.id) { i, group in
                        MomentGroupHeading(title: group.title, start: group.start, count: group.screens.count, noun: "screen") {
                            controller.openMeeting(group.callID)
                        }
                        .padding(.top, i == 0 ? 0 : 32)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: Space.m)], alignment: .leading, spacing: Space.m) {
                            ForEach(group.screens) { screen in
                                AllScreensTile(url: frameURL(group.callID, screen),
                                               time: (group.times[screen.file] ?? group.start).formatted(date: .omitted, time: .shortened),
                                               text: screen.text, query: trimmed) {
                                    controller.openScreen(group.callID, file: screen.file)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: Detail.listMax, alignment: .leading)
                .padding(.horizontal, Detail.gutter).padding(.top, Detail.bodyTop).padding(.bottom, Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Off by default, so the usual reason for no screens is the setting; with it on, the reason is that no call
    /// had a shared screen yet.
    @ViewBuilder
    private var empty: some View {
        if controller.captureScreens {
            EmptyState(symbol: "rectangle.on.rectangle", title: "No shared screens yet",
                       message: "Screen capture is on. When someone shares a screen in a call, Mossad keeps a frame each time the picture changes, and reads its text on this Mac. The frames show here.")
        } else {
            EmptyState(symbol: "rectangle.on.rectangle", title: "Screen capture is off",
                       message: "Mossad can keep frames of the screens shared in your calls and read their text on this Mac, so you can search them. It is off by default. Turn it on in Settings > Recording.",
                       action: ("Open Recording Settings", openRecordingSettings))
        }
    }

    private func openRecordingSettings() {
        UserDefaults.standard.set(SettingsPage.recording.rawValue, forKey: "settingsPage")
        controller.open(.settings)
    }

    private func frameURL(_ callID: String, _ screen: SharedScreen) -> URL {
        FrameIndex.folder(in: controller.paths.callDirectory(callID)).appendingPathComponent(screen.file)
    }
}

/// A frame in the grid: the picture, its time, and the first words read from it.
private struct AllScreensTile: View {
    let url: URL
    let time: String
    let text: String
    /// The search: its words show in bold in the line under the frame.
    let query: String
    let open: () -> Void
    private var matches: Bool { !query.isEmpty }

    private var line: AttributedString {
        guard matches else { return AttributedString(ScreenText.excerpt(text)) }
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return SearchText.marking(flat, query: query).excerpt(length: 48).boldMatches(size: 11.5)
    }
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 5) {
                FrameThumbnail(url: url)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                            .strokeBorder(matches ? Palette.accentFill : Palette.hairline, lineWidth: matches ? 1.5 : 1)
                    }
                    .opacity(hovered ? 0.88 : 1)
                Text(time).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Palette.tertiary)
                Text(line).font(.system(size: 11.5)).foregroundStyle(Palette.secondary).lineLimit(matches ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Open in the meeting")
        .accessibilityLabel("Screen at \(time): \(ScreenText.excerpt(text).prefix(80))")
    }
}
