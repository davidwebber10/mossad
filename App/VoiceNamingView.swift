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
                Text(meta(key, people: people, talk: talk)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let quote = longestLine(of: key) {
                Text("“\(quote)”").italic().font(.system(size: 13)).lineSpacing(3).lineLimit(3)
            }
            HStack(spacing: 8) {
                TextField("Name", text: Binding(get: { names[key, default: ""] }, set: { names[key] = $0 }))
                    .textFieldStyle(.roundedBorder)
                Menu {
                    picks(for: key)
                } label: {
                    Text(emails[key] ?? "Pick")
                }
                .fixedSize()
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

    /// "Invited to this meeting" picks an email (and its saved name); "Known voices" picks a saved person.
    @ViewBuilder
    private func picks(for key: String) -> some View {
        let used = Set(emails.filter { $0.key != key }.values)
        let invited = record.attendees.filter { !used.contains($0) }
        let profiles = controller.library.profiles.filter { !$0.isOwner }
        if !invited.isEmpty {
            Section("Invited to this meeting") {
                ForEach(invited, id: \.self) { attendee in
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
        if !profiles.isEmpty {
            Section("Known voices") {
                ForEach(profiles, id: \.name) { profile in
                    Button {
                        names[key] = profile.name
                        emails[key] = profile.email
                    } label: {
                        Text(profile.name)
                        if let email = profile.email { Text(email) }
                    }
                }
            }
        }
        if invited.isEmpty, profiles.isEmpty {
            Text("No invite or saved voices")
        }
    }

    private func meta(_ key: String, people: MeetingPeople, talk: TimeInterval) -> String {
        var parts = [people.name(forKey: key), talk < 60 ? "<1 min" : "\(Int(talk / 60)) min"]
        if let sample = sampleLengths[key] { parts.append("sample \(clock(sample))") }
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
                if !FileManager.default.fileExists(atPath: urls.clip.path) {
                    try? ClipExtractor.clip(for: key, utterances: utterances, source: urls.source, to: urls.clip)
                }
                if let file = try? AVAudioFile(forReading: urls.clip) {
                    result[key] = Double(file.length) / file.fileFormat.sampleRate
                }
            }
            return result
        }.value
        sampleLengths = lengths
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
