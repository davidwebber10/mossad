import AppKit
import MossadCore
import SwiftUI

/// Opens the Screens tab at one frame, from the transcript and from the player's ruler.
private struct OpenScreenKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (SharedScreen) -> Void)? = nil
}

extension EnvironmentValues {
    var openScreen: (@MainActor @Sendable (SharedScreen) -> Void)? {
        get { self[OpenScreenKey.self] }
        set { self[OpenScreenKey.self] = newValue }
    }
}

/// Small copies of the frames, decoded off the main thread at the size a view needs and kept in memory. The grid
/// never decodes a frame at full size.
@MainActor
final class FrameThumbnails {
    static let shared = FrameThumbnails()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 600
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func cached(_ url: URL, longEdge: Int) -> NSImage? {
        cache.object(forKey: "\(url.path)#\(longEdge)" as NSString)
    }

    func image(_ url: URL, longEdge: Int) async -> NSImage? {
        if let hit = cached(url, longEdge: longEdge) { return hit }
        let decoded = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let image = FrameImage.thumbnail(at: url, longEdge: longEdge) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }.value
        if let decoded {
            cache.setObject(decoded, forKey: "\(url.path)#\(longEdge)" as NSString, cost: Int(decoded.size.width * decoded.size.height) * 4)
        }
        return decoded
    }
}

/// One frame at a small size, loaded when it comes into view.
struct FrameThumbnail: View {
    let url: URL
    var longEdge = 480
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Palette.fill
            if let image {
                Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: contentMode)
            }
        }
        .task(id: url) {
            image = FrameThumbnails.shared.cached(url, longEdge: longEdge)
            if image == nil { image = await FrameThumbnails.shared.image(url, longEdge: longEdge) }
        }
        .accessibilityHidden(true)
    }
}

extension CallRecord {
    var hasScreens: Bool { !(screens ?? []).isEmpty }

    /// The time of day at a second of the recording, as the page shows it.
    func timeOfDay(_ offset: TimeInterval) -> String {
        start.addingTimeInterval(offset).formatted(date: .omitted, time: .shortened)
    }

    func frameURL(_ screen: SharedScreen) -> URL {
        FrameIndex.folder(in: Paths.live.callDirectory(id)).appendingPathComponent(screen.file)
    }
}

/// The screens that were shared in the meeting: a grid by share session, and one frame large with what was said
/// around it.
struct ScreensTab: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    @ObservedObject var player: AudioPlayer
    var top: CGFloat = 28
    /// The open frame's file name; nil shows the grid.
    @Binding var selected: String?
    @State private var find = ""
    /// The word boxes of each frame, by file name, for the marks of a search.
    @State private var words: [String: [ScreenWord]] = [:]
    /// True when the pictures were removed with the old audio; the text stays.
    @State private var picturesGone = false

    private var screens: [SharedScreen] { (record.screens ?? []).sorted { $0.offset < $1.offset } }

    /// The tab's own field first, then the app's search.
    private var query: String {
        let own = find.trimmingCharacters(in: .whitespaces)
        return own.isEmpty ? controller.search.query.trimmingCharacters(in: .whitespaces) : own
    }

    var body: some View {
        let screens = screens
        Group {
            if let file = selected, let index = screens.firstIndex(where: { $0.file == file }) {
                ScreenViewer(record: record, screens: screens, index: index, player: player, query: query,
                             words: words[file] ?? [], top: top, find: $find, selected: $selected)
            } else {
                overview(screens)
            }
        }
        .task(id: record.id) {
            let dir = Paths.live.callDirectory(record.id)
            let loaded = await Task.detached(priority: .utility) { FrameIndex.load(from: dir) }.value
            words = Dictionary((loaded?.frames ?? []).map { ($0.file, $0.words ?? []) }, uniquingKeysWith: { a, _ in a })
            picturesGone = loaded == nil
        }
    }

    private func overview(_ screens: [SharedScreen]) -> some View {
        let q = query
        let shown = q.isEmpty ? screens : screens.filter { $0.text.localizedCaseInsensitiveContains(q) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ScreenFindField(text: $find)
                Text(q.isEmpty ? "\(screens.count) \(screens.count == 1 ? "screen" : "screens")"
                     : "\(shown.count) of \(screens.count) with “\(q)”")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .detailColumn(top: top, bottom: Space.s)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xl) {
                    if picturesGone {
                        Text("The pictures were removed with the old audio. Their text is still in the transcript.")
                            .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    }
                    ForEach(ShareSession.group(shown)) { session in
                        VStack(alignment: .leading, spacing: Space.m) {
                            Text(session.heading { record.timeOfDay($0) })
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                                .accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: Space.m)], alignment: .leading, spacing: Space.m) {
                                ForEach(session.screens) { screen in
                                    ScreenTile(record: record, screen: screen, matches: !q.isEmpty) { selected = screen.file }
                                }
                            }
                        }
                    }
                    if shown.isEmpty {
                        Text("No screen has that text.").font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    }
                }
                .detailColumn(top: Space.s)
            }
        }
    }
}

