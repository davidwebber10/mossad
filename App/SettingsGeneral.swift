import AppKit
import MossadCore
import ServiceManagement
import SwiftUI

/// Settings › General: on or off, the owner, permissions, the org chart, and updates.
struct GeneralSettings: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var permissions: PermissionsMonitor
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("ownerEmail") private var ownerEmail = ""

    var body: some View {
        LabelColumnStack {
            LabelColumn(label: "Mossad", labelTopPadding: 10) { power }
            SettingsGroup(label: "You", footer: "Mossad uses your name for your lines in each note, and the company to tell your colleagues from other people.") {
                SettingsRow(title: "Your name") {
                    TextField("Your name", text: $controller.ownerName)
                        .textFieldStyle(SettingsFieldStyle(width: 160))
                        .onSubmit { controller.rebuildPipeline() }
                }
                SettingsRow(title: "Work email", detail: "Finds you in meeting invites.") {
                    TextField("Work email", text: $ownerEmail, prompt: Text("you@example.com"))
                        .textFieldStyle(SettingsFieldStyle(width: 160))
                }
                SettingsRow(title: "Company", titleNote: "optional") {
                    TextField("Company", text: $controller.organization, prompt: Text("Example Inc."))
                        .textFieldStyle(SettingsFieldStyle(width: 160))
                        .onSubmit { controller.rebuildPipeline() }
                }
                SettingsSwitchRow(title: "Open Mossad at login", detail: Rehearsal.isOn ? "Rehearsal never opens at login." : nil, isOn: $launchAtLogin)
                    .disabled(Rehearsal.isOn)
                    .onChange(of: launchAtLogin) { _, on in
                        guard !Rehearsal.isOn else { return }
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            Log.error("Launch at login change failed: \(error)")
                        }
                    }
            }
            LabelColumn(label: "Permissions", note: permissions.allGood ? nil : "\(permissions.problemCount) need\(permissions.problemCount == 1 ? "s" : "") attention",
                        labelTopPadding: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(permissions.items) { item in
                        PermissionRow(item: item) { permissions.fix(item) }.hairline(.bottom)
                    }
                    Text("\(Text("Recording consent.").fontWeight(.semibold).foregroundStyle(Palette.ink)) Mossad does not announce itself on calls. Tell the people you meet with that the call is recorded. Some places require the consent of every person on the call. This is not legal advice.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.s)
                }
            }
            SettingsGroup(label: "Setup", footer: "Walks through the same steps as the first launch: you, permissions, AI keys, calendars, the recording check, and sync. What you set already stays.") {
                SettingsRow(title: "Run setup again", detail: "Opens the setup window from the first step.") {
                    Button("Run setup again…") { controller.runSetupAgain() }.buttonStyle(.settings)
                }
            }
            OrgChartSettings()
            SettingsGroup(label: "Updates", footer: "New versions come from the Mossad releases on GitHub. Each one is signed, and an update never installs during a call.") {
                UpdateRows(updater: controller.updater)
            }
        }
    }

    private var power: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Space.s) {
                    Group {
                        if controller.isOn { Circle().fill(Palette.inPerson) } else { Circle().strokeBorder(Palette.ring, lineWidth: 1.5) }
                    }
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                    Text(controller.isOn ? "Mossad is on" : "Mossad is off")
                        .font(.system(size: 17, weight: .semibold)).tracking(-0.17).foregroundStyle(Palette.ink)
                }
                Text(powerDetail).font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Space.m)
            if controller.isOn {
                TurnOffMenu { FillMenuLabel(text: "Turn off") }
            } else {
                Button("Turn on") { controller.turnOn() }.buttonStyle(.settingsAccent)
            }
        }
        .padding(.top, 6).padding(.bottom, 12)
        .hairline(.bottom)
    }

    private var powerDetail: String {
        if controller.isOn { return "Records Zoom, Google Meet, and Microsoft Teams calls on its own." }
        if let date = controller.offUntilDate { return "No calls are detected or recorded until \(date.formatted(date: .abbreviated, time: .shortened))." }
        return "No calls are detected or recorded until you turn it on."
    }
}

