import AppKit
import MossadCore
import SwiftUI

/// The menu bar panel: one glass pane of 30 pt rows with hairlines between groups. The status row is the only
/// thing with color, and it means state: a neutral dot while waiting, a red pulse while recording.
struct MenuContent: View {
    @ObservedObject var controller: AppController
    @ObservedObject var permissions: PermissionsMonitor
    @Environment(\.dismiss) private var dismiss
    /// The panel stays in memory when closed; it animates only while open.
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusSection
            if controller.processing > 0 { processingRow }
            if controller.cloudSyncing, controller.processing == 0 {
                PanelRow {
                    ProgressView().controlSize(.mini).frame(width: 16)
                    Text("Uploading recordings to the cloud").foregroundStyle(Palette.secondary)
                    Spacer(minLength: 0)
                }
            }
            if !controller.isRecording {
                CoachMoment(compact: true).environmentObject(controller).padding(.horizontal, 6).padding(.vertical, 4)
            }
            let next = controller.upcoming.first { $0.start.timeIntervalSinceNow < 12 * 3600 }
            let recent = Array(controller.meetings.filter { $0.status != .recording }.prefix(3))
            if next != nil || !recent.isEmpty { PanelDivider() }
            if let next {
                PanelHeader(text: "Next")
                PanelRow(action: { go { controller.selectedMeetingID = next.id; controller.open(.meetings) } }) {
                    Group {
                        if let p = next.platform {
                            PlatformDot(platform: p, hollow: true)
                        } else {
                            Circle().strokeBorder(Palette.ring, lineWidth: 1.5).frame(width: 8, height: 8)
                        }
                    }
                    Text(next.title).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text(upcomingWhen(next)).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize()
                    if let link = next.link {
                        Button("Join") { NSWorkspace.shared.open(link); dismiss() }
                            .buttonStyle(PanelCapsuleStyle(height: 22))
                            .accessibilityLabel("Join \(next.title)")
                    }
                }
            }
            if !recent.isEmpty {
                PanelHeader(text: "Recent").padding(.top, next == nil ? 0 : 2)
                ForEach(recent, id: \.id) { r in
                    PanelRow(action: { go { controller.openMeeting(r.id) } }) {
                        PlatformDot(platform: r.platform)
                        Text(r.title).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 6)
                        if r.badge == .needsNames {
                            let n = r.unknownSpeakers.count
                            NeedsYouChip(text: n > 1 ? "\(n) voices" : "Name voices").fixedSize()
                        }
                        Text(panelDay(r.start)).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize()
                    }
                }
            }
            PanelDivider()
            PanelRow(action: { go { controller.open(controller.section) } }) {
                Text("Open Mossad").fontWeight(.medium)
                Spacer()
                Text("⌘O").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            }
            .keyboardShortcut("o")
            if let first = controller.callsNeedingNames.first {
                PanelRow(action: { go { controller.openNaming(first.id) } }) {
                    Text("Name voices")
                    Spacer()
                    Text("\(controller.callsNeedingNames.count)")
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Palette.accentFill, in: Capsule())
                }
                .accessibilityValue("\(controller.callsNeedingNames.count) \(controller.callsNeedingNames.count == 1 ? "call" : "calls")")
            }
            PanelRow(action: {
                go {
                    if !permissions.allGood { UserDefaults.standard.set(SettingsPage.general.rawValue, forKey: "settingsPage") }
                    controller.open(.settings)
                }
            }) {
                Text("Settings")
                Spacer()
                if !permissions.allGood {
                    Circle().fill(Palette.accentFill).frame(width: 7, height: 7)
                }
            }
            .accessibilityValue(permissions.allGood ? "" : permissionsText(permissions.problemCount))
            .help(permissions.allGood ? "" : permissionsText(permissions.problemCount))
            UpdateRow(updater: controller.updater)
            PanelDivider()
            PanelRow(action: { NSApp.terminate(nil) }) {
                Text("Quit Mossad")
                Spacer()
                Text("⌘Q").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            }
            .keyboardShortcut("q")
        }
        .font(.system(size: 13))
        .foregroundStyle(Palette.ink)
        .padding(6)
        .frame(width: 320)
        .environment(\.animationsActive, open)
        .onAppear { open = true }
        .onDisappear { open = false }
        .environmentObject(controller)
    }

    @ViewBuilder
    private var statusSection: some View {
        switch controller.status {
        case .idle where !controller.isOn:
            StatusRow(title: "Mossad is off",
                      detail: controller.offUntilDate.map { "Until \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Until you turn it on") {
                Circle().strokeBorder(Palette.ring, lineWidth: 1.5).frame(width: 8, height: 8)
            } action: {
                Button("Turn on") { controller.turnOn() }.buttonStyle(PanelCapsuleStyle(accent: true))
            }
        case .idle:
            StatusRow(title: "Waiting for a call", detail: "Zoom, Google Meet, Teams, in person") {
                Circle().fill(Palette.inPerson).frame(width: 8, height: 8)
            } action: {
                TurnOffMenu {
                    HStack(spacing: 5) {
                        Text("Turn off")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .panelCapsule()
                }
            }
            PanelRow(action: { controller.recordInPerson() }) {
                Image(systemName: "mic").font(.system(size: 13)).foregroundStyle(Palette.accent).frame(width: 16)
                Text("Record a meeting in person")
                Spacer()
            }
            .help("Records the room through your mic until you click Stop. Use it for meetings without a call app.")
        case .recording(let platform, let since):
            RecordingStatus(platform: platform, since: since)
        }
    }

    private var processingRow: some View {
        PanelRow(action: { go { controller.open(.meetings) } }) {
            ProgressView().controlSize(.mini).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Processing \(controller.processing) \(controller.processing == 1 ? "call" : "calls")")
                if let r = controller.meetings.filter({ ProcessingStep(status: $0.status) != nil }).min(by: { $0.start < $1.start }),
                   let text = controller.progressText(r) {
                    Text(text).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Runs a navigation action and closes the panel.
    private func go(_ action: () -> Void) {
        action()
        dismiss()
    }
}

/// The top row: a dot, what Mossad is doing, a quiet line under it, and the one action as a capsule.
private struct StatusRow<Dot: View, Action: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var dot: Dot
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            dot.frame(width: 8, height: 8).padding(.top, 5).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold).monospacedDigit()
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 6)
            action
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 10))
    }
}

