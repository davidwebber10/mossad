import MossadCore
import SwiftUI

/// The meeting band while the call records: the recording chip and who is there, the muted note, the live
/// audio, and the call controls. A room has one mic that hears everyone, so it shows voices, not you and the call,
/// and never the muted note.
struct LiveBand: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    private var room: Bool { record.platform == .inPerson }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RecordingChip(paused: controller.isPaused, room: room)
                LivePeopleLine(model: controller.live, record: record)
            }
            .padding(.top, Space.m)
            if controller.isMuted, !controller.isPaused, !room {
                MutedBanner(platform: record.platform).padding(.top, Space.l)
            }
            Group {
                if room { RoomWaveform(model: controller.live) } else { LiveBandWaveform() }
            }
            .padding(.top, 18)
            CallControls(callID: record.id, start: record.start).padding(.top, 18)
        }
    }
}

/// "Recording" in red with a pulsing dot; "Paused" on the fill.
private struct RecordingChip: View {
    let paused: Bool
    let room: Bool
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 22

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(color: paused ? Palette.tertiaryMark : Palette.recording, size: 8, pulsing: !paused)
            Text(paused ? "Paused" : room ? "In-person meeting" : "Recording")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(paused ? Palette.secondary : Palette.recording)
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(paused ? Palette.fill : Palette.recordingTint, in: Capsule())
    }
}

/// "6 people · Mossad names voices it knows", or in a room "12 speakers so far · 2 not named yet". Its own view,
/// so only this line follows the live transcript's updates.
private struct LivePeopleLine: View {
    @ObservedObject var model: LiveTranscriptModel
    let record: CallRecord

    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
    }

    private var text: String {
        guard record.platform == .inPerson else {
            let n = record.attendees.count
            return (n > 1 ? "\(n) people · " : "") + "Mossad names voices it knows"
        }
        let (total, unnamed) = model.roomVoices
        guard total > 0 else { return "Voices get names as Mossad knows them" }
        return "\(total) \(total == 1 ? "speaker" : "speakers") so far" + (unnamed == 0 ? "" : " · \(unnamed) not named yet")
    }
}

extension LiveTranscriptModel {
    /// The voices heard so far in a room, and how many have no name. A pause starts the labels over, so a named
    /// voice counts once by its name.
    var roomVoices: (total: Int, unnamed: Int) {
        var named = Set<String>(), unnamed = Set<String>()
        for line in visibleLines where line.source == .them {
            guard let key = line.speakerKey else { continue }
            if let name = transcript.names[key] { named.insert(name) } else { unnamed.insert(key) }
        }
        return (named.count + unnamed.count, unnamed.count)
    }
}

/// The room's waveform follows the voices heard: one hue until there is a second voice.
private struct RoomWaveform: View {
    @ObservedObject var model: LiveTranscriptModel

    var body: some View {
        LiveBandWaveform(room: true, voices: model.roomVoices.total)
    }
}

/// Under the band while the call records: the streaming transcript in the label column. The note uses the full
/// transcription after the call.
struct LiveTranscriptPanel: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    var top: CGFloat = Space.xl
    /// A moment from a live chat answer: the line there is scrolled to and marked for a few seconds.
    @Binding var jump: LiveJump?
    @State private var marked: String?
    private var room: Bool { record.platform == .inPerson }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    LabelColumn(label: room ? "Room transcript" : "Live transcript") {
                        Text(note).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if controller.liveTranscriptEnabled {
                        LiveLines(model: controller.live, room: room, paused: controller.isPaused, owner: controller.ownerName, marked: marked)
                    }
                }
                .detailColumn(top: top)
            }
            // Starts at the newest line and stays there as lines arrive.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .task(id: jump) {
                let lines = controller.live.visibleLines
                guard let jump, let i = ChatMoment.index(at: jump.at, in: lines.map(\.time)) else { return }
                // After the first layout, which starts at the newest line.
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation { proxy.scrollTo(lines[i].id, anchor: .center) }
                marked = lines[i].id
                // Used once: a later return to this tab starts at the newest line again.
                self.jump = nil
            }
            .task(id: marked) {
                guard marked != nil else { return }
                try? await Task.sleep(for: .seconds(4))
                withAnimation { marked = nil }
            }
        }
    }

    private var note: String {
        guard controller.liveTranscriptEnabled else {
            return room ? "Recording the room through your microphone. The transcript, with each speaker, and the summary appear after the meeting ends."
                        : "Recording your microphone and the call audio. The transcript and summary appear after the call ends."
        }
        return room ? "Voices get names as Mossad knows them." : "The full transcript, with names, replaces this after the call."
    }
}

/// A moment to show in the live transcript; a new one each time, so the same time can be shown twice.
struct LiveJump: Equatable {
    let at: TimeInterval
    let id = UUID()
}

private struct LiveLines: View {
    @ObservedObject var model: LiveTranscriptModel
    let room: Bool
    let paused: Bool
    let owner: String
    var marked: String?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Space.m) {
            ForEach(model.visibleLines) { line in
                let speaker = who(line)
                LabelColumnRow {
                    HStack(spacing: 7) {
                        Text(speaker.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(speaker.unnamed ? Palette.accent : Palette.ink)
                            .lineLimit(1)
                        Circle().fill(Palette.speaker(speaker.hue)).frame(width: 8, height: 8)
                    }
                    .padding(.top, 1)
                } content: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.text)
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .foregroundStyle(line.isFinal ? Palette.ink : Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(longClock(line.time)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.tertiary)
                    }
                }
                .background {
                    if line.id == marked {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.accent.opacity(0.12)).padding(-6)
                    }
                }
                .id(line.id)
                .accessibilityElement(children: .combine)
            }
            LabelColumnRow { Color.clear.frame(height: 1) } content: {
                Text(paused ? "Paused." : "Listening…").font(.system(size: 13)).foregroundStyle(Palette.tertiary)
            }
        }
        .textSelection(.enabled)
    }

    /// You, a voice's first name once the voice library knows it, else its letter. Unnamed voices are in the accent:
    /// they need a name after the call.
    /// The quick panel's peek uses the same names (`LivePeek.name`).
    private func who(_ line: LiveTranscript.Line) -> (name: String, hue: Int, unnamed: Bool) {
        let name = LivePeek.name(of: line, in: model.transcript, owner: owner, room: room)
        guard line.source == .them, name != "You" || line.speakerKey.flatMap({ model.transcript.names[$0] }) == nil else { return ("You", 0, false) }
        // A letter ("Speaker A2" in a later stream session) needs a name after the call.
        let unnamed = line.speaker != nil && line.speakerKey.flatMap { model.transcript.names[$0] } == nil
        return (name, model.transcript.hue(of: line, owner: owner), unnamed)
    }
}

/// The label column's two parts for a row whose label is not plain text: a name and a dot on the right.
private struct LabelColumnRow<Label: View, Content: View>: View {
    @ViewBuilder let label: Label
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            label.frame(width: LabelColumn<EmptyView>.labelWidth, alignment: .trailing)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