/// A permission: a check and "Granted" when it is, or the accent dot and the one button that fixes it.
private struct PermissionRow: View {
    let item: PermissionsMonitor.Item
    let fix: () -> Void

    var body: some View {
        HStack(spacing: Space.m) {
            Group {
                if item.state.isGood {
                    IconImage(.check, size: 14).foregroundStyle(Palette.secondary)
                } else {
                    Circle().fill(Palette.accentFill).frame(width: 8, height: 8)
                }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
            SettingsRowText(title: item.title, detail: item.reason)
            Spacer(minLength: Space.m)
            if item.state.isGood {
                Text("Granted").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            } else {
                Button(fixLabel, action: fix).buttonStyle(.settingsAccent)
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.state.isGood ? "Granted" : "Not granted")
    }

    private var fixLabel: String {
        switch item.state {
        case .notAsked: "Grant…"
        case .needsApp: "Open browser"
        default: "Open Settings…"
        }
    }
}

/// The imported org chart: its file and counts, Replace, and a way to see it in People. The import sheet is
/// the one People uses.
private struct OrgChartSettings: View {
    @EnvironmentObject var controller: AppController
    @StateObject private var org = OrgState(paths: Paths.live)
    @State private var importing = false
    @State private var profiles: [VoiceProfile] = []
    @State private var stats: [String: PersonStats] = [:]

    var body: some View {
        SettingsGroup(label: "Org chart", footer: "A CSV export from your HR system, with names, titles, and managers. Mossad copies it to the People folder. It stays on this Mac and never syncs.") {
            if let chart = org.chart {
                SettingsRow(title: org.fileName, detail: counts(chart)) {
                    Button("Replace…") { importing = true }.buttonStyle(.settings)
                }
                SettingsRow(title: "See it in People", detail: "Each manager with their team, and the people you meet with outside it.") {
                    Button("Open org chart") {
                        UserDefaults.standard.set(PeopleView.Mode.org.rawValue, forKey: "peopleMode")
                        controller.section = .people
                    }
                    .buttonStyle(.settings)
                }
            } else {
                SettingsRow(title: org.loaded ? "No org chart yet" : "Org chart",
                            detail: "People then shows each person’s title and manager, and your team as a chart.") {
                    Button("Import…") { importing = true }.buttonStyle(.settings).disabled(!org.loaded)
                }
            }
        }
        // The saved matches must be read before the sheet can edit them.
        .onAppear { org.reload() }
        .sheet(isPresented: $importing) {
            OrgImportSheet(org: org, profiles: profiles, stats: stats, owner: controller.ownerName)
        }
        .task(id: importing) {
            guard importing else { return }
            let records = controller.meetings
            stats = await Task.detached(priority: .userInitiated) { PersonStatistics.compute(records) }.value
            profiles = controller.library.profiles
        }
    }

    private func counts(_ chart: OrgChart) -> String {
        let n = chart.people.count
        var parts = ["\(n.formatted()) \(n == 1 ? "person" : "people")", "\(chart.levels) \(chart.levels == 1 ? "level" : "levels")"]
        if let date = org.imported { parts.append("imported \(date.formatted(.dateTime.month(.abbreviated).day()))") }
        return parts.joined(separator: " · ")
    }
}

private struct UpdateRows: View {
    @ObservedObject var updater: Updater

    var body: some View {
        SettingsRow(title: "Version \(updater.version)") {
            Button("Check for Updates…") { updater.checkForUpdates() }.buttonStyle(.settings).disabled(!updater.canCheck)
        }
        if let problem = updater.problem {
            InlineError(error: problem).padding(.vertical, Space.s)
        }
        SettingsSwitchRow(title: "Check for updates automatically",
                          isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
        SettingsSwitchRow(title: "Download and install updates automatically",
                          isOn: Binding(get: { updater.automaticallyInstalls }, set: { updater.automaticallyInstalls = $0 }))
    }
}
