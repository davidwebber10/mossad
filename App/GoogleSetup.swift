import AppKit
import MossadCore
import SwiftUI

/// The Google step: the owner's own Google app, made in Google Cloud with the numbered steps, then pasted here and
/// checked. Setup and Settings › Google show the same rows, each in its own groups. Optional: Mossad works without it.

/// Setup's step.
struct GoogleStep: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            StepGroup(label: "Your account") { GoogleAudienceRow() }
            StepGroup(label: "In Google Cloud", footer: "About 5 minutes, once. Each link opens the right page in your browser.") {
                GoogleGuideRows()
            }
            StepGroup(label: "Your Google app", footer: "The client ID, the secret, and the sign-in stay in the macOS Keychain. Mossad only reads.") {
                GoogleClientRows()
                GooglePartRows()
            }
        }
    }
}

/// Settings › Google.
struct GoogleSettings: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        let connector = controller.googleConnector
        VStack(alignment: .leading, spacing: Space.xl) {
            SettingsGroup(label: "Your Google app", footer: "The client ID, the secret, and the sign-in stay in the macOS Keychain. Mossad only reads, and works without Google.") {
                GoogleClientRows()
            }
            SettingsGroup(label: "What Mossad reads", footer: "A part you turn off is asked for no more at the next Check.") {
                GooglePartRows()
            }
            if controller.googleConnected, connector.scopes.contains(.calendar), connector.scopes.contains(.docs) {
                SettingsGroup(label: "Gemini notes", footer: "Every 15 minutes Mossad looks at the meetings of the last 2 days. A meeting you did not record becomes a meeting with Gemini's transcript and Mossad's own summary, marked \"Gemini notes\". A recorded meeting keeps its own transcript and gets the link. Meetings you declined are left out. The coach does not review these meetings.") {
                    GooglePastNotesRows()
                }
            }
            if !controller.googleConnected || connector.phase != .idle {
                SettingsGroup(label: "Your account") { GoogleAudienceRow() }
                SettingsGroup(label: "In Google Cloud") { GoogleGuideRows() }
            }
        }
    }
}

/// Internal or External, with what it means.
struct GoogleAudienceRow: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.rowStyle) private var style

    var body: some View {
        let connector = controller.googleConnector
        ChoiceRow(title: "Who signs in", detail: connector.audience.detail) {
            FillPicker(title: "Who signs in", selection: Binding(get: { connector.audience }, set: { connector.audience = $0 }),
                       choices: GoogleSetupGuide.Audience.allCases.map { ($0, $0.title) })
        }
    }
}

/// The numbered steps in Google Cloud, each with its links and the values to copy.
struct GoogleGuideRows: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        let connector = controller.googleConnector
        ForEach(GoogleSetupGuide.steps(audience: connector.audience, scopes: connector.scopes)) { step in
            GoogleGuideStepRow(step: step)
        }
    }
}

private struct GoogleGuideStepRow: View {
    let step: GoogleSetupGuide.Step
    @Environment(\.rowStyle) private var style

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Text("\(step.number)")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.accent)
                .frame(width: 20, height: 20)
                .background(Palette.accentTint, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                SettingsRowText(title: step.title, detail: step.detail)
                    .accessibilityLabel("Step \(step.number), \(step.title). \(step.detail)")
                HStack(spacing: Space.m) {
                    ForEach(step.links, id: \.url) { link in
                        RowLink(text: link.title, destination: link.url, spoken: "Open \(link.title) in Google Cloud")
                    }
                }
                ForEach(step.copies, id: \.value) { copy in GoogleCopyRow(copy: copy) }
            }
        }
        .padding(.vertical, style.padding)
    }
}

/// A value to paste in Google Cloud, with its Copy button.
private struct GoogleCopyRow: View {
    let copy: GoogleSetupGuide.Copy
    @State private var copied = false
    @Environment(\.rowStyle) private var style