private struct ScreenFindField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            IconImage(.search, size: 13).foregroundStyle(Palette.tertiaryMark)
            TextField("Find on screens", text: $text).textFieldStyle(.plain)
                .onExitCommand { text = "" }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .frame(minWidth: 160, idealWidth: 260, maxWidth: 260, minHeight: 28, maxHeight: 28)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A frame in the grid: the picture and its time.
private struct ScreenTile: View {
    let record: CallRecord
    let screen: SharedScreen
    let matches: Bool
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                FrameThumbnail(url: record.frameURL(screen))
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                            .strokeBorder(matches ? Palette.accentFill : Palette.hairline, lineWidth: matches ? 1.5 : 1)
                    }
                    .opacity(hovered ? 0.88 : 1)
                Text(record.timeOfDay(screen.offset))
                    .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Palette.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(ScreenText.excerpt(screen.text))
        .accessibilityLabel("Screen at \(record.timeOfDay(screen.offset))")
    }
}

/// One frame large, the transcript around it, the frame's actions, and the filmstrip on the meeting's timeline.
private struct ScreenViewer: View {
    let record: CallRecord
    let screens: [SharedScreen]
    let index: Int
    @ObservedObject var player: AudioPlayer
    let query: String
    let words: [ScreenWord]
    let top: CGFloat
    @Binding var find: String
    @Binding var selected: String?
    @FocusState private var focused: Bool

    private var screen: SharedScreen { screens[index] }
    private var url: URL { record.frameURL(screen) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: 10) {
                Button { selected = nil } label: {
                    HStack(spacing: 4) {
                        IconImage(.chevronLeft, size: 11)
                        Text("All screens")
                    }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                ScreenFindField(text: $find)
                Text("\(index + 1) of \(screens.count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.secondary)
                Spacer(minLength: 0)
                step(-1, icon: .chevronLeft, label: "Previous screen")
                step(1, icon: .chevronRight, label: "Next screen")
            }
            HStack(alignment: .top, spacing: Space.l) {
                picture
                side.frame(width: 280)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Filmstrip(record: record, screens: screens, index: index, duration: max(player.duration, record.end.timeIntervalSince(record.start)),
                      time: player.time) { selected = screens[$0].file }
        }
        .padding(.horizontal, Detail.gutter)
        .padding(.top, top)
        .padding(.bottom, Space.l)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .onKeyPress(.escape) { selected = nil; return .handled }
        .onAppear { focused = true }
    }

    private func move(_ by: Int) -> KeyPress.Result {
        guard screens.indices.contains(index + by) else { return .ignored }
        selected = screens[index + by].file
        return .handled
    }

    private func step(_ by: Int, icon: Icon, label: String) -> some View {
        Button { _ = move(by) } label: {
            IconImage(icon, size: 12).foregroundStyle(Palette.ink)
                .frame(width: 28, height: 26)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!screens.indices.contains(index + by))
        .help(label)
        .accessibilityLabel(label)
    }

    private var picture: some View {
        MarkedFrame(url: url, marks: ScreenText.matches(words, query: query))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityLabel("Shared screen at \(record.timeOfDay(screen.offset))")
    }

    private var side: some View {
        let lines = record.lines(around: screen.offset)
        return VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(screen.rowTitle(time: record.timeOfDay(screen.offset), speaker: record.mainSpeaker(around: screen.offset)))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(longClock(screen.offset)).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Palette.tertiary)
            }
            Button { player.play(from: max(0, screen.offset - 5)) } label: {
                HStack(spacing: 6) {
                    IconImage(.play, size: 9)
                    Text("Play from here")
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.onAccent)
                .padding(.horizontal, 12).frame(height: 26)
                .background(Palette.accentFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!player.isAvailable)
            .help(player.isAvailable ? "Plays the audio from 5 seconds before this screen" : "The audio is not available")
            HStack(spacing: Space.m) {
                action("Copy image") { ScreenActions.copy(url) }
                action("Save image…") { ScreenActions.save(url, name: "\(record.title) \(longClock(screen.offset).replacingOccurrences(of: ":", with: "."))") }
                action("Open in Preview") { ScreenActions.openInPreview(url) }
            }
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s) {
                    if lines.isEmpty {
                        Text("Nobody spoke within 30 seconds of this screen.")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(line.speaker).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                                Button(longClock(line.start)) { player.play(from: line.start) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.tertiary)
                                    .disabled(!player.isAvailable)
                            }
                            Text(line.text).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
    }