/// While a call records: the red pulse, "Recording · In person · 12:41", who has spoken, Stop, the live
/// talk-share strip, then pause, bookmark, and skip.
private struct RecordingStatus: View {
    @EnvironmentObject var controller: AppController
    let platform: Platform
    let since: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                StatusDot(color: controller.isPaused ? Palette.inPerson : Palette.recording, size: 8, pulsing: !controller.isPaused)
                    .background { if !controller.isPaused { Circle().fill(Palette.recordingTint).frame(width: 16, height: 16) } }
                    .padding(.top, 5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text("\(controller.isPaused ? "Paused" : "Recording") · \(platform.displayName) · \(elapsed(since, context.date))")
                            .fontWeight(.semibold).monospacedDigit().lineLimit(1)
                    }
                    PanelVoicesLine(model: controller.live, platform: platform, title: controller.recordingTitle)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 6)
                Button("Stop") { controller.stopCurrentCall() }
                    .buttonStyle(PanelCapsuleStyle())
                    .help("End the recording now and write the note")
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 10))
            TalkShareStrip(model: controller.live)
            if controller.isMuted, !controller.isPaused {
                MutedBanner(platform: platform, compact: true).padding(.horizontal, 6).padding(.bottom, 6)
            }
            CallControls(compact: true, showsStop: false)
                .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }
}

/// "12 speakers so far, 2 not yet named", or for a call app its title when known.
private struct PanelVoicesLine: View {
    @ObservedObject var model: LiveTranscriptModel
    let platform: Platform
    let title: String?

    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var text: String {
        let (total, unnamed) = model.roomVoices
        let voices = total == 0 ? nil
            : "\(total) \(total == 1 ? "speaker" : "speakers") so far" + (unnamed == 0 ? "" : ", \(unnamed) not yet named")
        if platform == .inPerson { return voices ?? "Voices get names as Mossad knows them" }
        return title ?? voices ?? "Mossad names voices it knows"
    }
}

/// Each voice's share of the talking so far, in its hue, the owner first. It updates with the live transcript.
private struct TalkShareStrip: View {
    @ObservedObject var model: LiveTranscriptModel

    var body: some View {
        let shares = model.transcript.talkShares.filter { $0.seconds > 0 }
        if !shares.isEmpty {
            GeometryReader { g in
                let total = shares.reduce(0) { $0 + $1.seconds }
                let gaps = CGFloat(shares.count - 1)
                HStack(spacing: 1) {
                    ForEach(Array(shares.enumerated()), id: \.offset) { i, share in
                        Rectangle().fill(Palette.speaker(i))
                            .frame(width: max(1, (g.size.width - gaps) * share.seconds / total))
                    }
                }
            }
            .frame(height: 6)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .padding(.horizontal, 12).padding(.bottom, 10)
            .accessibilityElement()
            .accessibilityLabel("Talk share")
            .accessibilityValue(shares.first.map { s in
                s.voice == .owner ? "You \(Int((s.seconds / shares.reduce(0) { $0 + $1.seconds } * 100).rounded())) percent" : "\(shares.count) voices"
            } ?? "")
        }
    }
}

/// "Today", "Yesterday", "Thu" this week, "Oct 9" before.
private func panelDay(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day, days < 7 {
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

func elapsed(_ since: Date, _ now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(since)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// "11:31 AM" today, "Oct 9" before.
func shortTime(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(.dateTime.month(.abbreviated).day())
}

private struct PanelDivider: View {
    var body: some View {
        Hairline().padding(.horizontal, 8).padding(.vertical, 6)
    }
}

private struct PanelHeader: View {
    let text: String

    var body: some View {
        Text(text).textRole(.label).foregroundStyle(Palette.secondary)
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 2, trailing: 12))
            .accessibilityAddTraits(.isHeader)
    }
}

/// A 30 pt row like a menu item, with the selection fill under the pointer.
private struct PanelRow<Content: View>: View {
    var action: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(hovering ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// The panel's capsule buttons: "Turn off", "Stop", "Join".
private struct PanelCapsuleStyle: ButtonStyle {
    var accent = false
    var height: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.panelCapsule(accent: accent, height: height, pressed: configuration.isPressed)
    }
}

private extension View {
    func panelCapsule(accent: Bool = false, height: CGFloat = 24, pressed: Bool = false) -> some View {
        font(.system(size: 12, weight: .semibold))
            .foregroundStyle(accent ? Palette.onAccent : Palette.ink)
            .lineLimit(1)
            .padding(.horizontal, height < 24 ? 9 : 10)
            .frame(height: height)
            .background(accent ? Palette.accentFill : pressed ? Palette.bar : Palette.selection, in: Capsule())
            .contentShape(Capsule())
            .fixedSize()
    }
}

/// "Check for updates…", or a note while an accepted update waits for the call to end.
private struct UpdateRow: View {
    @ObservedObject var updater: Updater

    var body: some View {
        PanelRow(action: { updater.checkForUpdates() }) {
            Text(updater.waitingForCall ? "Update installs after this call" : "Check for updates…")
            Spacer()
        }
        .disabled(!updater.canCheck || updater.waitingForCall)
    }
}
