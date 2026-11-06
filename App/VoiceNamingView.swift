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
    /// Voices skipped in this session; saved when the sheet closes with Save or Later.
    @State private var dismissed: Set<String> = []
    /// Voices skipped before that the owner asked to name after all.
    @State private var restored: Set<String> = []

    private var asking: [String] {
        record.unknownSpeakers.filter { !dismissed.contains($0) } + record.skippedSpeakers.filter { restored.contains($0) }
    }

    /// Skipped earlier or in this session, last in the sheet so a wrong Skip can be undone.
    private var skipped: [String] {
        (record.unknownSpeakers.filter { dismissed.contains($0) } + record.skippedSpeakers).filter { !restored.contains($0) }
    }

    var body: some View {
        let people = MeetingPeople(record: record, ownerName: controller.ownerName, library: controller.library)
        let talk = Dictionary(TranscriptBlock.talkTime(record).map { ($0.speaker, $0.seconds) }, uniquingKeysWith: +)
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(symbol: "waveform", title: title, subtitle: subtitle)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(asking, id: \.self) { key in
                        card(key, people: people, talk: talk[people.name(forKey: key)] ?? 0)
                    }
                    if !skipped.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Skipped").textRole(.label).foregroundStyle(Palette.secondary)
                                .padding(.bottom, 4)
                            ForEach(skipped, id: \.self) { key in
                                skippedRow(key, people: people, talk: talk[people.name(forKey: key)] ?? 0)
                            }
                        }
                        .padding(.top, asking.isEmpty ? 0 : 4)
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 400)
            .fixedSize(horizontal: false, vertical: true)
            SheetFooter {
                Text("Skipped voices stay as letters in the transcript.")
                    .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            } trailing: {
                Button("Later") {
                    saveSkips()
                    dismiss()
                }
                .buttonStyle(.sheetSecondary)
                .keyboardShortcut(.cancelAction)
                Button("Save names") {
                    saveSkips()
                    if names.values.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        controller.applyNames(callID: record.id, names: names, emails: emails)
                    }
                    dismiss()
                }
                .buttonStyle(.sheetPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(names.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } && dismissed.isEmpty && restored.isEmpty)
            }
        }
        .mossadSheet(width: 640)
        .task { await measureSamples() }
    }

    /// Skips and restores both save on Later too: they are choices, not names.
    private func saveSkips() {
        if !dismissed.isEmpty { controller.dismissSpeakers(callID: record.id, keys: Array(dismissed)) }
        if !restored.isEmpty { controller.restoreSpeakers(callID: record.id, keys: Array(restored)) }
    }

    private var title: String {
        let n = record.unknownSpeakers.count
        return n == 0 ? "Name voices" : n == 1 ? "Name 1 voice" : "Name \(n) voices"
    }

    private var subtitle: String {
        if record.unknownSpeakers.isEmpty {
            return "\(record.title) · You skipped these voices. Name one and Mossad knows it in later meetings."
        }
        return "\(record.title) · Mossad saves each voice and knows it in later meetings."
    }

    private func playButton(_ key: String, size: CGFloat) -> some View {
        Button { toggle(key) } label: {
            Image(systemName: playing == key ? "stop.fill" : "play.fill")
                .font(.system(size: size * 0.37))
                .foregroundStyle(Palette.window)
                .frame(width: size, height: size)
                .background(Palette.ink, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Play a sample of this voice")
        .accessibilityLabel(playing == key ? "Stop sample" : "Play sample")
    }

    private func card(_ key: String, people: MeetingPeople, talk: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                playButton(key, size: 30)
                Button { nextSample(key) } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 26, height: 26)
                        .background(Palette.fill, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Play a different sample")
                .accessibilityLabel("Next sample")
                .disabled(ClipExtractor.candidates(for: key, utterances: record.utterances).count < 2)
                Text(people.name(forKey: key)).fontWeight(.semibold).foregroundStyle(Palette.accent)
                Circle().fill(people.color(forKey: key)).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(meta(key, talk: talk)).font(.system(size: 12)).foregroundStyle(Palette.secondary).monospacedDigit()
                Spacer()
                Button("Skip") {
                    if restored.contains(key) { restored.remove(key) } else { dismissed.insert(key) }
                    names[key] = nil
                    emails[key] = nil
                    if playing == key { player?.stop(); playing = nil }
                }
                .buttonStyle(.sheetText)
                .help("Stop asking for this voice. Its lines stay in the transcript.")
            }
            if let quote = sampleText[key] ?? longestLine(of: key) {
                Text("“\(quote)”").italic().foregroundStyle(Palette.secondary).lineSpacing(4).lineLimit(3)
                    .padding(.top, 8)
            }
            HStack(spacing: 8) {
                TextField("Name", text: Binding(get: { names[key, default: ""] }, set: { names[key] = $0 }))
                    .textFieldStyle(SheetFieldStyle())
                // Typed by hand when the invite only lists a group address, or has no invite at all.
                TextField("Email (optional)", text: Binding(get: { emails[key, default: ""] },
                                                            set: { emails[key] = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(SheetFieldStyle())
                    .frame(width: 220)
                // Pick only when the call's own meeting link matched an invite; a time match can be another meeting.
                if record.hasInviteLink, !record.attendees.isEmpty {
                    Menu {
                        picks(for: key)
                    } label: {
                        Text("Pick")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.sheetSecondary)
                    .fixedSize()
                }
            }
            .padding(.top, 10)
            ExistingPersonHint(name: names[key, default: ""], email: emails[key])
                .padding(.top, 8)
        }
        .sheetCard()
    }

    private func skippedRow(_ key: String, people: MeetingPeople, talk: TimeInterval) -> some View {
        HStack(spacing: 10) {
            playButton(key, size: 24)
            Text(people.name(forKey: key)).fontWeight(.medium)
            Circle().fill(people.color(forKey: key)).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(meta(key, talk: talk)).font(.system(size: 12)).foregroundStyle(Palette.secondary).monospacedDigit()
            Spacer()
            Button("Name") {
                if dismissed.contains(key) { dismissed.remove(key) } else { restored.insert(key) }
            }
            .buttonStyle(.sheetText)
            .help("Ask for this voice again")
        }
        .padding(.vertical, 8)
        .hairline(.bottom)
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

    private func meta(_ key: String, talk: TimeInterval) -> String {
        var parts = [talk < 60 ? "<1 min" : "\(Int(talk / 60)) min"]
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
        let jobs = (record.unknownSpeakers + record.skippedSpeakers).map { ($0, clipURL($0)) }
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
