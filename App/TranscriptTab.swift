import MossadCore
import SwiftUI

/// The transcript in speaker blocks. Find highlights every match in place; Follow keeps the playing line centered.
struct TranscriptTab: View {
    let record: CallRecord
    let people: MeetingPeople
    @ObservedObject var player: AudioPlayer
    var horizontalPadding: CGFloat = 16
    var maxWidth: CGFloat = .infinity
    @State private var find = ""
    @State private var matchIndex = 0
    @State private var follow = true

    private struct LineID: Hashable { let block: Int; let line: Int }

    var body: some View {
        let blocks = TranscriptBlock.blocks(record)
        let matches = self.matches(blocks)
        let current = player.isPlaying || player.time > 0 ? currentLine(blocks) : nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Spacer()
                findField(count: matches.count)
                    .onSubmit { step(1, count: matches.count) }
                if player.isAvailable {
                    Toggle("Follow playback", isOn: $follow).toggleStyle(.switch).controlSize(.mini)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
            if record.utterances.isEmpty {
                DetailEmptyState(symbol: "text.bubble", title: record.status == .written ? "No speech detected" : "No transcript yet",
                                 message: record.status == .written ? "The call was recorded, but nobody spoke." : "The transcript appears when processing is done.")
            } else {
                ScrollViewReader { proxy in
                    let breaks = record.transcriptMarkers
                    ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(blocks) { block in
                            let previousEnd = blocks.last { $0.id < block.id }?.end ?? -1
                            ForEach(Array(breaks.filter { $0.offset > previousEnd && $0.offset <= block.start }.enumerated()), id: \.offset) { _, line in
                                MarkerLine(text: line.text)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Circle().fill(people.color(forKey: block.speakerKey)).frame(width: 7, height: 7)
                                    Text(block.speaker).font(.system(size: 12, weight: .semibold)).foregroundStyle(people.color(forKey: block.speakerKey))
                                }
                                .padding(.top, 6)
                                ForEach(Array(block.lines.enumerated()), id: \.offset) { i, line in
                                    let id = LineID(block: block.id, line: i)
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Button(clock(line.start)) { player.play(from: line.start) }
                                            .buttonStyle(.plain)
                                            .font(.system(size: 11)).monospacedDigit()
                                            .foregroundStyle(player.isAvailable ? Color.accentColor : .secondary)
                                            .frame(width: 44, alignment: .leading)
                                            .disabled(!player.isAvailable)
                                            .help(player.isAvailable ? "Play from here" : "The audio is not available")
                                        Text(highlighted(line.text, active: matches.indices.contains(matchIndex) && matches[matchIndex] == id))
                                            .font(.system(size: 13)).lineSpacing(3)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(id == current ? Theme.field : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .padding(.horizontal, -10)
                                    .id(id)
                                }
                            }
                        }
                    }
                    ForEach(Array(breaks.filter { $0.offset > (blocks.last?.end ?? -1) }.enumerated()), id: \.offset) { _, line in
                        MarkerLine(text: line.text)
                    }
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, 24)
                    .frame(maxWidth: maxWidth)
                    .frame(maxWidth: .infinity)
                    }
                    .onChange(of: current) { _, line in
                        guard follow, player.isPlaying, let line else { return }
                        withAnimation { proxy.scrollTo(line, anchor: .center) }
                    }
                    .onChange(of: matchIndex) { _, i in
                        if matches.indices.contains(i) { withAnimation { proxy.scrollTo(matches[i], anchor: .center) } }
                    }
                    .onChange(of: find) { _, _ in
                        matchIndex = 0
                        if let first = matches.first { proxy.scrollTo(first, anchor: .center) }
                    }
                }
            }
        }
    }

    private func findField(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
            TextField("Find in transcript", text: $find).textFieldStyle(.plain)
            if !find.isEmpty {
                Text(count == 0 ? "0 of 0" : "\(matchIndex + 1) of \(count)")
                    .foregroundStyle(count == 0 ? .tertiary : .secondary).monospacedDigit()
                Button { step(-1, count: count) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain).keyboardShortcut("g", modifiers: [.command, .shift])
                Button { step(1, count: count) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain).keyboardShortcut("g", modifiers: .command)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(width: 240, height: 26)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func step(_ by: Int, count: Int) {
        guard count > 0 else { return }
        matchIndex = (matchIndex + by + count) % count
    }

    /// One entry per line that contains the term, in reading order.
    private func matches(_ blocks: [TranscriptBlock]) -> [LineID] {
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
            result[range].backgroundColor = active ? .orange : .yellow
            result[range].foregroundColor = .black
            search = range.upperBound..<result.endIndex
        }
        return result
    }

    /// The last line that starts at or before the play position.
    private func currentLine(_ blocks: [TranscriptBlock]) -> LineID? {
        var found: LineID?
        for block in blocks where block.start <= player.time {
            for (i, line) in block.lines.enumerated() where line.start <= player.time { found = LineID(block: block.id, line: i) }
        }
        return found
    }
}

/// A pause, a stop, or a join, drawn across the transcript.
private struct MarkerLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.separator).frame(height: 1)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).fixedSize()
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}
