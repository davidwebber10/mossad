import AppKit
import MossadCore
import ServiceManagement
import SwiftUI

// MARK: 5. Calendars

struct CalendarsStep: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var permissions: PermissionsMonitor

    private var calendarItem: PermissionsMonitor.Item? { permissions.items.first { $0.kind == .calendars } }
    private var sample: Bool { OnboardingSample.isOn }
    private var calendars: [CalendarInfo] { sample ? OnboardingSample.calendars : controller.calendars }
    @State private var sampleChosen: Set<String> = ["work", "team"]

    private func isChosen(_ id: String) -> Bool { sample ? sampleChosen.contains(id) : controller.chosenCalendars.contains(id) }
    private func choose(_ id: String, _ on: Bool) {
        if sample { if on { sampleChosen.insert(id) } else { sampleChosen.remove(id) }; return }
        if on { controller.chosenCalendars.insert(id) } else { controller.chosenCalendars.remove(id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            if !sample, let item = calendarItem, !item.state.isGood {
                HStack(spacing: Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow Calendars first").font(.system(size: 13.5, weight: .semibold))
                        Text("Then choose which calendars Mossad reads. It never changes them.")
                            .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    }
                    Spacer(minLength: Space.m)
                    Button(item.state == .notAsked ? "Allow…" : "Open Settings…") { permissions.fix(item) }
                        .buttonStyle(SheetButtonStyle(kind: .primary, compact: true))
                }
                .padding(Space.l)
                .background(Palette.accentTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                HStack(alignment: .top, spacing: Space.xl) {
                    calendarList.frame(maxWidth: .infinity, alignment: .leading)
                    nextMeeting.frame(width: 250)
                }
            }
        }
        .onAppear { controller.refreshUpcoming() }
        .onChange(of: calendarItem?.state) { _, state in if state == .granted { controller.refreshUpcoming() } }
    }

    private var calendarList: some View {
        StepGroup(label: "Read these calendars", footer: "Your own calendars are checked to start. Shared and holiday calendars stay off.") {
            if calendars.isEmpty {
                Text("No calendars on this Mac yet. Add your work account in System Settings › Internet Accounts.")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Onboard.rowPadding)
            }
            ForEach(Array(Dictionary(grouping: calendars, by: \.account).sorted { $0.key < $1.key }), id: \.key) { account, list in
                VStack(alignment: .leading, spacing: 0) {
                    Text(account.isEmpty ? "On this Mac" : account)
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.secondary)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(list) { c in
                        Toggle(isOn: Binding(get: { isChosen(c.id) }, set: { choose(c.id, $0) })) {
                            Text(c.title).font(.system(size: 13)).foregroundStyle(Palette.ink)
                        }
                        .toggleStyle(SettingsCheckboxStyle())
                        .padding(.vertical, 5)
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }

    /// The next call on the chosen calendars, as Mossad would record it.
    private var nextMeeting: some View {
        let upcoming = sample ? [OnboardingSample.meeting].compactMap { $0 } : controller.upcoming
        let next = upcoming.first { $0.platform != nil } ?? upcoming.first
        return VStack(alignment: .leading, spacing: 0) {
            Text("Next meeting").textRole(.label).foregroundStyle(Palette.tertiary).padding(.bottom, Space.s)
            VStack(alignment: .leading, spacing: 6) {
                if let next {
                    HStack(spacing: 6) {
                        if let platform = next.platform { PlatformDot(platform: platform, hollow: true) }
                        Text(next.start.formatted(.dateTime.weekday(.wide).hour().minute()))
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    }
                    Text(next.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !next.attendees.isEmpty {
                        Text(next.attendees.prefix(4).joined(separator: ", ") + (next.attendees.count > 4 ? ", and \(next.attendees.count - 4) more" : ""))
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                            .lineLimit(2)
                    }
                    Text(next.platform.map { "Mossad records it when the \($0.displayName) call starts, and names the note after this invite." }
                         ?? "This event has no call link. Mossad records it if a call starts at that time.")
                        .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                } else {
                    Text("No meetings in the next \(UpcomingMeeting.days) days on these calendars.")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .hairlineBorder(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: 6. Check

struct CheckStep: View {
    @ObservedObject var model: OnboardingModel
    @EnvironmentObject var permissions: PermissionsMonitor

    private func item(_ kind: PermissionKind) -> PermissionsMonitor.Item? {
        guard let found = permissions.items.first(where: { $0.kind == kind }) else { return nil }
        if OnboardingSample.isOn { var granted = found; granted.state = .granted; return granted }
        return found
    }
    private var preview: Bool { CommandLine.arguments.contains("--ui-preview") }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            micCard
            toneCard
        }
        .onAppear { if !preview, item(.microphone)?.state.isGood == true { model.startMic() } }
        .onDisappear { model.stopMic() }
        .onChange(of: item(.microphone)?.state) { _, state in if state == .granted, !preview { model.startMic() } }
    }

    private var micCard: some View {
        CheckCard(icon: .mic, title: "Your microphone", passed: model.micHeard == true) {
            if item(.microphone)?.state.isGood == false {
                needsPermission("Allow the microphone first.", .microphone)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.micHeard == true ? "Mossad hears you." : "Say something, such as your name.")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    MicMeter(model: model)
                    if let problem = model.micProblem {
                        Text("\(problem). Check that no other app holds the microphone, then come back to this step.")
                            .font(.system(size: 12)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var toneCard: some View {
        CheckCard(icon: .waveform, title: "The other people on the call", passed: model.tone == .heard) {
            if item(.systemAudio)?.state.isGood == false {
                needsPermission("Allow System audio recording first.", .systemAudio)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(toneText).font(.system(size: 12.5)).foregroundStyle(toneFailed ? Palette.accent : Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Space.s) {
                        Button(model.tone == .idle ? "Play test tone" : "Play again") { model.playTone() }
                            .buttonStyle(SheetButtonStyle(kind: model.tone == .heard ? .secondary : .primary, compact: true))
                            .disabled(model.tone == .playing)
                        if model.tone == .playing { ProgressView().controlSize(.small) }
                        if toneFailed, let audio = item(.systemAudio) {
                            Button("Open System Settings…") { NSWorkspace.shared.open(audio.kind.settingsURL) }
                                .buttonStyle(SheetButtonStyle(kind: .secondary, compact: true))
                        }
                    }
                }
            }
        }
    }

    private var toneFailed: Bool {
        switch model.tone {
        case .silent, .failed: true
        default: false
        }
    }

    private var toneText: String {
        switch model.tone {
        case .idle: "Mossad plays a short tone and listens for it, the way it hears a call. Your speakers can be off."
        case .playing: "Playing the tone…"
        case .heard: "Mossad heard the tone. It will hear the other people on your calls."
        case .silent: "Mossad did not hear the tone. In System Settings › Privacy & Security › Screen & System Audio Recording, turn \(Rehearsal.isOn ? "Mossad Rehearsal" : "Mossad") on, then play it again."
        case .failed: "Mossad could not listen to system audio. Check that System audio recording is allowed for \(Rehearsal.isOn ? "Mossad Rehearsal" : "Mossad"), then play it again."
        }
    }

    private func needsPermission(_ text: String, _ kind: PermissionKind) -> some View {
        HStack(spacing: Space.m) {
            Text(text).font(.system(size: 12.5)).foregroundStyle(Palette.accent)
            Spacer(minLength: Space.m)
            if let item = item(kind) {
                Button(item.state == .notAsked ? "Allow…" : "Open Settings…") { permissions.fix(item) }
                    .buttonStyle(SheetButtonStyle(kind: .primary, compact: true))
            }
        }
    }
}

/// A check: an icon tile, a title with pass or fail, then its body.
private struct CheckCard<Content: View>: View {
    let icon: Icon
    let title: String
    let passed: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            IconImage(icon, size: 16).foregroundStyle(passed ? Palette.okText : Palette.accent)
                .frame(width: 32, height: 32)
                .background(passed ? Palette.ok.opacity(0.14) : Palette.accentTint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: Space.s)
                    if passed { PassLine(text: "Works") }
                }
                content
            }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .hairlineBorder(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// The live mic level: 32 bars of the last second and a half, redrawn ten times a second.
private struct MicMeter: View {
    @ObservedObject var model: OnboardingModel
    private static let bars = 32

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let history = model.micCheck.meter.history
            let recent = Array(history.suffix(Self.bars))
            let padded = Array(repeating: Float(0), count: max(0, Self.bars - recent.count)) + recent
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(padded.enumerated()), id: \.offset) { _, level in
                    let f = AudioCheck.meterFraction(level)
                    Capsule().fill(f > 0.33 ? Palette.accentFill : Palette.bar)
                        .frame(width: 4, height: max(4, 28 * f))
                }
            }
            .frame(height: 30, alignment: .center)
            .onChange(of: context.date) { _, _ in model.noteMicLevels(recent) }
        }
        .accessibilityLabel("Microphone level")
    }
}

// MARK: 7. iPhone and sync

struct SyncStep: View {
    @EnvironmentObject var controller: AppController
    @State private var settingUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            StepGroup(label: "Sync to") {
                RadioRow(title: "iCloud", detail: AppController.hasICloud ? "Your Apple devices, through your private iCloud. Nothing to set up." : "Not in this build.",
                         selected: controller.syncWith == .icloud) { controller.chooseSync(.icloud) } trailing: { EmptyView() }
                    .disabled(!AppController.hasICloud)
                RadioRow(title: "Your server", detail: "Your own Cloudflare account. Adds share links and ChatGPT.",
                         selected: controller.syncWith == .server) {
                    if controller.serverConnection == nil { settingUp = true } else { controller.chooseSync(.server) }
                } trailing: {
                    if controller.serverConnection == nil { Text("About 10 minutes").font(.system(size: 12)).foregroundStyle(Palette.tertiary) }
                }
                RadioRow(title: "Don’t sync", detail: "Everything stays on this Mac. The iPhone app gets no meetings.",
                         selected: controller.syncWith == .off) { controller.chooseSync(.off) } trailing: { EmptyView() }
            }
            switch controller.syncWith {
            case .icloud where AppController.hasICloud:
                IconLine(icon: .qr, text: "Get Mossad for iPhone, and sign in with the same Apple Account.",
                         detail: "Finished meetings appear there on their own. Audio stays on this Mac.")
            case .server where controller.serverConnection != nil:
                StepGroup(label: "Your iPhone") { PhonePairingRows() }
            default:
                EmptyView()
            }
        }
        .sheet(isPresented: $settingUp) { ServerSetupSheet() }
    }
}

// MARK: 8. Done

struct DoneStep: View {
    @State private var launchAtLogin = Rehearsal.isOn ? true : SMAppService.mainApp.status == .enabled || !UserDefaults.standard.bool(forKey: "didSetLoginItem")

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            StepGroup(label: "Start") {
                SettingsSwitchRow(title: "Open Mossad at login",
                                  detail: Rehearsal.isOn ? "Shown as new users see it. Rehearsal never opens at login." : "So it is ready for your first call each day.",
                                  isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLogin(on) }
            }
            HStack(alignment: .top, spacing: Space.xl) {
                MenuBarPicture().frame(width: 260)
                VStack(alignment: .leading, spacing: 0) {
                    IconLine(icon: .waveform, text: "Mossad lives in the menu bar.",
                             detail: "Look for the five bars at the top right of your screen. Click them for the menu and your meetings.")
                    IconLine(icon: .meetings, text: "On your next call, there is nothing to do.",
                             detail: "When a call starts, the bars turn red with the time. A few minutes after it ends, the note is in Meetings.")
                }
            }
        }
        .onAppear { if launchAtLogin { setLogin(true) } }
    }

    /// Never in Rehearsal, and never in a UI preview: a preview build would put its own copy in the login items.
    private func setLogin(_ on: Bool) {
        // Only an installed copy: a development build run by hand once put itself in the owner's login items.
        guard !Rehearsal.isOn, !CommandLine.arguments.contains("--ui-preview"),
              Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            UserDefaults.standard.set(true, forKey: "didSetLoginItem")
        } catch {
            Log.error("Launch at login change failed: \(error)")
        }
    }
}

/// A slice of the menu bar with Mossad's bars, so the owner knows what to look for.
private struct MenuBarPicture: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 14) {
                Spacer()
                Image(systemName: "wifi").font(.system(size: 12, weight: .medium))
                Image(nsImage: MenuBarIcon.idle).renderingMode(.template)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Palette.accentTint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.accentFill, lineWidth: 1.5) }
                Image(systemName: "battery.75percent").font(.system(size: 13))
                Text("Mon 9:41").font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 12).frame(height: 30)
            .background(Palette.glass)
            .hairline(.bottom)
            Spacer(minLength: 0)
            Text("Mossad").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent)
                .padding(.trailing, 96).padding(.top, 6)
            Spacer(minLength: 0)
        }
        .frame(height: 96)
        .background(Palette.window.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .hairlineBorder(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Mossad's five bars in the menu bar, near the clock")
    }
}

/// Development hook for screenshots: `MOSSAD_ONBOARDING_SAMPLE=1` in a preview shows made-up calendars and a
/// meeting, and treats the check's permissions as allowed, since a preview build has none of its own.
enum OnboardingSample {
    static let isOn = CommandLine.arguments.contains("--ui-preview") && ProcessInfo.processInfo.environment["MOSSAD_ONBOARDING_SAMPLE"] != nil

    static let calendars = [
        CalendarInfo(id: "work", title: "alex@example.com", account: "Google"),
        CalendarInfo(id: "team", title: "Product team", account: "Google"),
        CalendarInfo(id: "holidays", title: "US Holidays", account: "Google"),
        CalendarInfo(id: "home", title: "Home", account: "iCloud"),
    ]

    static var meeting: UpcomingMeeting? {
        let now = Date()
        let event = CalendarEventInfo(title: "Weekly product review", start: now.addingTimeInterval(5400), end: now.addingTimeInterval(7200),
                                      attendees: ["Alex Rivera", "Sam Carter", "Jordan Lee", "Casey Brooks", "Riley Chen"],
                                      text: "https://meet.google.com/abc-defg-hij", isAllDay: false)
        return UpcomingMeeting.from([event], now: now).first
    }
}