    private func action(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(title, action: run)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
            .lineLimit(1).fixedSize()
    }
}

/// One frame at reading size, with a box on each word that a search found. The boxes are an overlay of the picture
/// itself, so they keep their place at any size.
private struct MarkedFrame: View {
    let url: URL
    let marks: [ScreenWord]
    @State private var image: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .overlay {
                        GeometryReader { g in
                            ForEach(Array(marks.enumerated()), id: \.offset) { _, w in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(Palette.accentFill.opacity(0.28))
                                    .overlay { RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Palette.accentFill, lineWidth: 1) }
                                    .frame(width: max(4, w.width * g.size.width + 4), height: max(4, w.height * g.size.height + 4))
                                    .position(x: (w.x + w.width / 2) * g.size.width, y: (w.y + w.height / 2) * g.size.height)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    .clipShape(shape)
                    .overlay { shape.strokeBorder(Palette.hairline, lineWidth: 1) }
            } else {
                shape.fill(Palette.fill).aspectRatio(16 / 10, contentMode: .fit)
            }
        }
        .task(id: url) {
            // The small copy from the grid shows at once; the large one replaces it.
            image = FrameThumbnails.shared.cached(url, longEdge: 1600) ?? FrameThumbnails.shared.cached(url, longEdge: 480)
            if let large = await FrameThumbnails.shared.image(url, longEdge: 1600) { image = large }
        }
    }
}

/// The frames along the meeting's time, so they line up with the audio. The open frame is on top.
private struct Filmstrip: View {
    let record: CallRecord
    let screens: [SharedScreen]
    let index: Int
    let duration: TimeInterval
    let time: TimeInterval
    let open: (Int) -> Void

    private static let height: CGFloat = 40
    private static let width: CGFloat = 64

    var body: some View {
        GeometryReader { g in
            let span = max(1, g.size.width - Self.width)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Palette.fill)
                    .frame(height: 4).offset(y: Self.height + 6)
                if time > 0, duration > 0 {
                    Rectangle().fill(Palette.ink).frame(width: 1.5, height: Self.height + 12)
                        .offset(x: Self.width / 2 + span * min(1, time / duration))
                }
                ForEach(Array(screens.enumerated()), id: \.element.id) { i, screen in
                    let on = i == index
                    Button { open(i) } label: {
                        FrameThumbnail(url: record.frameURL(screen), longEdge: 160)
                            .frame(width: Self.width, height: Self.height)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(on ? Palette.accentFill : Palette.hairline, lineWidth: on ? 2 : 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .help(record.timeOfDay(screen.offset))
                    .accessibilityLabel("Screen at \(record.timeOfDay(screen.offset))")
                    .offset(x: duration > 0 ? span * min(1, screen.offset / duration) : 0)
                    .zIndex(on ? 2 : 1)
                }
            }
        }
        .frame(height: Self.height + 12)
    }
}

/// A screen in the transcript, at its time: a small picture and who shared. A click opens it in the Screens tab.
struct ScreenLine: View {
    let record: CallRecord
    let screen: SharedScreen
    @Environment(\.openScreen) private var openScreen

    var body: some View {
        Button { openScreen?(screen) } label: {
            HStack(spacing: 10) {
                // Lines up with the words, past the speaker column.
                Color.clear.frame(width: 150 + Space.m - 10, height: 1)
                FrameThumbnail(url: record.frameURL(screen), longEdge: 160)
                    .frame(width: 56, height: 35)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1) }
                Text(screen.rowTitle(time: record.timeOfDay(screen.offset), speaker: record.mainSpeaker(around: screen.offset)))
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.secondary).lineLimit(1)
                Hairline()
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(ScreenText.excerpt(screen.text))
    }
}

/// The small mark of a shared screen on the player's ruler.
struct ScreenMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .strokeBorder(Palette.secondary, lineWidth: 1.2)
            .frame(width: 9, height: 7)
    }
}

@MainActor
enum ScreenActions {
    static func copy(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// Saves a PNG copy, which every app opens.
    static func save(_ url: URL, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + ".png"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        Task.detached(priority: .userInitiated) {
            guard let image = FrameImage.thumbnail(at: url, longEdge: 4000) else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: target, options: .atomic)
        }
    }

    static func openInPreview(_ url: URL) {
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }
}
