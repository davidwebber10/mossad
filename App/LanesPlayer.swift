import MossadCore
import SwiftUI

extension Palette {
    /// The meeting header's band: a trace of ink over the window, so the title and the player read as one block.
    static let band = Color(light: 0x1C1A17, lightAlpha: 0.035, dark: 0xFFFFFF, darkAlpha: 0.035)
    /// The band over the window as one opaque color, for the fade at the foot of scrolling lanes.
    static let bandOpaque = Color(light: 0xEEECE9, dark: 0x262523)
}

/// The player: one lane per speaker across the whole meeting, a playhead through every lane, decisions and
/// bookmarks on the ruler, and the transport row. Lanes draw in a Canvas each, so a meeting with a hundred voices
/// and a thousand turns stays fast.
struct LanesPlayer: View {
    @ObservedObject var player: AudioPlayer
    let record: CallRecord
    let people: MeetingPeople
    let lanes: [SpeakerLanes.Lane]
    var retentionDays: Int?
    /// Lanes shown before the rest scroll: fewer in a short window.
    var maxLanes = 12

    static let laneHeight = Detail.laneRow
    static let laneGap = Detail.laneGap
    /// The label column and its gap: where the lanes start.
    static let gutter = Detail.labelGutter

    @State private var dragging: TimeInterval?
    @State private var scrolledToEnd = false

    private var duration: TimeInterval {
        let recorded = player.duration > 0 ? player.duration : record.end.timeIntervalSince(record.start)
        return max(recorded, lanes.lazy.compactMap { $0.segments.last?.upperBound }.max() ?? 0, 1)
    }

    private var time: TimeInterval { dragging ?? player.time }
    private var started: Bool { player.isPlaying || player.time > 0 || dragging != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // No lanes yet while the call processes, or none when nobody spoke: the ruler and transport still play.
                if !lanes.isEmpty { lanesArea }
                PlayerRuler(record: record, duration: duration, time: time, enabled: player.isAvailable) { player.seek(to: $0) }
                    .padding(.top, 4)
            }
            .overlay(alignment: .topLeading) { playhead }
            PlayerTransport(player: player, record: record, noAudio: noAudioText)
                .padding(.top, 6)
        }
        .background { shortcuts }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Player")
    }

    // MARK: Lanes

    private var lanesArea: some View {
        let visible = min(lanes.count, maxLanes)
        let height = CGFloat(visible) * Self.laneHeight + CGFloat(max(visible - 1, 0)) * Self.laneGap
        let scrolls = lanes.count > maxLanes
        let current = started ? currentKey : nil
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: Self.laneGap) {
                ForEach(Array(lanes.enumerated()), id: \.element.key) { _, lane in
                    // Equatable, so a tick of the player redraws only the rows whose state changed.
                    LaneRow(lane: lane, speaker: people.speaker(forKey: lane.key), callID: record.id,
                            editable: record.status == .written, current: lane.key == current,
                            duration: duration, enabled: player.isAvailable,
                            scrub: { dragging = $0 }, seek: { dragging = nil; player.seek(to: $0) })
                        .equatable()
                }
            }
        }
        .frame(height: height)
        .scrollDisabled(!scrolls)
        .scrollIndicators(scrolls ? .automatic : .never)
        .onScrollGeometryChange(for: Bool.self) { g in
            g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 4
        } action: { _, end in scrolledToEnd = end }
        .overlay(alignment: .bottom) {
            if scrolls, !scrolledToEnd { moreVoices(lanes.count - maxLanes) }
        }
        .accessibilityRepresentation {
            Slider(value: Binding(get: { player.time }, set: { player.seek(to: $0) }), in: 0...duration) { Text("Position") }
        }
    }

    /// The speaker whose turn the playhead is in, named in bold.
    private var currentKey: String? {
        let t = time
        return lanes.first { $0.segments.contains { $0.contains(t) } }?.key
    }

    private func moreVoices(_ n: Int) -> some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Palette.bandOpaque.opacity(0), Palette.bandOpaque], startPoint: .top, endPoint: .bottom)
            Text("+\(n) more \(n == 1 ? "voice" : "voices") · scroll")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 9).padding(.vertical, 2)
                .background(Palette.fill, in: Capsule())
                .padding(.bottom, 2)
        }
        .frame(height: 38)
        .allowsHitTesting(false)
    }

    // MARK: Playhead

    private var playhead: some View {
        GeometryReader { g in
            let width = max(g.size.width - Self.gutter, 1)
            let x = Self.gutter + width * min(max(time / duration, 0), 1)
            let bubbleX = min(max(x, Self.gutter + 26), g.size.width - 26)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Palette.ink)
                    .frame(width: 1.5, height: max(g.size.height - 22 + 4, 0))
                    .offset(x: x - 0.75, y: -4)
                Text(longClock(time))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Palette.window)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Palette.ink, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .fixedSize()
                    .position(x: bubbleX, y: -18.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Keys

    private var shortcuts: some View {
        // J, K, and L: back 15 seconds, play or pause, forward 15 seconds, as in most players.
        Group {
            Button("Back 15 seconds") { player.skip(-15) }.keyboardShortcut("j", modifiers: [])
            Button("Play or pause") { player.toggle() }.keyboardShortcut("k", modifiers: [])
            Button("Forward 15 seconds") { player.skip(15) }.keyboardShortcut("l", modifiers: [])
        }
        .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        .disabled(!player.isAvailable)
    }

    private var noAudioText: String? {
        guard !player.isAvailable, record.status == .written else { return nil }
        if let days = retentionDays, record.end < Date().addingTimeInterval(-Double(days) * 86_400) {
            return "No audio. The recording was deleted after \(days) days."
        }
        return "No audio available."
    }
}

