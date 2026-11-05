import MossadCore
import SwiftUI

/// Transcribes a finished meeting again from its audio. It costs money and replaces the transcript, so it asks
/// first, says what it costs, and keeps the current transcript for one undo.
struct TranscribeAgainSheet: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.dismiss) private var dismiss
    let record: CallRecord

    @State private var knowsCount = false
    @State private var count = 2

    private var dir: URL { controller.paths.callDirectory(record.id) }
    private var tracks: Int {
        [Track.me, .them].filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.fileName).path) }.count
    }
    private var room: Bool { record.platform == .inPerson }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.badge.magnifyingglass").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38).background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcribe “\(record.title)” again").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("\(record.start.formatted(date: .abbreviated, time: .shortened)) · \(record.lengthText)").foregroundStyle(.secondary)
                }
            }
            .padding(18)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text("Mossad sends the audio to \(controller.transcriptionProvider.displayName) again, names the voices it knows, and writes a new summary and note.")
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $knowsCount.animation(.snappy)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("I know how many people spoke").font(.system(size: 12, weight: .medium))
                            Text("The exact number gives the best split between voices.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    if knowsCount {
                        Stepper(value: $count, in: 1...30) {
                            Text("\(count) \(count == 1 ? "person" : "people")\(room ? " in the room" : " on the call, you included")")
                                .monospacedDigit()
                        }
                        .padding(.leading, 2)
                    }
                }
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.separator))

                VStack(alignment: .leading, spacing: 6) {
                    Label("About \(Pricing.transcribeAgainEstimate(record, tracks: tracks).formatted(.currency(code: "USD")))", systemImage: "dollarsign.circle")
                    Label("Voice names you gave stay, through the voice library.", systemImage: "person.wave.2")
                    Label("You can go back to the current transcript from the More menu.", systemImage: "arrow.uturn.backward")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Transcribe again") {
                        controller.transcribeAgain(record.id, speakers: knowsCount ? count : nil)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .font(.system(size: 12))
            .padding(18)
        }
        .frame(width: 440)
        .background(Theme.background)
        .onAppear {
            // Start from the number of voices this transcript found, within reason.
            count = max(2, min(30, Set(record.utterances.map(\.speakerKey)).count))
        }
    }
}
