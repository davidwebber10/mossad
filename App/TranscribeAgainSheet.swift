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
            SheetHeader(icon: .waveform, title: "Transcribe “\(record.title)” again",
                        subtitle: "\(dayWord(record.start)), \(record.start.formatted(date: .omitted, time: .shortened)) · \(record.lengthText) · \(record.platform.displayName)")
            VStack(alignment: .leading, spacing: Rhythm.rowGap) {
                Text("Mossad sends the audio to \(controller.transcriptionProvider.displayName) again, names the voices it knows, and writes a new summary and note.")
                    .foregroundStyle(Palette.secondary)
                    .lineSpacing(Rhythm.secondaryLineGap)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 0) {
                    Toggle(isOn: $knowsCount.animation(.snappy)) {
                        VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                            Text("I know how many people spoke").fontWeight(.medium)
                            Text("The exact number gives the best split between voices.")
                                .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary)
                        }
                    }
                    .toggleStyle(SheetSwitchStyle())
                    if knowsCount {
                        HStack(spacing: Space.m) {
                            Text("\(count) \(count == 1 ? "person" : "people")").fontWeight(.semibold).monospacedDigit()
                            Text(room ? "in the room" : "on the call, you included").foregroundStyle(Palette.secondary)
                            Spacer()
                            CountStepper(count: $count, range: 1...30)
                        }
                        .padding(.top, 12)
                        .hairline(.top)
                        .padding(.top, 12)
                        .accessibilityElement(children: .combine)
                        .accessibilityValue("\(count)")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: count = min(30, count + 1)
                            case .decrement: count = max(1, count - 1)
                            @unknown default: break
                            }
                        }
                    }
                }
                .sheetCard(horizontal: 14, vertical: 12)

                VStack(alignment: .leading, spacing: Rhythm.itemGap) {
                    note(.clock) {
                        Text("About \(Pricing.transcribeAgainEstimate(record, tracks: tracks).formatted(.currency(code: "USD")))")
                            .fontWeight(.semibold).foregroundStyle(Palette.ink)
                    }
                    note(.people) { Text("Voice names you gave stay, through the voice library.") }
                    note(.chevronLeft) { Text("Restore previous transcript stays in the More menu.") }
                }
                .font(.system(size: Rhythm.secondarySize))
                .foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            SheetFooter {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.sheetSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Transcribe again") {
                    controller.transcribeAgain(record.id, speakers: knowsCount ? count : nil)
                    dismiss()
                }
                .buttonStyle(.sheetPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .mossadSheet(width: 520)
        .onAppear {
            // Start from the number of voices this transcript found, within reason.
            count = max(2, min(30, Set(record.utterances.map(\.speakerKey)).count))
            // Development hook for screenshots: MOSSAD_TRANSCRIBE_AGAIN=count shows the count turned on.
            if CommandLine.arguments.contains("--ui-preview"), ProcessInfo.processInfo.environment["MOSSAD_TRANSCRIBE_AGAIN"] == "count" {
                knowsCount = true
            }
        }
    }

    private func note<Content: View>(_ icon: Icon, @ViewBuilder _ text: () -> Content) -> some View {
        HStack(spacing: Space.s) {
            IconImage(icon, size: 12).foregroundStyle(Palette.tertiaryMark).frame(width: 16)
                .accessibilityHidden(true)
            text()
        }
    }
}

/// Fewer and More on one fill, with a hairline between them.
private struct CountStepper: View {
    @Binding var count: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 0) {
            step("minus", "Fewer", enabled: count > range.lowerBound) { count -= 1 }
            Hairline(axis: .vertical).frame(height: 26)
            step("plus", "More", enabled: count < range.upperBound) { count += 1 }
        }
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func step(_ symbol: String, _ label: String, enabled: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: Rhythm.noteSize, weight: .semibold))
                .frame(width: 30, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ink)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}
