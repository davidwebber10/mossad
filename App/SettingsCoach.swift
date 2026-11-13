import MossadCore
import SwiftUI

/// The coach's settings: reviews on or off and their voice, which emails it sends, and the provider that sends
/// them. The same page is Coach › Settings and Settings › Coach. The focus, the questions, and what the coach
/// knows are pages of Coach.
struct CoachSettings: View {
    @EnvironmentObject var controller: AppController
    @StateObject private var keys = KeyChecker()
    @State private var editingKey: APIKey?
    @State private var sending = false
    /// In Settings, a row that points to the pages of Coach. Not inside Coach itself.
    var showsPagesLink = true

    var body: some View {
        let profile = controller.shownCoachProfile
        LabelColumnStack {
            SettingsGroup(label: "Communication coach",
                          footer: "Reviews use the Notes provider in Settings › AI, now \(controller.aiProvider.displayName). The coach’s notes stay on this Mac, in the Coach folder.") {
                SettingsSwitchRow(title: "Review each call",
                                  detail: "After each note, the coach reviews how you communicated, with advice tied to moments in the call.",
                                  isOn: $controller.coachEnabled)
                    .onChange(of: controller.coachEnabled) { _, on in if on { controller.turnOnCoach() } }
                if controller.coachEnabled {
                    SettingsRow(title: "Voice", detail: profile.voice.detail) {
                        FillPicker(title: "Voice", selection: Binding(get: { profile.voice }, set: { controller.setCoachVoice($0) }),
                                   choices: CoachVoice.allCases.map { ($0, $0.title) })
                    }
                }
            }
            if controller.coachEnabled {
                SettingsGroup(label: "How people think",
                              footer: "A trait shows after 3 calls that agree, or 2 on different topics when the moments are strong. The reads stay on this Mac; a short copy goes to your iPhone through your own server.") {
                    SettingsSwitchRow(title: "Keep a read on each person",
                                      detail: "After each call, one small request finds how each named person decides. Each person's page then says how to present to them.",
                                      isOn: Binding(get: { controller.personaEnabled }, set: { controller.personaEnabled = $0; controller.coachVersion += 1 }))
                    if controller.personaEnabled, let note = controller.personaFillNote {
                        SettingsRow(title: "Your older calls", detail: note) {
                            Button(controller.personaFillYesGives.map { String(format: "Read them, up to $%.2f more", $0) } ?? "Read them") {
                                controller.approvePersonaFill()
                            }
                            .buttonStyle(.settings)
                        }
                    }
                    if controller.personaEnabled {
                        SettingsSwitchRow(title: "Share the reads with other AI apps",
                                          detail: "Apps connected through Mossad's MCP, on this Mac or through your own server, read the traits on each person. Chat in Mossad always can.",
                                          isOn: $controller.personaInMCP)
                            .onChange(of: controller.personaInMCP) { _, _ in controller.syncNow() }
                    }
                }
            }
            if controller.coachEnabled, showsPagesLink {
                SettingsGroup(label: "Coach") {
                    SettingsRow(title: "Findings, goals, and what the coach knows", detail: "These are in Coach, in the sidebar.") {
                        Button("Open Coach") { controller.open(.coach) }.buttonStyle(.settings)
                    }
                }
            }
            SettingsGroup(label: "Emails", footer: "Mossad only ever emails you, at one address.") { emails }
            if controller.coachEnabled, controller.coachEmailEnabled || controller.coachMonthlyEmail {
                SettingsGroup(label: "Email provider") { emailProvider }
            }
        }
        .sheet(item: $editingKey) { key in KeySheet(key: key) }
    }

    /// Which emails the coach sends, and where.
    @ViewBuilder
    private var emails: some View {
        if !controller.coachEnabled {
            SettingsRow(title: "Weekly and monthly emails", detail: "The coach writes these emails. Turn on the coach to send them.") {
                Button("Turn on the coach") { controller.coachEnabled = true; controller.turnOnCoach() }.buttonStyle(.settings)
            }
        } else {
            SettingsSwitchRow(title: "Weekly email on Monday", detail: "What improved in the week, what to work on, and your focus.",
                              isOn: $controller.coachEmailEnabled)
            SettingsSwitchRow(title: "Month in review on the 1st", detail: "The same for the whole month: the change across its weeks.",
                              isOn: $controller.coachMonthlyEmail)
            if controller.coachEmailEnabled || controller.coachMonthlyEmail {
                SettingsRow(title: "Send to",
                            detail: !controller.coachEmailTo.isEmpty && !WeeklyEmail.isSingleAddress(controller.coachEmailTo)
                                ? "Enter one address, your own. Mossad only ever emails you." : nil) {
                    TextField("Send to", text: $controller.coachEmailTo, prompt: Text("you@example.com")).textFieldStyle(SettingsFieldStyle(width: 260))
                }
            }
        }
    }

    /// The service that sends them: the provider, its sender and settings, its key, and a test.
    @ViewBuilder
    private var emailProvider: some View {
        SettingsRow(title: "Provider", detail: "Sends the emails with your own account.") {
            FillPicker(title: "Email provider", selection: $controller.mailProvider, choices: MailProvider.allCases.map { ($0, $0.displayName) })
        }
        SettingsRow(title: "Send from", detail: "Use a sender that you verified with \(controller.mailProvider.displayName).") {
            TextField("Send from", text: $controller.coachEmailFrom, prompt: Text("Mossad <coach@yourdomain.com>")).textFieldStyle(SettingsFieldStyle(width: 260))
        }
        if controller.mailProvider == .mailgun {
            SettingsRow(title: "Sending domain") {
                TextField("Sending domain", text: $controller.mailDomain, prompt: Text("mg.yourdomain.com")).textFieldStyle(SettingsFieldStyle(width: 260))
            }
        }
        if controller.mailProvider == .mailgun || controller.mailProvider == .sendgrid {
            SettingsSwitchRow(title: "Use the EU region", isOn: $controller.mailEurope)
        }
        if controller.mailProvider == .ses {
            SettingsRow(title: "Region") {
                TextField("Region", text: $controller.mailRegion, prompt: Text("us-east-1")).textFieldStyle(SettingsFieldStyle(width: 260))
            }
            SettingsRow(title: "Access key ID") {
                TextField("Access key ID", text: $controller.mailAccessKeyID, prompt: Text("AKIA…")).textFieldStyle(SettingsFieldStyle(width: 260, monospaced: true))
            }
        }
        // No free request tries a mail key: "Send one now" is its check.
        KeyRow(keys: keys, key: controller.mailProvider.key, page: controller.mailProvider.keysPage) { editingKey = $0 }
            .id(controller.mailProvider)
        SettingsRow(title: "Send one now", detail: "To check the address, the sender, and the key.") {
            Menu {
                Button("Last week’s email") { send(.weekly) }
                Button("Last month’s review") { send(.monthly) }
            } label: {
                FillMenuLabel(text: sending ? "Sending…" : "Send now")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .disabled(sending || !WeeklyEmail.isSingleAddress(controller.coachEmailTo) || controller.coachEmailFrom.isEmpty
                      || !controller.hasKey(controller.mailProvider.key))
        }
    }

    private func send(_ kind: CoachEmailKind) {
        sending = true
        Task {
            await controller.sendCoachEmail(kind, now: true)
            sending = false
        }
    }
}

