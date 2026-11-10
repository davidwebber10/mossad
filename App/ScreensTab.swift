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
/// never decodes a frame at full size. A picture is decoded one time, also when two views ask for it at once. The
/// decodes wait in one queue of low priority that runs three at a time, so a fast scroll through a page of frames
/// holds no threads, and the large picture of the viewer goes before the small ones.
@MainActor
final class FrameThumbnails {
    static let shared = FrameThumbnails()
    private let cache = NSCache<NSString, NSImage>()
    private var loading: [String: Task<NSImage?, Never>] = [:]
    private nonisolated static let decodes: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.dwebber.mossad.thumbnails"
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .utility
        return q
    }()
    static let sizes = [160, 480, 1600]

    private init() {
        cache.countLimit = 600
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func cached(_ url: URL, longEdge: Int) -> NSImage? {
        cache.object(forKey: "\(url.path)#\(longEdge)" as NSString)
    }

    /// A deleted frame leaves no copy in memory.
    func forget(_ url: URL) {
        for size in Self.sizes { cache.removeObject(forKey: "\(url.path)#\(size)" as NSString) }
    }

    func image(_ url: URL, longEdge: Int) async -> NSImage? {
        let key = "\(url.path)#\(longEdge)"
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let running = loading[key] { return await running.value }
        let task = Task { () -> NSImage? in
            // Through a continuation, so the view that waits does not raise the decode's priority.
            let decoded: CGImage? = await withCheckedContinuation { done in
                let work = BlockOperation { done.resume(returning: FrameImage.thumbnail(at: url, longEdge: longEdge)) }
                work.queuePriority = longEdge >= 1000 ? .veryHigh : .normal
                Self.decodes.addOperation(work)
            }
            return decoded.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height) * 4) }
        return image
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

    /// The time of day a screen was on, as the page shows it. Not the start plus the offset: the offset leaves
    /// out pauses and the time between the parts of a joined meeting.
    func timeOfDay(_ screen: SharedScreen) -> String {
        date(of: screen).formatted(date: .omitted, time: .shortened)
    }

    /// "Sam Carter shared 12:04–12:19 · 9 screens", with the times of the session's first and last screen.
    func heading(_ session: ShareSession) -> String {
        session.heading { offset in session.screens.first { $0.offset == offset }.map(timeOfDay) ?? "" }
    }

    /// Changes when the screens, their text or presenter, or the speakers' names do: what the Screens tab shows.
    var screensStamp: Int {
        var h = Hasher()
        h.combine(id)
        h.combine(title)
        h.combine(speakerNames)
        for s in screens ?? [] {
            h.combine(s.file)
            h.combine(s.text.utf8.count)
            h.combine(s.presenter)
        }
        return h.finalize()
    }

    /// The row in the transcript and the title in the viewer.
    func screenTitle(_ screen: SharedScreen) -> String {
        screen.rowTitle(time: timeOfDay(screen), speaker: screen.presenter == nil ? mainSpeaker(around: screen.offset) : nil)
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
    /// Not observed here: the tab does not draw again on each tick of the playback. The small views that show
    /// the play position observe it themselves.
    let player: AudioPlayer
    var top: CGFloat = 28
    /// The open frame's file name; nil shows the grid.
    @Binding var selected: String?
    @State private var find = ""
    /// The word boxes of each frame, by file name, for the marks of a search.
    @State private var words: [String: [ScreenWord]] = [:]
    /// True when the pictures were removed with the recording; the text stays.
    @State private var picturesGone = false
    @State private var sessions: [ShareSession] = []
    /// The screen the owner asked to delete, until the answer.
    @State private var deleting: SharedScreen?

    private var screens: [SharedScreen] { (record.screens ?? []).sorted { $0.offset < $1.offset } }
    private var ownQuery: String { find.trimmingCharacters(in: .whitespaces) }

    /// For the marks on a frame: the tab's own field first, then the app's search.
    private var markQuery: String {
        ownQuery.isEmpty ? controller.search.query.trimmingCharacters(in: .whitespaces) : ownQuery
    }

    /// Changes when the screens do, also after the text was read again or a speaker got a name.
    private var screensKey: Int { record.screensStamp }

    var body: some View {
        let screens = screens
        Group {
            if !picturesGone, let file = selected, let index = screens.firstIndex(where: { $0.file == file }) {
                ScreenViewer(record: record, screens: screens, index: index, player: player, query: markQuery,
                             words: words[file] ?? [], top: top, stamp: screensKey, find: $find, selected: $selected) { deleting = $0 }
            } else {
                overview(screens)
            }
        }
        .task(id: screensKey) {
            sessions = ShareSession.group(screens)
            let dir = Paths.live.callDirectory(record.id)
            let loaded = await Task.detached(priority: .utility) { FrameIndex.load(from: dir) }.value
            words = Dictionary((loaded?.frames ?? []).map { ($0.file, $0.words ?? []) }, uniquingKeysWith: { a, _ in a })
            picturesGone = loaded == nil
        }
        .confirmationDialog("Delete this screen?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { screen in
            Button("Delete screen", role: .destructive) { delete(screen) }
        } message: { _ in
            Text("Mossad removes the picture and its line in the transcript, and writes the note again. The summary is not changed.")
        }
    }

    /// Moves on to the next screen (or back to the grid), then deletes.
    private func delete(_ screen: SharedScreen) {
        let all = screens
        if selected == screen.file, let i = all.firstIndex(where: { $0.file == screen.file }) {
            selected = (all[safe: i + 1] ?? all[safe: i - 1])?.file
        }
        FrameThumbnails.shared.forget(record.frameURL(screen))
        controller.deleteScreen(callID: record.id, file: screen.file)
    }

    private func overview(_ screens: [SharedScreen]) -> some View {
        // The grid is filtered by the tab's own field only, with the same words as the marks.
        let q = ownQuery
        let shown = q.isEmpty ? sessions : ShareSession.group(screens.filter { ScreenText.contains($0.text, query: q) })
        let count = shown.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ScreenFindField(text: $find)
                Text(q.isEmpty ? "\(screens.count) \(screens.count == 1 ? "screen" : "screens")"
                     : "\(count) of \(screens.count) with “\(q)”")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .detailColumn(top: top, bottom: Space.s)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xl) {
                    if picturesGone {
                        Text("The pictures were removed with the recording. Their text is still in the transcript.")
                            .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    }
                    ForEach(shown) { session in
                        VStack(alignment: .leading, spacing: Space.m) {
                            Text(record.heading(session))
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                                .accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: Space.m)], alignment: .leading, spacing: Space.m) {
                                ForEach(session.screens) { screen in
                                    ScreenTile(url: record.frameURL(screen), time: record.timeOfDay(screen), text: screen.text,
                                               matches: !q.isEmpty, enabled: !picturesGone) { selected = screen.file }
                                        // Also when the pictures are gone: the text of a screen can still be deleted.
                                        .contextMenu { Button("Delete screen…", role: .destructive) { deleting = screen } }
                                }
                            }
                        }
                    }
                    if shown.isEmpty, !q.isEmpty {
                        Text("No screen has that text.").font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    }
                }
                .detailColumn(top: Space.s)
            }
        }
    }
}