    var body: some View {
        HStack(spacing: Space.s) {
            Text(copy.label).font(.system(size: style.detailSize)).foregroundStyle(Palette.secondary)
                .frame(minWidth: 110, alignment: .leading)
            Text(copy.value).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.ink)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: Space.s)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copy.value, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(2)); copied = false }
            }
            .rowButton()
            .accessibilityLabel("Copy \(copy.label)")
            .fixedSize()
        }
    }
}

/// The client ID and secret: pasted once, then only "Saved", with Change. Neither is shown again.
struct GoogleClientRows: View {
    @EnvironmentObject var controller: AppController
    @State private var id = ""
    @State private var secret = ""
    @State private var replacing = false
    @Environment(\.rowStyle) private var style

    var body: some View {
        let saved = controller.hasKey(.googleClientID) && controller.hasKey(.googleClientSecret)
        if !saved || replacing {
            VStack(alignment: .leading, spacing: 8) {
                SettingsRowText(title: "Client ID and secret", detail: "From the client of step 5. The ID ends with .apps.googleusercontent.com.")
                field("Client ID", text: $id, secure: false)
                field("Client secret", text: $secret, secure: true)
                HStack(spacing: Space.s) {
                    Spacer()
                    if replacing { Button("Cancel") { replacing = false; id = ""; secret = "" }.rowButton() }
                    Button("Save and Check") {
                        controller.checkGoogle(typedID: id, typedSecret: secret)
                        replacing = false
                        id = ""
                        secret = ""
                    }
                    .rowButton(accent: true)
                    .disabled(id.trimmingCharacters(in: .whitespaces).isEmpty || secret.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.vertical, style.padding)
        } else {
            SettingsRow(title: "Client ID and secret", detail: "Saved in the Keychain.") {
                Button("Change") { replacing = true }.rowButton()
                Button("Remove") { controller.forgetGoogleClient() }.rowButton()
            }
        }
        GoogleConnectionRow()
    }

    private func field(_ title: String, text: Binding<String>, secure: Bool) -> some View {
        HStack(spacing: Space.s) {
            Group {
                if secure {
                    SecureField(title, text: text, prompt: Text("Paste the \(title.lowercased())"))
                } else {
                    TextField(title, text: text, prompt: Text("Paste the \(title.lowercased())"))
                }
            }
            .textFieldStyle(SheetFieldStyle(monospaced: true))
            .accessibilityLabel(title)
            Button("Paste") { text.wrappedValue = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? text.wrappedValue }
                .rowButton()
                .accessibilityLabel("Paste the \(title.lowercased())")
        }
    }
}

/// The sign-in: who is connected, Check, Sign out, and what the last Check found for each part.
struct GoogleConnectionRow: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.rowStyle) private var style

    var body: some View {
        let connector = controller.googleConnector
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Space.m) {
                SettingsRowText(title: "Google account", detail: status)
                Spacer(minLength: Space.m)
                if controller.googleConnected {
                    Button("Sign out") { controller.signOutOfGoogle() }.rowButton().disabled(connector.busy)
                }
                Button {
                    controller.checkGoogle()
                } label: {
                    if connector.busy { ProgressView().controlSize(.small).frame(width: 40) } else { Text(controller.googleConnected ? "Check" : "Sign in and Check") }
                }
                .rowButton(accent: !controller.googleConnected)
                .disabled(connector.busy || !(controller.hasKey(.googleClientID) && controller.hasKey(.googleClientSecret)))
                .help("Signs in with Google in your browser when needed, then reads one event.")
            }
            result
        }
        .padding(.vertical, style.padding)
    }

    private var status: String {
        switch controller.googleConnector.phase {
        case .signingIn: return "Finish the sign-in in your browser."
        case .checking: return "Reading one event…"
        default:
            if let account = controller.googleAccount { return "Connected as \(account)." }
            return controller.googleConnected ? "Connected." : "Not connected. Mossad uses your Mac's calendars."
        }
    }

    @ViewBuilder
    private var result: some View {
        switch controller.googleConnector.phase {
        case .done(let report):
            VStack(alignment: .leading, spacing: 4) {
                if let event = report.event { PassLine(text: "Read \"\(event)\"") }
                ForEach(GoogleScope.allCases.filter { report.parts[$0] != nil }) { scope in
                    if let error = report.parts[scope] ?? nil {
                        GoogleErrorLine(error: error, part: scope.title)
                    } else if scope != .calendar || report.event == nil {
                        PassLine(text: "\(scope.title) works")
                    }
                }
            }
        case .failed(let error):
            GoogleErrorLine(error: error, part: nil)
        default:
            EmptyView()
        }
    }
}

