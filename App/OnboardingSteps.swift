import AppKit
import MossadCore
import SwiftUI

// MARK: Shared parts

/// A group of a step: a small label, then rows divided by hairlines, then an optional quiet note.
struct StepGroup<Content: View>: View {
    let label: String
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).textRole(.label).foregroundStyle(Palette.tertiary).padding(.bottom, Space.s)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        row.frame(maxWidth: .infinity, alignment: .leading).hairline(.bottom)
                    }
                }
            }
            .hairline(.top)
            if let footer { SettingsFootnote(text: footer) }
        }
    }
}

/// One line with the canvas's icon in the accent before it.
struct IconLine: View {
    let icon: Icon
    let text: String
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            IconImage(icon, size: 16).foregroundStyle(Palette.accent)
                .frame(width: 32, height: 32)
                .background(Palette.accentTint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Palette.ink)
                    .cssLineHeight(size: 13.5)
                if let detail {
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                        .cssLineHeight(1.45, size: 12.5)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 1)
        }
        .padding(.vertical, Onboard.rowPadding)
        .accessibilityElement(children: .combine)
    }
}

/// A green check and a few words: "Key works", "Mossad heard the tone".
struct PassLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            IconImage(.checkSmall, size: 12).foregroundStyle(Palette.ok)
            Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.okText)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: 1. Welcome

struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl + 4) {
            StepGroup(label: "What Mossad does") {
                IconLine(icon: .waveform, text: "It notices your Zoom, Google Meet, and Teams calls, and records them.",
                         detail: "Your microphone and the call's audio, as two tracks.")
                IconLine(icon: .document, text: "After each call it writes the note for you.",
                         detail: "The transcript with names, a short summary, your action items, and the decisions.")
                IconLine(icon: .sparkle, text: "You do nothing.",
                         detail: "No buttons to press during a call, and no reminders.")
            }
            StepGroup(label: "Your privacy") {
                IconLine(icon: .lock, text: "Audio stays on this Mac.",
                         detail: "Only your transcription service gets it, to make the transcript.")
                IconLine(icon: .people, text: "Voice fingerprints never leave this Mac.",
                         detail: "Mossad uses them to put names on voices in later calls.")
                IconLine(icon: .key, text: "Your keys live in the macOS Keychain.",
                         detail: "Mossad never shows them again, logs them, or writes them to a file.")
            }
        }
    }
}

// MARK: 2. You

struct YouStep: View {
    @EnvironmentObject var controller: AppController
    @AppStorage("ownerEmail") private var ownerEmail = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.l, verticalSpacing: Space.l) {
                field("Your name", note: "Required", text: $controller.ownerName, prompt: "First and last name",
                      help: "Your lines in each note carry this name.")
                    .focused($focused)
                field("Work email", note: nil, text: $ownerEmail, prompt: "you@example.com",
                      help: "Mossad finds you in meeting invites with it, and picks your own calendars.")
                field("Company", note: "Optional", text: $controller.organization, prompt: "Example Inc.",
                      help: "Tells your colleagues from other people in the notes.")
            }
        }
        .onAppear { focused = controller.ownerName.isEmpty }
        .onDisappear { controller.rebuildPipeline() }
    }

    private func field(_ title: String, note: String?, text: Binding<String>, prompt: String, help: String) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                if let note { Text(note).font(.system(size: 11.5)).foregroundStyle(Palette.tertiary) }
            }
            .frame(width: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                TextField(title, text: text, prompt: Text(prompt)).textFieldStyle(SheetFieldStyle())
                    .frame(maxWidth: 380)
                Text(help).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: 3. Permissions

struct PermissionsStep: View {
    @EnvironmentObject var permissions: PermissionsMonitor

    private var items: [PermissionsMonitor.Item] {
        let order = OnboardingPermissions.ordered(permissions.items.map(\.kind))
        return order.compactMap { kind in permissions.items.first { $0.kind == kind } }
    }

    var body: some View {
        let missing = items.filter { !$0.state.isGood }.map(\.kind)
        let lines = OnboardingPermissions.whatWillNotWork(missing: missing)
        VStack(alignment: .leading, spacing: Space.xl) {
            StepGroup(label: "Permissions") {
                ForEach(items) { PermissionStepRow(item: $0) { permissions.fix($0) } }
            }
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("You can continue now. Until you allow them:")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.ink)
                    ForEach(lines, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                            Circle().fill(Palette.tertiaryMark).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                            Text(line).font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.opacity)
            }
        }
        .animation(.snappy, value: missing.count)
    }
}