/// The meeting page draws again on each tick of the playback. The tab does not: it is the same until its screens,
/// the open frame, or its place change.
extension ScreensTab: Equatable {
    nonisolated static func == (a: ScreensTab, b: ScreensTab) -> Bool {
        a.record.screensStamp == b.record.screensStamp && a.selected == b.selected && a.top == b.top && a.player === b.player
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
    let url: URL
    let time: String
    let text: String
    let matches: Bool
    let enabled: Bool
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                FrameThumbnail(url: url)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                            .strokeBorder(matches ? Palette.accentFill : Palette.hairline, lineWidth: matches ? 1.5 : 1)
                    }
                    .opacity(hovered && enabled ? 0.88 : 1)
                Text(time).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Palette.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 }
        .accessibilityLabel("Screen at \(time)")
    }
}

/// One frame large, the transcript around it, the frame's actions, and the filmstrip on the meeting's timeline.
private struct ScreenViewer: View {
    let record: CallRecord
    let screens: [SharedScreen]
    let index: Int
    let player: AudioPlayer
    let query: String
    let words: [ScreenWord]
    let top: CGFloat
    /// Changes when the names or the text do, so the lines around the frame are worked out again.
    let stamp: Int
    @Binding var find: String
    @Binding var selected: String?
    let delete: (SharedScreen) -> Void
    @FocusState private var focused: Bool
    /// What was said around the open frame and its title: worked out when the frame changes, not on each draw.
    @State private var context = Context()