/// A failed part: what went wrong and what to do, in plain words.
struct GoogleErrorLine: View {
    let error: GoogleError
    let part: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            WarningMark(size: 12).foregroundStyle(Palette.accent)
            Text("\(Text((part.map { "\($0): " } ?? "") + error.title).fontWeight(.semibold).foregroundStyle(Palette.ink))\(Text(". " + error.advice).foregroundStyle(Palette.secondary))")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A switch for each part. A change takes effect at the next Check, which signs in again with the new parts.
struct GooglePartRows: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        let connector = controller.googleConnector
        ForEach(GoogleScope.allCases) { scope in
            SettingsSwitchRow(title: scope.title, detail: detail(scope),
                              isOn: Binding(get: { connector.scopes.contains(scope) }, set: { on in
                                  if on { connector.scopes.insert(scope) } else { connector.scopes.remove(scope) }
                                  controller.objectWillChange.send()
                              }))
        }
    }

    private func detail(_ scope: GoogleScope) -> String {
        let pending = controller.google.isConnected && controller.google.scopes.contains(scope) != controller.googleConnector.scopes.contains(scope)
        return scope.detail + (pending ? " Press Check to apply." : "")
    }
}

/// Old notes: how far back, what was found and what it costs, the cap, and Import.
struct GooglePastNotesRows: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.rowStyle) private var style

    var body: some View {
        let c = controller.googleConnector
        ChoiceRow(title: "Old notes", detail: "Import the notes of past meetings once. Mossad's summary costs about $0.02 a meeting, billed to your AI provider.") {
            HStack(spacing: Space.s) {
                FillPicker(title: "How far back", selection: Binding(get: { c.pastDays }, set: { c.pastDays = $0; c.pastPlan = nil }),
                           choices: [(30, "Last 30 days"), (90, "Last 90 days"), (180, "Last 6 months"), (365, "Last year")])
                Button {
                    controller.findPastNotes()
                } label: {
                    if c.pastSearching { ProgressView().controlSize(.small).frame(width: 40) } else { Text("Look") }
                }
                .rowButton()
                .disabled(c.pastSearching || c.pastImport != nil)
            }
        }
        if let line = c.pastLine {
            VStack(alignment: .leading, spacing: 8) {
                Text(line).font(.system(size: style.detailSize)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: Space.s) {
                    Text("Spend at most").font(.system(size: style.detailSize)).foregroundStyle(Palette.secondary)
                    TextField("Cap", value: Binding(get: { c.pastCap }, set: { c.pastCap = max(0, $0) }), format: .currency(code: "USD"))
                        .textFieldStyle(SheetFieldStyle())
                        .frame(width: 90)
                        .accessibilityLabel("The most to spend on summaries")
                    Spacer()
                    if let progress = c.pastImport {
                        Text("Importing \(progress.done) of \(progress.total)").font(.system(size: style.detailSize)).foregroundStyle(Palette.secondary)
                    } else {
                        let count = GeminiImport.capped(c.pastPlan ?? [], dollars: c.pastCap).count
                        Button("Import \(count)") { controller.importPastNotes() }
                            .rowButton(accent: true)
                            .disabled(count == 0 || controller.isRecording)
                    }
                }
            }
            .padding(.vertical, style.padding)
        }
        if let result = c.pastResult {
            Text(result).font(.system(size: style.detailSize)).foregroundStyle(Palette.secondary)
                .padding(.vertical, style.padding)
        }
    }
}