/// A permission: its mark, what it is for, Required or Recommended, and the one action that gets it.
private struct PermissionStepRow: View {
    let item: PermissionsMonitor.Item
    let fix: (PermissionsMonitor.Item) -> Void

    var body: some View {
        let required = OnboardingPermissions.isRequired(item.kind)
        HStack(spacing: Space.m) {
            Group {
                if item.state.isGood {
                    Circle().fill(Palette.ok.opacity(0.16)).overlay { IconImage(.checkSmall, size: 11).foregroundStyle(Palette.okText) }
                } else if required {
                    WarningMark(size: 15).foregroundStyle(Palette.accent)
                } else {
                    Circle().strokeBorder(Palette.ring, lineWidth: 1.5).padding(2)
                }
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Space.s) {
                    Text(item.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Palette.ink)
                    if required { NeedsYouChip(text: "Required") } else { TagChip(text: "Recommended") }
                }
                Text(Self.reason(item.kind, fallback: item.reason)).font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.m)
            action
        }
        .padding(.vertical, Onboard.rowPadding)
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.state.isGood ? "Allowed" : "Not allowed")
    }

    @ViewBuilder
    private var action: some View {
        switch item.state {
        case .granted:
            Text("Allowed").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.okText)
        case .notAsked:
            Button(item.kind == .accessibility ? "Open Settings…" : "Allow…") { fix(item) }
                .buttonStyle(SheetButtonStyle(kind: OnboardingPermissions.isRequired(item.kind) ? .primary : .secondary, compact: true))
                .accessibilityLabel("Allow \(item.title)")
        case .needsApp:
            Button("Open the browser") { fix(item) }.buttonStyle(SheetButtonStyle(kind: .secondary, compact: true))
        case .denied:
            Button("Open Settings…") { fix(item) }
                .buttonStyle(SheetButtonStyle(kind: OnboardingPermissions.isRequired(item.kind) ? .primary : .secondary, compact: true))
                .help("macOS asks only once. Turn Mossad on in this list in System Settings.")
        }
    }

    /// One line on what each permission is for.
    static func reason(_ kind: PermissionKind, fallback: String) -> String {
        switch kind {
        case .microphone: "Records your side of the call."
        case .systemAudio: "Records the other people, from the call app's audio. Nothing else on your Mac."
        case .calendars: "Names each call from its invite and lists who was there."
        case .accessibility: "Reads call window titles, to notice when a Zoom or Teams call starts."
        case .notifications: "Tells you when a new voice needs a name. Nothing during calls."
        case .automation: "Reads the meeting link in the browser tab, to notice Google Meet calls."
        }
    }
}

// MARK: 4. AI

struct AIStep: View {
    @ObservedObject var model: OnboardingModel
    @EnvironmentObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            ProviderKeyBlock(
                model: model,
                label: "Transcription",
                detail: "Turns each call's audio into the transcript. " + controller.transcriptionProvider.note(model: controller.transcriptionModel),
                picker: FillPicker(title: "Transcription provider", selection: $controller.transcriptionProvider,
                                   choices: TranscriptionProvider.allCases.map { ($0, $0.displayName) }),
                service: KeyCheck.Service(controller.transcriptionProvider),
                apiKey: controller.transcriptionProvider.key,
                modelRow: controller.transcriptionProvider.models.count > 1 ? AnyView(
                    FillPicker(title: "Transcription model", selection: $controller.transcriptionModel,
                               choices: controller.transcriptionProvider.models.map { ($0.id, $0.name) }))
                    : AnyView(Text(controller.transcriptionProvider.models.first?.name ?? "Default")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)))
            .onChange(of: controller.transcriptionProvider) { _, p in
                controller.transcriptionModel = p.models.first?.id ?? ""
                controller.rebuildPipeline()
            }
            .onChange(of: controller.transcriptionModel) { _, _ in controller.rebuildPipeline() }
            ProviderKeyBlock(
                model: model,
                label: "Notes",
                detail: ["Writes the summary, the action items, and the coach's notes, and answers in Chat.", controller.aiProvider.note]
                    .compactMap { $0 }.joined(separator: " "),
                picker: FillPicker(title: "Notes provider", selection: $controller.aiProvider,
                                   choices: AIProvider.allCases.map { ($0, $0.displayName) }),
                service: KeyCheck.Service(controller.aiProvider),
                apiKey: controller.aiProvider.key,
                // The same menu as Settings: the provider's own list once its key is saved, with the price.
                modelRow: AnyView(ModelPicker(provider: controller.aiProvider, model: $controller.aiModel)),
                keyless: controller.aiProvider == .localServer ? AnyView(LocalServerSetup(onboarding: true))
                    : controller.aiProvider == .apple ? AnyView(HStack(spacing: Space.s) { PassLine(text: "No key needed"); Spacer(); AppleModelStatus() })
                    : nil)
            .onChange(of: controller.aiModel) { _, _ in controller.rebuildPipeline() }
            .onChange(of: controller.aiProvider) { _, _ in
                controller.aiModel = ""
                controller.rebuildPipeline()
            }
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                IconImage(.analytics, size: 13).foregroundStyle(Palette.tertiaryMark)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                Text(Onboarding.costLine(perHour: Pricing.hourEstimate(transcription: controller.transcriptionProvider,
                                                                       ai: controller.aiProvider, model: controller.aiModel)))
                    .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A provider with its key: the menu, the key field with Paste, "Get a key", and Check with its result.