    private struct Context {
        var file = ""
        var title = ""
        var lines: [(start: TimeInterval, speaker: String, text: String)] = []
    }

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
            Filmstrip(record: record, screens: screens, index: index, player: player) { selected = screens[$0].file }
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
        .task(id: "\(screen.file)|\(stamp)") {
            context = Context(file: screen.file, title: record.screenTitle(screen), lines: record.lines(around: screen.offset))
        }
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
            .accessibilityLabel("Shared screen at \(record.timeOfDay(screen))")
    }

    private var side: some View {
        // Until the task ran for this frame, the lines of the frame before are not shown.
        let lines = context.file == screen.file ? context.lines : []
        return VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(context.file == screen.file ? context.title : " ")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(longClock(screen.offset)).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Palette.tertiary)
            }
            PlayFromHere(player: player, at: max(0, screen.offset - 5))
            HStack(spacing: Space.m) {
                action("Copy image") { ScreenActions.copy(url) }
                action("Save image…") { ScreenActions.save(url, name: "\(record.title) \(longClock(screen.offset).replacingOccurrences(of: ":", with: "."))") }
                action("Open in Preview") { ScreenActions.openInPreview(url) }
            }
            Button("Delete screen…") { delete(screen) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.recording)
                .help("Removes this picture and its line in the transcript")
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s) {
                    if lines.isEmpty, context.file == screen.file {
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

/// Plays the audio from a little before the frame. It alone follows whether the audio is there.
private struct PlayFromHere: View {
    @ObservedObject var player: AudioPlayer
    let at: TimeInterval

    var body: some View {
        Button { player.play(from: at) } label: {
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

/// The frames along the meeting's time, so they line up with the audio. Every frame is a small mark; pictures are
/// drawn only where there is room for one (about one for each 70 pt) and for the open frame, so a long meeting
/// decodes a dozen small pictures, not hundreds.
private struct Filmstrip: View {
    let record: CallRecord
    let screens: [SharedScreen]
    let index: Int
    let player: AudioPlayer
    let open: (Int) -> Void

    private static let height: CGFloat = 40
    private static let width: CGFloat = 64
    private static let spacing: CGFloat = 70

    var body: some View {
        let duration = max(player.duration, record.end.timeIntervalSince(record.start), screens.last?.offset ?? 0, 1)
        GeometryReader { g in
            let span = max(1, g.size.width - Self.width)
            let pictured = FilmstripLayout.pictured(screens.map(\.offset), open: index, duration: duration, span: span, spacing: Self.spacing)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let line = CGRect(x: Self.width / 2, y: Self.height + 6, width: span, height: 4)
                    context.fill(Path(roundedRect: line, cornerRadius: 2), with: .color(Palette.fill))
                    for s in screens {
                        let x = Self.width / 2 + span * min(1, s.offset / duration)
                        context.fill(Path(CGRect(x: x - 0.75, y: Self.height + 3, width: 1.5, height: 10)), with: .color(Palette.secondary))
                    }
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in
                    // A click on the line opens the frame nearest to that time.
                    let at = duration * min(1, max(0, (tap.location.x - Self.width / 2) / span))
                    if let nearest = screens.indices.min(by: { abs(screens[$0].offset - at) < abs(screens[$1].offset - at) }) { open(nearest) }
                })
                ForEach(pictured, id: \.self) { i in
                    let on = i == index
                    Button { open(i) } label: {
                        FrameThumbnail(url: record.frameURL(screens[i]), longEdge: 160)
                            .frame(width: Self.width, height: Self.height)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(on ? Palette.accentFill : Palette.hairline, lineWidth: on ? 2 : 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Screen \(i + 1) of \(screens.count)")
                    .offset(x: span * min(1, screens[i].offset / duration))
                    .zIndex(on ? 2 : 1)
                }
                FilmstripPlayhead(player: player, duration: duration, span: span, inset: Self.width / 2, height: Self.height + 14)
            }
        }
        .frame(height: Self.height + 14)
    }
}

/// The play position on the filmstrip. Only this small view draws again as the audio plays.
private struct FilmstripPlayhead: View {
    @ObservedObject var player: AudioPlayer
    let duration: TimeInterval
    let span: CGFloat
    let inset: CGFloat
    let height: CGFloat

    var body: some View {
        if player.time > 0 {
            Rectangle().fill(Palette.ink).frame(width: 1.5, height: height)
                .offset(x: inset + span * min(1, player.time / duration))
                .allowsHitTesting(false)
        }
    }
}

/// A screen in the transcript, at its time: a small picture and who shared. A click opens it in the Screens tab.
/// The title comes ready, so a tick of the playback does not work it out again.
struct ScreenLine: View {
    let url: URL
    let title: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                // Lines up with the words, past the speaker column.
                Color.clear.frame(width: 150 + Space.m - 10, height: 1)
                FrameThumbnail(url: url, longEdge: 160)
                    .frame(width: 56, height: 35)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1) }
                Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.secondary).lineLimit(1)
                Hairline()
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The shared screens on the player's ruler: every mark in one drawing, and one click target that opens the
/// nearest screen. It takes no play position, and it is equal to itself while the screens are the same, so the
/// playback (four draws of the ruler each second) does not make it again.
struct RulerScreenMarks: View, Equatable {
    let screens: [SharedScreen]
    let duration: TimeInterval
    let width: CGFloat
    let open: (SharedScreen) -> Void

    private static let reach: Double = 8

    nonisolated static func == (a: RulerScreenMarks, b: RulerScreenMarks) -> Bool {
        a.duration == b.duration && a.width == b.width && a.screens.count == b.screens.count
            && a.screens.first?.file == b.screens.first?.file && a.screens.last?.file == b.screens.last?.file
    }

    var body: some View {
        Canvas { context, _ in
            guard duration > 0 else { return }
            for s in screens {
                let x = width * min(1, s.offset / duration)
                let mark = CGRect(x: x - 4.5, y: 0, width: 9, height: 7).insetBy(dx: 0.6, dy: 0.6)
                context.stroke(Path(roundedRect: mark, cornerRadius: 1.5), with: .color(Palette.secondary), lineWidth: 1.2)
            }
        }
        .frame(width: width, height: 12)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { tap in
            let offsets = screens.map(\.offset)
            if let i = FilmstripLayout.nearest(offsets, atX: tap.location.x, duration: duration, span: width, reach: Self.reach) { open(screens[i]) }
        })
        .help(screens.count == 1 ? "A shared screen. Click it to open it." : "Shared screens. Click one to open it.")
        .accessibilityElement()
        .accessibilityLabel(screens.count == 1 ? "1 shared screen" : "\(screens.count) shared screens")
        .accessibilityHint("Open the Screens tab for each one")
    }
}

@MainActor
enum ScreenActions {
    /// The picture is decoded off the main thread, then put on the pasteboard.
    static func copy(_ url: URL) {
        Task {
            let decoded = await Task.detached(priority: .userInitiated) { FrameImage.thumbnail(at: url, longEdge: 4000) }.value
            guard let decoded else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))])
        }
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
