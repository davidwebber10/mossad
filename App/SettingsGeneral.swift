import AppKit
import MossadCore
import ServiceManagement
import SwiftUI

/// Settings › General: on or off and login, the owner, the shortcuts, permissions, setup, the org chart, and updates.
struct GeneralSettings: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var permissions: PermissionsMonitor
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("ownerEmail") private var ownerEmail = ""
    @AppStorage(CompanyDomainsSheet.key) private var companyDomains = ""
    @State private var editingDomains = false

    /// Setup's order: the two that recording needs, then the ones that make the notes better.
    private var permissionItems: [PermissionsMonitor.Item] {
        OnboardingPermissions.ordered(permissions.items.map(\.kind)).compactMap { kind in permissions.items.first { $0.kind == kind } }
    }

    var body: some View {
        LabelColumnStack {
            SettingsGroup(label: "Mossad") {
                power
                SettingsSwitchRow(title: "Open Mossad at login",
                                  detail: Rehearsal.isOn ? "Rehearsal never opens at login." : "So it is ready for your first call each day.",
                                  isOn: $launchAtLogin)
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
            SettingsGroup(label: "You") {
                SettingsRow(title: "Your name", detail: "Your lines in each note carry it.") {
                    TextField("Your name", text: $controller.ownerName, prompt: Text("First and last name"))
                        .textFieldStyle(SettingsFieldStyle(width: Self.fieldWidth))
                        .onSubmit { controller.rebuildPipeline() }
                }
                SettingsRow(title: "Work email", detail: "Finds you in invites and picks your calendars.") {
                    TextField("Work email", text: $ownerEmail, prompt: Text("you@example.com"))
                        .textFieldStyle(SettingsFieldStyle(width: Self.fieldWidth))
                }
                SettingsRow(title: "Company", detail: "Tells colleagues from other people.", titleNote: "optional") {
                    TextField("Company", text: $controller.organization, prompt: Text("Example Inc."))
                        .textFieldStyle(SettingsFieldStyle(width: Self.fieldWidth))
                        .onSubmit { controller.rebuildPipeline() }
                }
                SettingsRow(title: "Company domains", detail: CompanyDomains.parse(companyDomains).isEmpty ? "None" : CompanyDomains.parse(companyDomains).text,
                            titleNote: "optional") {
                    Button("Edit…") { editingDomains = true }.buttonStyle(.settings)
                }
            }
            ShortcutSettings()
            LabelColumn(label: "Permissions", note: permissions.allGood ? nil : "\(permissions.problemCount) need\(permissions.problemCount == 1 ? "s" : "") attention",
                        labelTopPadding: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(permissionItems) { item in
                        PermissionRow(item: item) { permissions.fix(item) }.hairline(.bottom)
                    }
                    Text("\(Text("Recording consent.").fontWeight(.semibold).foregroundStyle(Palette.ink)) Mossad does not announce itself on calls. Tell the people you meet with that the call is recorded. Some places require the consent of every person on the call. This is not legal advice.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.s)
                }
            }
            SettingsGroup(label: "Setup") {
                SettingsRow(title: "Run setup again", detail: "The same steps as the first launch, from the first one. What you set already stays.") {
                    Button("Open setup…") { controller.runSetupAgain() }.buttonStyle(.settings)
                }
            }
            OrgChartSettings()
                .sheet(isPresented: $editingDomains) { CompanyDomainsSheet() }
                .onAppear {
                    // Development hook for screenshots: MOSSAD_DOMAINS_SHEET opens the company domains.
                    if CommandLine.arguments.contains("--ui-preview"), ProcessInfo.processInfo.environment["MOSSAD_DOMAINS_SHEET"] != nil { editingDomains = true }
                }
            SettingsGroup(label: "Updates", footer: "New versions come from the Mossad releases on GitHub. Each one is signed, and an update never installs during a call.") {
                UpdateRows(updater: controller.updater)
            }
        }
    }

    private static let fieldWidth: CGFloat = 180

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
    }

    private var powerDetail: String {
        if controller.isOn { return "Records Zoom, Google Meet, and Microsoft Teams calls on its own." }
        if let date = controller.offUntilDate { return "No calls are detected or recorded until \(date.formatted(date: .abbreviated, time: .shortened))." }
        return "No calls are detected or recorded until you turn it on."
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
