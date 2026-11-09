import MossadCore
import SwiftUI

/// The transcript as turns in the label column: the speaker on the left, what they said on the right. It follows
/// playback with the current turn highlighted; Find marks every match in place.
struct TranscriptTab: View {
    let record: CallRecord
    let people: MeetingPeople
    @ObservedObject var player: AudioPlayer
    /// Room above the tools for the tabs on the band's edge.
    var top: CGFloat = 28
    /// A moment to mark and scroll to, such as where a commitment was made.
    var highlight: TimeInterval?
    @State private var blocks: [TranscriptBlock] = []
    @State private var stats = ""
    @State private var find = ""
    @State private var matchIndex = 0
    @State private var follow = true
    @State private var jump = 0
    @State private var flashed: Int?
    @FocusState private var findFocused: Bool

    private struct LineID: Hashable { let block: Int; let line: Int }

    /// Rebuilt only when the words or the names change, not on every tick of the player.
    private var blocksKey: String {
        "\(record.utterances.count)|\(record.markers.count)|\(record.screens?.count ?? 0)|" + record.speakerNames.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    var body: some View {
        let matches = self.matches()
        let current = player.isPlaying || player.time > 0 ? currentBlock : nil
        let marked = highlight.flatMap { h in blocks.last { $0.start <= h + 0.5 }?.id }
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                tools(matches: matches, proxy: proxy)
                    .detailColumn(top: top, bottom: Space.s)
                if record.utterances.isEmpty {
                    EmptyState(symbol: "text.bubble", title: record.status == .written ? "No speech detected" : "No transcript yet",
                               message: record.status == .written ? "The call was recorded, but nobody spoke." : "The transcript appears when processing is done.")
                } else {
                    ScrollView {
                        turns(matches: matches, current: current, marked: marked)
                            .detailColumn(top: 2)
                    }
                    // Playing or seeking in the lanes both move the current turn into view.
                    .onChange(of: current) { _, block in
                        guard follow, let block else { return }
                        withAnimation { proxy.scrollTo(block, anchor: .center) }
                    }
                    .task(id: blocks.count) {
                        guard follow, let current else { return }
                        try? await Task.sleep(for: .milliseconds(100))
                        proxy.scrollTo(current, anchor: .center)
                    }
                    .task(id: marked) {
                        guard let marked else { return }
                        try? await Task.sleep(for: .milliseconds(150))
                        withAnimation { proxy.scrollTo(marked, anchor: .center) }
                    }
                    .onChange(of: matchIndex) { _, i in
                        if matches.indices.contains(i) { withAnimation { proxy.scrollTo(matches[i].block, anchor: .center) } }
                    }
                    .onChange(of: find) { _, _ in
                        matchIndex = 0
                        if let first = self.matches().first { proxy.scrollTo(first.block, anchor: .center) }
                    }
                }
            }
        }
        .task(id: blocksKey) {
            blocks = TranscriptBlock.blocks(record)
            let words = record.utterances.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
            stats = "\(blocks.count.formatted()) \(blocks.count == 1 ? "turn" : "turns") · \(words.formatted()) words"
        }
    }

    // MARK: Tools

    private func tools(matches: [LineID], proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            findField(count: matches.count)
            Text(stats).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
            if player.isAvailable {
                Button { follow.toggle() } label: {
                    Text(follow ? "· follows playback" : "· Follow playback")
                        .font(.system(size: 12, weight: follow ? .regular : .semibold))
                        .foregroundStyle(follow ? Palette.secondary : Palette.accent)
                        .lineLimit(1).fixedSize()
                }
                .buttonStyle(.plain)
                .padding(.leading, -6)
                .help(follow ? "Stop scrolling with playback" : "Keep the playing turn in view")
            }
            Spacer(minLength: 0)
            let unnamed = people.speakers.filter(\.isUnknown)
            if record.status == .written, !unnamed.isEmpty {
                let target = unnamed[jump % unnamed.count]
                Button {
                    guard let block = blocks.first(where: { target.keys.contains($0.speakerKey) }) else { return }
                    withAnimation { proxy.scrollTo(block.id, anchor: .center) }
                    flashed = block.id
                    jump += 1
                } label: {
                    Text("Jump to \(target.name)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Palette.accentTint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Show where this voice first speaks, to name it")
            }
        }
    }

    private func findField(count: Int) -> some View {
        HStack(spacing: 7) {
            IconImage(.search, size: 13).foregroundStyle(Palette.tertiaryMark)
            TextField("Find in transcript", text: $find).textFieldStyle(.plain).focused($findFocused)
                .onSubmit { step(1, count: count) }
                .onExitCommand { find = "" }
            if !find.isEmpty {
                Text(count == 0 ? "0 of 0" : "\(matchIndex + 1) of \(count)")
                    .foregroundStyle(Palette.secondary).monospacedDigit()
                Button { step(-1, count: count) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain).keyboardShortcut("g", modifiers: [.command, .shift]).accessibilityLabel("Previous match")
                Button { step(1, count: count) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain).keyboardShortcut("g", modifiers: .command).accessibilityLabel("Next match")
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .frame(minWidth: 160, idealWidth: 300, maxWidth: 300, minHeight: 28, maxHeight: 28)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func step(_ by: Int, count: Int) {
        guard count > 0 else { return }
        matchIndex = (matchIndex + by + count) % count
    }

    // MARK: Turns

    private func turns(matches: [LineID], current: Int?, marked: Int?) -> some View {
        let breaks = record.recordingMarkers
        let screens = record.screens ?? []
        let active = matches.indices.contains(matchIndex) ? matches[matchIndex] : nil
        return LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(blocks, id: \.id) { block in
                let previousEnd = block.id > 0 ? blocks[safe: block.id - 1]?.end ?? -1 : -1
                ForEach(Array(breaks.filter { $0.offset > previousEnd && $0.offset <= block.start }.enumerated()), id: \.offset) { _, m in
                    MarkerLine(marker: m)
                }
                ForEach(screens.filter { $0.offset > previousEnd && $0.offset <= block.start }) { s in
                    ScreenLine(record: record, screen: s)
                }
                TurnRow(block: block, speaker: people.speaker(forKey: block.speakerKey), callID: record.id,
                        editable: record.status == .written, player: player,
                        background: block.id == marked || block.id == flashed ? Palette.accentTint : block.id == current ? Palette.selection : .clear,
                        text: { i, text in highlighted(text, active: active == LineID(block: block.id, line: i)) })
                    .id(block.id)
            }
            ForEach(Array(breaks.filter { $0.offset > (blocks.last?.end ?? -1) }.enumerated()), id: \.offset) { _, m in
                MarkerLine(marker: m)
            }
            ForEach(screens.filter { $0.offset > (blocks.last?.end ?? -1) }) { s in
                ScreenLine(record: record, screen: s)
            }
        }
        .textSelection(.enabled)
    }

    /// One entry per line that contains the term, in reading order.
    private func matches() -> [LineID] {
        let q = find.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return blocks.flatMap { block in
            block.lines.enumerated().compactMap { i, line in
                line.text.localizedCaseInsensitiveContains(q) ? LineID(block: block.id, line: i) : nil
            }
        }
    }

    private func highlighted(_ text: String, active: Bool) -> AttributedString {
        var result = AttributedString(text)
        let q = find.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return result }
        var search = result.startIndex..<result.endIndex
        while let range = result[search].range(of: q, options: .caseInsensitive) {
            result[range].backgroundColor = active ? Palette.accentFill : Palette.accentTint
            if active { result[range].foregroundColor = Palette.onAccent }
            search = range.upperBound..<result.endIndex
        }
        return result
    }

    /// The last turn that starts at or before the play position.
    private var currentBlock: Int? {
        blocks.last { $0.start <= player.time }?.id
    }
}