/// One speaker: name and minutes on the left, their turns across. Click or drag in the lane to play from there.
private struct LaneRow: View, @MainActor Equatable {
    let lane: SpeakerLanes.Lane
    let speaker: MeetingPeople.Speaker?
    let callID: String
    let editable: Bool
    let current: Bool
    let duration: TimeInterval
    let enabled: Bool
    let scrub: (TimeInterval) -> Void
    let seek: (TimeInterval) -> Void
    @State private var naming = false

    private var unknown: Bool { speaker?.isUnknown ?? true }
    private var color: Color { speaker?.color ?? Palette.bar }

    /// The closures only reach the player, which never changes for a row, so they are left out.
    static func == (a: LaneRow, b: LaneRow) -> Bool {
        a.lane == b.lane && a.current == b.current && a.duration == b.duration && a.enabled == b.enabled
            && a.editable == b.editable && a.callID == b.callID && a.speaker?.name == b.speaker?.name
            && a.speaker?.isUnknown == b.speaker?.isUnknown && a.speaker?.keys == b.speaker?.keys
            && a.speaker?.color == b.speaker?.color && a.speaker?.email == b.speaker?.email
    }

    var body: some View {
        HStack(spacing: Space.m) {
            HStack(spacing: 7) {
                Button { naming = true } label: {
                    Text(lane.name)
                        .fontWeight(unknown || current ? .semibold : .regular)
                        .foregroundStyle(unknown ? Palette.accent : Palette.ink)
                        .lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .disabled(!editable || speaker == nil)
                .help(unknown ? "Name this voice" : "Change who this is")
                .popover(isPresented: $naming, arrowEdge: .bottom) {
                    if let speaker { SpeakerNamingPopover(speaker: speaker, callID: callID, isPresented: $naming) }
                }
                Text(minutes).foregroundStyle(Palette.tertiary).frame(width: 30, alignment: .trailing)
            }
            .font(.system(size: 12)).monospacedDigit()
            .frame(width: Detail.labelColumn, alignment: .trailing)
            GeometryReader { g in
                Canvas { context, size in
                    let track = CGRect(x: 0, y: (size.height - Detail.laneTrack) / 2, width: size.width, height: Detail.laneTrack)
                    context.fill(Path(roundedRect: track, cornerRadius: Detail.laneTrackRadius), with: .color(Palette.fill))
                    let shading = GraphicsContext.Shading.color(color)
                    let inset = Detail.laneBarInset
                    // Merged at this width, so a long meeting reads as blocks rather than one-point slivers.
                    let blocks = SpeakerLanes.blocks(lane.segments, duration: duration, width: size.width,
                                                     mergeGap: Detail.laneMergeGap, minWidth: Detail.laneMinBlock)
                    for b in blocks {
                        let x = size.width * b.lowerBound / duration
                        let w = size.width * (b.upperBound - b.lowerBound) / duration
                        let bar = CGRect(x: x, y: track.minY + inset, width: w, height: Detail.laneTrack - inset * 2)
                        context.fill(Path(roundedRect: bar, cornerRadius: Detail.laneBarRadius), with: shading)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { scrub(at($0.location.x, g.size.width)) }
                    .onEnded { seek(at($0.location.x, g.size.width)) })
                .allowsHitTesting(enabled)
            }
            .frame(height: LanesPlayer.laneHeight)
        }
        .frame(height: LanesPlayer.laneHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lane.name), \(minutes)")
    }

    private var minutes: String {
        lane.seconds < 30 ? "<1m" : "\(Int((lane.seconds / 60).rounded()))m"
    }

    private func at(_ x: CGFloat, _ width: CGFloat) -> TimeInterval {
        min(max(0, x / max(width, 1)), 1) * duration
    }
}

/// Times along the meeting, with decisions as dots and bookmarks as accent flags. A dot or flag plays from there.
private struct PlayerRuler: View {
    let record: CallRecord
    let duration: TimeInterval
    let time: TimeInterval
    let enabled: Bool
    let seek: (TimeInterval) -> Void
    @Environment(\.openScreen) private var openScreen

    var body: some View {
        HStack(spacing: Detail.labelGap) {
            Color.clear.frame(width: Detail.labelColumn, height: 1)
            GeometryReader { g in
                let w = g.size.width
                let current = currentDecision
                ZStack(alignment: .topLeading) {
                    Hairline().frame(width: w).offset(y: 3)
                    ForEach(Array(ticks.enumerated()), id: \.offset) { i, t in
                        Text(t.label)
                            .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Palette.tertiary)
                            .frame(width: 60, alignment: i == 0 ? .leading : i == ticks.count - 1 ? .trailing : .center)
                            .position(x: i == 0 ? 30 : i == ticks.count - 1 ? w - 30 : w * t.fraction, y: 18)
                    }
                    ForEach(Array(record.decisions.enumerated()), id: \.offset) { i, d in
                        if let at = d.at {
                            marker(at: at, x: w * at / duration, help: "Decision · \(clock(at))\n\(d.text)", label: "Decision at \(clock(at))") {
                                Circle()
                                    .fill(i == current ? Palette.ink : Palette.window)
                                    .overlay { Circle().strokeBorder(Palette.ink, lineWidth: 1.5) }
                                    .frame(width: 7, height: 7)
                            }
                        }
                    }
                    if let screens = record.screens, !screens.isEmpty {
                        // One drawing and one click target for all screens. It does not take the play position.
                        RulerScreenMarks(screens: screens, duration: duration, width: w) { openScreen?($0) }
                            .equatable()
                    }
                    ForEach(Array(bookmarks.enumerated()), id: \.offset) { _, b in
                        let note = b.note?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                        marker(at: b.offset, x: w * b.offset / duration, help: "Bookmark · \(clock(b.offset))" + (note.map { "\n\($0)" } ?? ""),
                               label: "Bookmark at \(clock(b.offset))") {
                            BookmarkFlag().fill(Palette.accentFill).frame(width: 9, height: 11)
                        }
                    }
                }
            }
            .frame(height: Detail.rulerHeight)
        }
    }

    private var bookmarks: [TranscriptMarker] { record.transcriptMarkers.filter(\.isBookmark) }

    /// The decision the playhead last passed: its dot fills.
    private var currentDecision: Int? {
        guard time > 0 else { return nil }
        return record.decisions.indices.filter { (record.decisions[$0].at ?? .infinity) <= time }
            .max { record.decisions[$0].at! < record.decisions[$1].at! }
    }

    private func marker<Mark: View>(at: TimeInterval, x: CGFloat, help: String, label: String, @ViewBuilder mark: () -> Mark) -> some View {
        Button { seek(at) } label: {
            mark().frame(width: 16, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(label)
        .position(x: x, y: 3.5)
    }

    /// Start, quarters, and end. An hour or more reads as hours and minutes ("0:26"); under ten minutes, as
    /// minutes and seconds.
    private var ticks: [(fraction: Double, label: String)] {
        [0, 0.25, 0.5, 0.75, 1].map { f in
            let s = Int(duration * f)
            let label = duration >= 600 ? String(format: "%d:%02d", s / 3600, (s % 3600) / 60) : String(format: "%d:%02d", s / 60, s % 60)
            return (f, label)
        }
    }
}

/// −15, play, +15, Add bookmark, and the speeds.
private struct PlayerTransport: View {
    @EnvironmentObject var controller: AppController
    @ObservedObject var player: AudioPlayer
    let record: CallRecord
    let noAudio: String?
    @State private var bookmarked: TimeInterval?
    @State private var adding = false

    var body: some View {
        let enabled = player.isAvailable
        HStack(spacing: Detail.transportGap) {
            HStack(spacing: 4) {
                skip(-15)
                Button { player.toggle() } label: {
                    IconImage(player.isPlaying ? .pause : .play, size: 10)
                        .foregroundStyle(Palette.window)
                        .frame(width: Detail.playButton, height: Detail.playButton)
                        .background(Palette.ink, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                skip(15)
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            bookmarkButton.padding(.leading, 6)
            if let noAudio { Text(noAudio).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1) }
            Spacer(minLength: 0)
            SpeedControl(rate: $player.rate).disabled(!enabled).opacity(enabled ? 1 : 0.45).fixedSize()
        }
        .padding(.leading, LanesPlayer.gutter)
        .frame(height: Detail.transportHeight)
    }

    private func skip(_ seconds: TimeInterval) -> some View {
        Button { player.skip(seconds) } label: {
            SkipGlyph(forward: seconds > 0)
                .foregroundStyle(Palette.secondary)
                .frame(width: Detail.skipButton, height: Detail.skipButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(seconds < 0 ? "Back 15 seconds" : "Forward 15 seconds")
    }

    private var bookmarkButton: some View {
        let open = bookmarked != nil
        return Button(action: add) {
            // A narrow window keeps the flag and drops the words rather than cut them.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    BookmarkFlag().fill(Palette.accentFill).frame(width: 9, height: 11)
                    Text("Add bookmark").fixedSize()
                }
                BookmarkFlag().fill(Palette.accentFill).frame(width: 9, height: 11)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(open ? Palette.accent : Palette.ink)
            .padding(.leading, 10).padding(.trailing, 12)
            .frame(height: Detail.bookmarkHeight)
            .background(open ? Palette.accentTint : Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add bookmark")
        .disabled(adding || (!player.isAvailable && record.status != .recording))
        .help("Mark this moment, with an optional note")
        .popover(isPresented: Binding(get: { bookmarked != nil }, set: { if !$0 { bookmarked = nil } }), arrowEdge: .bottom) {
            if let at = bookmarked {
                BookmarkNotePopover(at: at) { note in
                    controller.setBookmarkNote(callID: record.id, offset: at, note: note)
                } dismiss: { bookmarked = nil }
            }
        }
    }

    /// The bookmark goes in at once; the popover only offers a note.
    private func add() {
        adding = true
        let at = player.time
        Task {
            bookmarked = await controller.addBookmark(callID: record.id, at: at)
            adding = false
        }
    }
}

/// The canvas's skip icon: a circular arrow with "15" inside, 18 pt in a 24 pt box, mirrored for forward.
private struct SkipGlyph: View {
    let forward: Bool

    var body: some View {
        ZStack {
            SkipArrow(forward: forward)
                .stroke(style: StrokeStyle(lineWidth: 1.8 * 18 / 24, lineCap: .round, lineJoin: .round))
            Text("15").font(.system(size: 7.5 * 18 / 24, weight: .bold)).offset(y: 0.9)
        }
        .frame(width: 18, height: 18)
    }
}

private struct SkipArrow: Shape {
    let forward: Bool

    /// The canvas's path in its 24 pt box: an arc of radius 8 around (12, 13) from 260° to 225°, and the head.
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (forward ? 24 - x : x) * k, y: rect.minY + y * k)
        }
        var p = Path()
        let steps = 48
        for i in 0...steps {
            let a = (260 + 325 * Double(i) / Double(steps)) * .pi / 180
            let q = pt(12 + 8 * cos(a), 13 + 8 * sin(a))
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        p.move(to: pt(6.3, 3.9))
        p.addLine(to: pt(6.3, 7.4))
        p.addLine(to: pt(9.8, 7.4))
        return p
    }
}

/// 1×, 1.25×, 1.5×, 2× in one quiet capsule.
private struct SpeedControl: View {
    @Binding var rate: Float
    private let speeds: [Float] = [1, 1.25, 1.5, 2]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(speeds, id: \.self) { s in
                let on = s == rate
                Button { rate = s } label: {
                    Text(s == 1 ? "1×" : "\(s.formatted())×")
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .fixedSize()
                        .foregroundStyle(on ? Palette.ink : Palette.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background {
                            if on { Capsule().fill(Palette.segmentOn).shadow(color: .black.opacity(0.12), radius: 1, y: 1) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(s.formatted()) times speed")
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Palette.fill, in: Capsule())
    }
}

/// "Bookmarked at 0:52:08", and an optional note. Return with no note skips it; the popover also closes itself
/// after a few seconds when nothing was typed.
struct BookmarkNotePopover: View {
    let at: TimeInterval
    let save: (String) -> Void
    let dismiss: () -> Void
    @State private var note = ""
    @State private var saved = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                BookmarkFlag().fill(Palette.accentFill).frame(width: 9, height: 11)
                Text("Bookmarked at \(longClock(at))").monospacedDigit()
            }
            .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 5) {
                Text("Note \(Text("(optional)").foregroundStyle(Palette.tertiary))")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                TextField("What happened here?", text: $note)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .focused($focused)
                    .onSubmit(finish)
            }
            .padding(.top, 10)
            HStack(spacing: Space.s) {
                Text(note.isEmpty ? "Press Return to skip the note" : "Press Return to save the note")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                Spacer(minLength: 0)
                Button(action: finish) {
                    Text("Done")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background(Palette.accentFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, Space.m)
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { focused = true }
        // A click outside closes the popover; a typed note must not be lost with it.
        .onDisappear(perform: keep)
        .task {
            try? await Task.sleep(for: .seconds(8))
            if note.isEmpty { dismiss() }
        }
    }

    private func finish() {
        keep()
        dismiss()
    }

    private func keep() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved, !text.isEmpty else { return }
        saved = true
        save(text)
    }
}

/// The canvas's bookmark: a ribbon with a notch.
struct BookmarkFlag: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 7.8 / 11))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
