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
            .environment(\.rowStyle, .setup)
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
                ForEach(items) { item in PermissionRow(item: item) { permissions.fix(item) } }
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

// MARK: 4. AI

struct AIStep: View {
    @ObservedObject var model: OnboardingModel
    @EnvironmentObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            StepGroup(label: ProviderJob.transcription.title) { TranscriptionRows(keys: model.keys) }
            StepGroup(label: ProviderJob.notes.title) { NotesRows(keys: model.keys) }
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                IconImage(.analytics, size: 13).foregroundStyle(Palette.tertiaryMark)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                // The amount that Settings › AI shows, with the live transcript and the coach while they are on.
                Text(Onboarding.costLine(controller.hourCost))
                    .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