/// One turn: the speaker and their hue on the left; the words, then the time, on the right.
private struct TurnRow: View {
    let block: TranscriptBlock
    let speaker: MeetingPeople.Speaker?
    let callID: String
    let editable: Bool
    @ObservedObject var player: AudioPlayer
    let background: Color
    let text: (Int, String) -> AttributedString
    @State private var naming = false

    private var unknown: Bool { speaker?.isUnknown ?? true }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(block.speaker)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(unknown ? Palette.accent : Palette.ink)
                    .lineLimit(1).truncationMode(.tail)
                Circle().fill(speaker?.color ?? Palette.tertiaryMark).frame(width: 8, height: 8).offset(y: -1)
            }
            .frame(width: 150, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(block.lines.enumerated()), id: \.offset) { i, line in
                    Text(text(i, line.text))
                        .font(.system(size: 13)).lineSpacing(13 * 0.45 - 3)
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contextMenu {
                            Button("Play from \(clock(line.start))", systemImage: "play") { player.play(from: line.start) }
                                .disabled(!player.isAvailable)
                        }
                }
                HStack(spacing: Space.s) {
                    Button(longClock(block.start)) { player.play(from: block.start) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5)).monospacedDigit()
                        .foregroundStyle(Palette.tertiary)
                        .disabled(!player.isAvailable)
                        .help(player.isAvailable ? "Play from here" : "The audio is not available")
                    if unknown, editable, let speaker {
                        Button { naming = true } label: {
                            Text("Name this voice ▾")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Palette.accent)
                                .padding(.horizontal, 7)
                                .frame(height: 17)
                                .background(Palette.accentTint, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $naming, arrowEdge: .bottom) {
                            SpeakerNamingPopover(speaker: speaker, callID: callID, isPresented: $naming)
                        }
                    }
                }
                .padding(.top, 3)
            }
            .padding(.trailing, Space.s)
        }
        .padding(.vertical, Space.s)
        .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A pause, a stop, a join, or a bookmark, drawn across the transcript.
private struct MarkerLine: View {
    let marker: TranscriptMarker

    var body: some View {
        HStack(spacing: 10) {
            // Lines up with the words, past the speaker column.
            Color.clear.frame(width: 150 + Space.m - 10, height: 1)
            if marker.isBookmark { BookmarkFlag().fill(Palette.accentFill).frame(width: 7, height: 9) }
            Text(marker.lineText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(marker.isBookmark ? Palette.accent : Palette.secondary)
                .lineLimit(2)
            Hairline()
        }
        .padding(.vertical, 6)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
