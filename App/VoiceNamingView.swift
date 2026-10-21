import AVFoundation
import MossadCore
import SwiftUI

/// Name the unknown voices of one call. For each voice: play a sample, pick who it is from the invite
/// (their email), and type the name. Mossad keeps the name with the email for later calls.
struct VoiceNamingView: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.dismiss) private var dismiss
    let record: CallRecord
    @State private var names: [String: String] = [:]
    @State private var emails: [String: String] = [:]
    @State private var player: AVAudioPlayer?
    @State private var playing: String?
    @State private var sampleLengths: [String: TimeInterval] = [:]
    /// Which candidate line each voice's sample comes from, and that line's text.
    @State private var choices: [String: Int] = [:]
    @State private var sampleText: [String: String] = [:]

    var body: some View {
        let people = MeetingPeople(record: record, ownerName: controller.ownerName, library: controller.library)
        let talk = Dictionary(TranscriptBlock.talkTime(record).map { ($0.speaker, $0.seconds) }, uniquingKeysWith: +)
        VStack(alignment: .leading, spacing: 14) {
            Text("Who is speaking?").font(.system(size: 16, weight: .bold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(record.unknownSpeakers, id: \.self) { key in
                        card(key, people: people, talk: talk[people.name(forKey: key)] ?? 0)
                    }
                }
            }
            .frame(maxHeight: 460)
            HStack(spacing: 8) {
                Spacer()
                Button("Later") { dismiss() }
                Button("Save") {
                    controller.applyNames(callID: record.id, names: names, emails: emails)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(names.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(EdgeInsets(top: 20, leading: 20, bottom: 16, trailing: 20))
        .frame(width: 560)
        .task { await measureSamples() }
    }

    private var subtitle: String {
        let n = record.unknownSpeakers.count
        return n == 1
            ? "1 voice in \(record.title) is new. Name it once and Mossad recognizes it in future calls."
            : "\(n) voices in \(record.title) are new. Name them once and Mossad recognizes them in future calls."
    }

    private func card(_ key: String, people: MeetingPeople, talk: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { toggle(key) } label: {
                    Image(systemName: playing == key ? "stop.fill" : "play.fill").font(.system(size: 11)).foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(people.color(forKey: key), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Play a sample of this voice")
                .accessibilityLabel(playing == key ? "Stop sample" : "Play sample")
                Button { nextSample(key) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Theme.field, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Play a different sample")
                .accessibilityLabel("Next sample")
                .disabled(ClipExtractor.candidates(for: key, utterances: record.utterances).count < 2)
                Text(meta(key, people: people, talk: talk)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let quote = sampleText[key] ?? longestLine(of: key) {
                Text("“\(quote)”").italic().font(.system(size: 13)).lineSpacing(3).lineLimit(3)
            }
            HStack(spacing: 8) {
                TextField("Name", text: Binding(get: { names[key, default: ""] }, set: { names[key] = $0 }))
                    .textFieldStyle(.roundedBorder)
                // Pick only when the call's own meeting link matched an invite; a time match can be another meeting.
                if record.hasInviteLink, !record.attendees.isEmpty {
                    Menu {
                        picks(for: key)
                    } label: {
                        Text(emails[key] ?? "Pick")
                    }
                    .fixedSize()
                }
            }
            if let email = emails[key] {
                HStack(spacing: 4) {
                    Image(systemName: "envelope").font(.system(size: 10))
                    Text(email)
                    Button { emails[key] = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
    }

    /// The invite's people. Picking one sets the email, and the saved name for that email when there is one.
    @ViewBuilder
    private func picks(for key: String) -> some View {
        let used = Set(emails.filter { $0.key != key }.values)
        Section("Invited to this meeting") {
            ForEach(record.attendees.filter { !used.contains($0) }, id: \.self) { attendee in
                let saved = attendee.contains("@") ? controller.library.name(forEmail: attendee) : nil
                Button {
                    if attendee.contains("@") {
                        emails[key] = attendee
                        if let saved, names[key, default: ""].isEmpty { names[key] = saved }
                    } else {
                        names[key] = attendee
                    }
                } label: {
                    Text(saved ?? attendee)
                    if saved != nil { Text(attendee) }
                }
            }
        }
    }

    private func meta(_ key: String, people: MeetingPeople, talk: TimeInterval) -> String {
        var parts = [people.name(forKey: key), talk < 60 ? "<1 min" : "\(Int(talk / 60)) min"]
        if let sample = sampleLengths[key] { parts.append("sample \(clock(sample))") }
        let count = ClipExtractor.candidates(for: key, utterances: record.utterances).count
        if count > 1 { parts.append("\((choices[key] ?? 0) % count + 1) of \(count)") }
        return parts.joined(separator: " · ")
    }

    private func longestLine(of key: String) -> String? {
        record.utterances.filter { $0.speakerKey == key }.max { $0.text.count < $1.text.count }?.text
    }

    private func clipURL(_ key: String) -> (source: URL, clip: URL) {
        let dir = controller.paths.callDirectory(record.id)
        return (dir.appendingPathComponent(key.hasPrefix("me:") ? Track.me.fileName : Track.them.fileName),
                dir.appendingPathComponent("clip-\(key.replacingOccurrences(of: ":", with: "-")).caf"))
    }

    /// Makes the clips when the sheet opens, off the main actor, to show each sample's length.
    private func measureSamples() async {
        let jobs = record.unknownSpeakers.map { ($0, clipURL($0)) }
        let utterances = record.utterances
        let lengths = await Task.detached(priority: .userInitiated) { () -> [String: TimeInterval] in
            var result: [String: TimeInterval] = [:]
            for (key, urls) in jobs {
                // Always the first candidate, so the file matches "1 of N" after an earlier session cycled it.
                try? ClipExtractor.clip(for: key, utterances: utterances, source: urls.source, to: urls.clip)
                if let file = try? AVAudioFile(forReading: urls.clip) {
                    result[key] = Double(file.length) / file.fileFormat.sampleRate
                }
            }
            return result
        }.value
        sampleLengths = lengths
    }

    /// Cuts the next candidate line into the clip file and plays it.
    private func nextSample(_ key: String) {
        player?.stop()
        let choice = (choices[key] ?? 0) + 1
        let urls = clipURL(key)
        do {
            if let line = try ClipExtractor.clip(for: key, utterances: record.utterances, source: urls.source, to: urls.clip, choice: choice) {
                choices[key] = choice
                sampleText[key] = line.text
            }
            if let file = try? AVAudioFile(forReading: urls.clip) {
                sampleLengths[key] = Double(file.length) / file.fileFormat.sampleRate
            }
            player = try AVAudioPlayer(contentsOf: urls.clip)
            player?.play()
            playing = key
        } catch {
            Log.error("Clip for \(key) failed: \(error)")
        }
    }

    private func toggle(_ key: String) {
        if playing == key {
            player?.stop()
            playing = nil
            return
        }
        let urls = clipURL(key)
        do {
            if !FileManager.default.fileExists(atPath: urls.clip.path) {
                try ClipExtractor.clip(for: key, utterances: record.utterances, source: urls.source, to: urls.clip)
            }
            player = try AVAudioPlayer(contentsOf: urls.clip)
            player?.play()
            playing = key
        } catch {
            Log.error("Clip for \(key) failed: \(error)")
        }
    }
}