private struct ProviderKeyBlock<Picker: View>: View {
    @ObservedObject var model: OnboardingModel
    @EnvironmentObject var controller: AppController
    let label: String
    let detail: String
    let picker: Picker
    let service: KeyCheck.Service?
    let apiKey: APIKey?
    /// The model menu, under the provider.
    var modelRow: AnyView? = nil
    /// What shows in place of the key for a provider that needs none, such as the local server's address.
    var keyless: AnyView? = nil
    @State private var typed = ""
    @State private var replacing = false

    var body: some View {
        StepGroup(label: label) {
            HStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Provider").font(.system(size: 13.5, weight: .medium))
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.m)
                picker
            }
            .padding(.vertical, Onboard.rowPadding)
            if let modelRow {
                HStack(spacing: Space.m) {
                    Text("Model").font(.system(size: 13.5, weight: .medium))
                    Spacer(minLength: Space.m)
                    modelRow
                }
                .padding(.vertical, Onboard.rowPadding)
            }
            if let keyless, service == nil { keyless } else { keyRow.padding(.vertical, Onboard.rowPadding) }
        }
        .onChange(of: service) { _, _ in typed = ""; replacing = false }
    }

    @ViewBuilder
    private var keyRow: some View {
        if let service, let apiKey {
            let state = model.keyChecks[service] ?? .idle
            let saved = controller.hasKey(apiKey)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(service.displayName) key").font(.system(size: 13.5, weight: .medium))
                        Link(destination: service.keysPage) {
                            HStack(spacing: 3) {
                                Text("Get a key")
                                IconImage(.arrowUp, size: 10).rotationEffect(.degrees(45))
                            }
                        }
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.accent)
                        .accessibilityLabel("Get a \(service.displayName) key on its website")
                    }
                    Spacer(minLength: Space.m)
                    if saved, !replacing, state != .checking {
                        if state == .passed { PassLine(text: "Key works") } else {
                            Text("Key saved").font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                        }
                        if state != .passed {
                            Button("Check") { model.check(service, key: controller.keychain.get(apiKey) ?? "", as: apiKey, controller: controller) }
                                .buttonStyle(SheetButtonStyle(kind: .secondary, compact: true))
                                .help("Tries the saved key with one free request.")
                        }
                        Button("Change") { replacing = true; typed = "" }.buttonStyle(SheetButtonStyle(kind: .secondary, compact: true))
                    } else {
                        SecureField("\(service.displayName) key", text: $typed, prompt: Text("Paste the key"))
                            .textFieldStyle(SheetFieldStyle(monospaced: true))
                            .frame(width: 250)
                            .onSubmit(check)
                        Button("Paste") { typed = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? typed }
                            .buttonStyle(SheetButtonStyle(kind: .secondary, compact: true))
                        Button(action: check) {
                            if state == .checking { ProgressView().controlSize(.small).frame(width: 40) } else { Text("Check") }
                        }
                        .buttonStyle(SheetButtonStyle(kind: .primary, compact: true))
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty || state == .checking)
                    }
                }
                if case .failed(let error) = state {
                    InlineError(error: error)
                }
            }
            .onChange(of: state) { _, s in if s == .passed { replacing = false; typed = "" } }
        } else {
            HStack(spacing: Space.s) {
                PassLine(text: "No key needed")
                Text("It runs on this Mac. The model downloads once, on first use.").font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
            }
        }
    }

    private func check() {
        guard let service, let apiKey else { return }
        model.check(service, key: typed, as: apiKey, controller: controller)
    }
}
