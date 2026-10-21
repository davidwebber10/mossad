import AVFoundation
import MossadCore
import SwiftUI

/// Name the unknown voices of one call. Each voice has a short clip to play.
struct VoiceNamingView: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.dismiss) private var dismiss
    let record: CallRecord
    @State private var names: [String: String] = [:]
    @State private var player: AVAudioPlayer?

    private var suggestions: [String] {
        Array(Set(record.attendees + controller.library.profiles.map(\.name))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Who is speaking?").font(.title2.bold())
            Text(record.title).foregroundStyle(.secondary)
            ForEach(record.unknownSpeakers, id: \.self) { key in
                HStack(spacing: 12) {
                    Button { play(key) } label: { Image(systemName: "play.circle.fill").font(.title2) }
                        .buttonStyle(.plain)
                        .help("Play a 5-second sample")
                    Text(MarkdownWriter.displayNames(record)[key] ?? key).frame(width: 90, alignment: .leading)
                    TextField("Name", text: Binding(get: { names[key, default: ""] }, set: { names[key] = $0 }))
                        .textFieldStyle(.roundedBorder)
                    Menu("Pick") {
                        ForEach(suggestions, id: \.self) { name in Button(name) { names[key] = name } }
                    }
                    .frame(width: 70)
                    .disabled(suggestions.isEmpty)
                }
                Text(firstLine(of: key)).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.leading, 44)
            }
            HStack {
                Spacer()
                Button("Later") { dismiss() }
                Button("Save") {
                    controller.applyNames(callID: record.id, names: names)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(names.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func firstLine(of key: String) -> String {
        record.utterances.filter { $0.speakerKey == key }.max { $0.text.count < $1.text.count }.map { "“\($0.text)”" } ?? ""
    }

    private func play(_ key: String) {
        let dir = controller.paths.callDirectory(record.id)
        let source = dir.appendingPathComponent(key.hasPrefix("me:") ? Track.me.fileName : Track.them.fileName)
        let clip = dir.appendingPathComponent("clip-\(key.replacingOccurrences(of: ":", with: "-")).caf")
        do {
            if !FileManager.default.fileExists(atPath: clip.path) {
                try ClipExtractor.clip(for: key, utterances: record.utterances, source: source, to: clip)
            }
            player = try AVAudioPlayer(contentsOf: clip)
            player?.play()
        } catch {
            Log.error("Clip for \(key) failed: \(error)")
        }
    }
}
