import AppKit
import MossadCore
import SwiftUI

/// One meeting: header, player, and Summary and Transcript tabs. Clicking a time in the transcript plays from there.
struct MeetingDetailView: View {
    enum Tab: String, CaseIterable { case summary = "Summary", transcript = "Transcript" }

    @EnvironmentObject var controller: AppController
    let record: CallRecord
    @Binding var deleting: CallRecord?
    @StateObject private var player: AudioPlayer
    @State private var tab = Tab.summary

    init(record: CallRecord, deleting: Binding<CallRecord?>, audioDirectory: URL) {
        self.record = record
        _deleting = deleting
        _player = StateObject(wrappedValue: AudioPlayer(callDirectory: audioDirectory))
    }

    var body: some View {
        let colors = SpeakerColors(record)
        VStack(spacing: 0) {
            header(colors)
            if record.status != .written { statusBanner }
            if player.isAvailable, record.status != .recording {
                Divider()
                PlayerBar(player: player)
            }
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .padding(.vertical, 10)
            switch tab {
            case .summary: SummaryTab(record: record, colors: colors)
            case .transcript: TranscriptTab(record: record, colors: colors, player: player)
            }
        }
    }

    private func header(_ colors: SpeakerColors) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.title).font(.title2.bold()).textSelection(.enabled)
                Spacer()
                if !record.unknownSpeakers.isEmpty, record.status == .written {
                    Button("Name voices") { controller.namingCallID = record.id }
                }
                Menu {
                    if let path = record.markdownPath {
                        Button("Open note") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                        Button("Show note in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    }
                    Button("Show audio in Finder") { NSWorkspace.shared.open(controller.paths.callDirectory(record.id)) }
                    Divider()
                    Button("Delete…", role: .destructive) { deleting = record }.disabled(!record.canDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Text(subtitle).foregroundStyle(.secondary)
            if !colors.order.isEmpty {
                HStack(spacing: 12) {
                    ForEach(colors.order, id: \.self) { name in
                        Label {
                            Text(name)
                        } icon: {
                            Circle().fill(colors[name]).frame(width: 8, height: 8)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        let date = record.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        let times = "\(record.start.formatted(date: .omitted, time: .shortened)) – \(record.end.formatted(date: .omitted, time: .shortened))"
        let minutes = max(1, Int(record.end.timeIntervalSince(record.start) / 60))
        return "\(date) · \(times) · \(minutes) min · \(record.platform.displayName)"
    }

    private var statusBanner: some View {
        HStack {
            Image(systemName: record.status == .failed ? "exclamationmark.triangle.fill" : "hourglass")
                .foregroundStyle(record.status == .failed ? .orange : .secondary)
            Text(statusText).foregroundStyle(.secondary)
            Spacer()
            if record.attempts > 0 || record.status == .failed { Button("Retry now") { controller.retry(record.id) } }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5))
    }

    private var statusText: String {
        switch record.status {
        case .recording: "Recording…"
        case .recorded: record.attempts > 0 ? "Transcription failed \(record.attempts)×; Mossad will retry." : "Waiting for transcription…"
        case .transcribed: "Identifying speakers…"
        case .identified: "Writing summary…"
        case .summarized: "Writing file…"
        case .failed where record.attempts == 0: "The recording was interrupted, and a track could not be read. Check the log, then retry."
        case .failed: "Mossad gave up after \(record.attempts) attempts. Check the log, then retry."
        case .written: ""
        }
    }
}

/// A fixed color per speaker, in order of first appearance.
struct SpeakerColors {
    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]
    let order: [String]

    init(_ record: CallRecord) {
        order = TranscriptBlock.blocks(record).reduce(into: [String]()) { names, block in
            if !names.contains(block.speaker) { names.append(block.speaker) }
        }
    }

    subscript(_ speaker: String) -> Color {
        Self.palette[(order.firstIndex(of: speaker) ?? 0) % Self.palette.count]
    }
}

private func clock(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

private struct PlayerBar: View {
    @ObservedObject var player: AudioPlayer
    @State private var scrubbing: TimeInterval?

    var body: some View {
        HStack(spacing: 14) {
            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                .buttonStyle(.borderless).help("Back 15 seconds")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 26))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.space, modifiers: [])
            .help(player.isPlaying ? "Pause" : "Play")
            Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                .buttonStyle(.borderless).help("Forward 15 seconds")
            Slider(value: Binding(get: { scrubbing ?? player.time }, set: { scrubbing = $0 }),
                   in: 0...max(player.duration, 1)) { editing in
                if !editing, let t = scrubbing {
                    player.seek(to: t)
                    scrubbing = nil
                }
            }
            Text("\(clock(scrubbing ?? player.time)) / \(clock(player.duration))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Picker("Speed", selection: $player.rate) {
                ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { Text($0 == 1 ? "1×" : "\($0.formatted())×").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

private struct SummaryTab: View {
    let record: CallRecord
    let colors: SpeakerColors

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let summary = record.summary {
                    card("Summary", systemImage: "text.alignleft") {
                        Text(summary).textSelection(.enabled).lineSpacing(3)
                    }
                    card("Action items", systemImage: "checklist") {
                        if record.actionItems.isEmpty {
                            Text("None.").foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(record.actionItems, id: \.self) { item in
                                    Label { Text(item).textSelection(.enabled) } icon: { Image(systemName: "square").foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                } else if record.status == .written {
                    Text("No summary for this meeting.").foregroundStyle(.secondary)
                }
                let talk = TranscriptBlock.talkTime(record)
                if let longest = talk.first?.seconds, longest > 0 {
                    card("Talk time", systemImage: "chart.bar") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(talk, id: \.speaker) { entry in
                                HStack {
                                    Text(entry.speaker).frame(width: 140, alignment: .leading).lineLimit(1)
                                    GeometryReader { g in
                                        Capsule().fill(colors[entry.speaker].opacity(0.7))
                                            .frame(width: max(4, g.size.width * entry.seconds / longest))
                                    }
                                    .frame(height: 8)
                                    Text(clock(entry.seconds)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                        .frame(width: 60, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
                if !record.attendees.isEmpty {
                    card("Invited", systemImage: "person.2") {
                        Text(record.attendees.joined(separator: ", ")).textSelection(.enabled).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func card(_ title: String, systemImage: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct TranscriptTab: View {
    let record: CallRecord
    let colors: SpeakerColors
    @ObservedObject var player: AudioPlayer
    @State private var filter = ""
    @State private var follow = true

    var body: some View {
        let blocks = TranscriptBlock.blocks(record)
        let shown = filtered(blocks)
        // Filtering renumbers lines, so the highlight only shows on the full transcript.
        let current = filter.isEmpty && (player.isPlaying || player.time > 0) ? currentLine(blocks) : nil
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in transcript", text: $filter).textFieldStyle(.plain)
                Spacer()
                if player.isAvailable { Toggle("Follow playback", isOn: $follow).toggleStyle(.checkbox) }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            Divider()
            if record.utterances.isEmpty {
                ContentUnavailableView("No transcript", systemImage: "text.bubble",
                                       description: Text(record.status == .written ? "Nobody spoke in this call." : "The transcript appears when processing is done."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(shown) { block in blockView(block, current: current) }
                        }
                        .padding(20)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: current) { _, line in
                        guard follow, player.isPlaying, filter.isEmpty, let line else { return }
                        withAnimation { proxy.scrollTo(line, anchor: .center) }
                    }
                }
            }
        }
    }

    private func blockView(_ block: TranscriptBlock, current: LineID?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(colors[block.speaker]).frame(width: 8, height: 8)
                Text(block.speaker).font(.callout.bold()).foregroundStyle(colors[block.speaker])
            }
            ForEach(Array(block.lines.enumerated()), id: \.offset) { index, line in
                let id = LineID(block: block.id, line: index)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button(clock(line.start)) { player.play(from: line.start) }
                        .buttonStyle(.link)
                        .font(.caption.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                        .disabled(!player.isAvailable)
                        .help(player.isAvailable ? "Play from here" : "The audio is not available")
                    Text(line.text).textSelection(.enabled).lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(id == current ? colors[block.speaker].opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .id(id)
            }
        }
    }

    struct LineID: Hashable { let block: Int; let line: Int }

    /// The last line that starts at or before the play position.
    private func currentLine(_ blocks: [TranscriptBlock]) -> LineID? {
        var found: LineID?
        for block in blocks where block.start <= player.time {
            for (i, line) in block.lines.enumerated() where line.start <= player.time { found = LineID(block: block.id, line: i) }
        }
        return found
    }

    private func filtered(_ blocks: [TranscriptBlock]) -> [TranscriptBlock] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return blocks }
        return blocks.compactMap { block in
            var b = block
            b.lines = block.lines.filter { $0.text.localizedCaseInsensitiveContains(q) || block.speaker.localizedCaseInsensitiveContains(q) }
            return b.lines.isEmpty ? nil : b
        }
    }
}
