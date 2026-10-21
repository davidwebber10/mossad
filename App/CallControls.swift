import MossadCore
import SwiftUI

/// Pause or resume, stop and keep, or skip and delete the call being recorded.
struct CallControls: View {
    @EnvironmentObject var controller: AppController
    var compact = false
    @State private var confirmSkip = false

    var body: some View {
        HStack(spacing: 8) {
            if controller.isPaused {
                control("Resume", "record.circle", tint: Theme.recording) { controller.resumeCurrentCall() }
            } else {
                control("Pause", "pause.fill", tint: .primary) { controller.pauseCurrentCall() }
            }
            control("Stop", "stop.fill", tint: .primary) { controller.stopCurrentCall() }
                .help("End the recording now and write the note")
            control(confirmSkip ? "Click again to delete" : "Skip and delete", "trash", tint: Theme.recording) {
                if confirmSkip { controller.skipCurrentCall() } else { confirmSkip = true }
            }
            .help("Stop recording and delete this call")
        }
        .onChange(of: controller.isRecording) { _, _ in confirmSkip = false }
    }

    private func control(_ title: String, _ symbol: String, tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: compact ? 12 : 13, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, compact ? 9 : 12).padding(.vertical, compact ? 4 : 6)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// The big switch at the top of Settings, and the "Turn off" menu used in the panel.
struct PowerControl: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: controller.isOn ? "waveform" : "waveform.slash")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(controller.isOn ? Color.accentColor : .secondary)
                .frame(width: 44, height: 44)
                .background((controller.isOn ? Color.accentColor : Color.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.isOn ? "Mossad is on" : "Mossad is off").font(.system(size: 16, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if controller.isOn {
                TurnOffMenu().controlSize(.large)
            } else {
                Button("Turn on") { controller.turnOn() }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.separator))
    }

    private var detail: String {
        if controller.isOn { return "Records Zoom, Google Meet, and Microsoft Teams calls on its own." }
        if let date = controller.offUntilDate { return "No calls are detected or recorded until \(date.formatted(date: .abbreviated, time: .shortened))." }
        return "No calls are detected or recorded until you turn it on."
    }
}

struct TurnOffMenu: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        Menu("Turn off") {
            Button("For 1 hour") { controller.turnOff(until: Date().addingTimeInterval(3600)) }
            Button("Until tomorrow") { controller.turnOff(until: Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400 + 6 * 3600)) }
            Button("For 3 days") { controller.turnOff(until: Date().addingTimeInterval(3 * 86_400)) }
            Button("For 1 week") { controller.turnOff(until: Date().addingTimeInterval(7 * 86_400)) }
            Divider()
            Button("Until I turn it on") { controller.turnOff(until: nil) }
        }
        .fixedSize()
    }
}
