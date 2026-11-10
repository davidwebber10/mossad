import AppKit
import MossadCore
import SwiftUI

/// Settings › Recording: the live transcript, shared screens, voices, calendars, and folders. How long audio stays
/// is in Storage & Sync.
struct RecordingSettings: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var permissions: PermissionsMonitor
    @State private var confirmDeleteVoices = false

    var body: some View {
        LabelColumnStack {
            SettingsGroup(label: "Recording") {
                SettingsSwitchRow(title: "Live transcript while recording", isOn: $controller.liveTranscriptEnabled)
                    .help("Shows what is said as the call runs, with AssemblyAI streaming. AssemblyAI bills the time a call records with this on. The note still uses the full transcription after the call.")
            }
            if !Rehearsal.isOn {
                SettingsGroup(label: "Shared screens", footer: "Mossad keeps frames of the meeting window only, when its picture changes, and reads their text on this Mac. The frames stay on this Mac. Get consent before you capture what other people share. macOS shows its screen recording mark during a call.") {
                    SettingsSwitchRow(title: "Capture shared screens", isOn: $controller.captureScreens)
                        .help("Keeps pictures of slides and documents that people share in a call, next to the transcript.")
                        .onChange(of: controller.captureScreens) { _, on in
                            if on { permissions.requestScreenCaptureOnce() }
                        }
                    if controller.captureScreens {
                        SettingsRow(title: "Screen & System Audio Recording",
                                    detail: permissions.screenCapture.isGood ? "Allowed" : "Not allowed. Turn Mossad on in System Settings, then open Mossad again if this line does not change.") {
                            if !permissions.screenCapture.isGood {
                                Button("Open System Settings") { permissions.openScreenCaptureSettings() }
                                    .buttonStyle(SettingsButtonStyle(accent: true))
                            }
                        }
                    }
                }
            }
            SettingsGroup(label: "Voices", footer: "Some laws treat voice fingerprints as biometric data. Turn off recognition to keep no fingerprints; speakers are then labeled Speaker A, Speaker B.") {
                SettingsSwitchRow(title: "Recognize voices", isOn: $controller.voiceFingerprints)
                    .help("Mossad saves a voice fingerprint for each person it hears so it can name them in later calls.")
                    .onChange(of: controller.voiceFingerprints) { _, _ in controller.rebuildPipeline() }
                Button("Delete all saved voices…") { confirmDeleteVoices = true }
                    .buttonStyle(SettingsTextButtonStyle(color: Palette.recording, weight: .medium))
                    .font(.system(size: 13))
                    .padding(.vertical, 9)
            }
            SettingsGroup(label: "Calendars", footer: "Mossad reads only the checked calendars, to name calls from their invites and to list upcoming calls.") {
                if controller.calendars.isEmpty {
                    Text("Allow Calendars in General to choose them.")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                        .padding(.vertical, 9)
                }
                ForEach(Array(Dictionary(grouping: controller.calendars, by: \.account).sorted { $0.key < $1.key }), id: \.key) { account, list in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(account.isEmpty ? "On this Mac" : account)
                            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.secondary)
                            .padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(list) { c in
                            Toggle(isOn: Binding(get: { controller.chosenCalendars.contains(c.id) },
                                                 set: { on in
                                                     if on { controller.chosenCalendars.insert(c.id) } else { controller.chosenCalendars.remove(c.id) }
                                                 })) {
                                Text(c.title).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                            }
                            .toggleStyle(SettingsCheckboxStyle())
                            .padding(.vertical, 5)
                        }
                    }
                    .padding(.top, Space.s).padding(.bottom, 4)
                }
            }
            SettingsGroup(label: "Do not record", footer: controller.noRecord.unreadable
                          ? "The do-not-record list could not be read, so calls with an invite are not recorded. Reset the list, or set a choice for any upcoming meeting, to record them again."
                          : "Removes every \"Don't record\" choice you made for upcoming meetings.") {
                Button("Reset do-not-record list") { controller.resetNoRecordList() }
                    .buttonStyle(SettingsTextButtonStyle(color: Palette.recording, weight: .medium))
                    .font(.system(size: 13))
                    .padding(.vertical, 9)
            }
            SettingsGroup(label: "Folders") {
                folderRow("Meetings", controller.paths.meetings)
                folderRow("Audio", controller.paths.audio)
                folderRow("Voices", controller.paths.voices)
            }
        }
        .confirmationDialog("Delete every saved voice?", isPresented: $confirmDeleteVoices) {
            Button("Delete all voices", role: .destructive) { controller.deleteAllVoices() }
        } message: {
            Text("Mossad forgets every voice it learned, including yours. Meeting notes keep their names.")
        }
    }

    private func folderRow(_ title: String, _ url: URL) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
            Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.tertiary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Space.m)
            Button("Open") { NSWorkspace.shared.open(url) }
                .buttonStyle(SettingsTextButtonStyle())
                .accessibilityLabel("Open the \(title) folder")
        }
        .padding(.vertical, 9)
    }
}

/// A checkbox row in Settings: the 14 pt box, then the label.
struct SettingsCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: Space.s) {
                SheetCheckbox(isOn: configuration.isOn).scaleEffect(14 / 16)
                configuration.label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// A row whose checkbox sits on the right, where a switch would.
struct TrailingCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: Space.m) {
                configuration.label
                Spacer(minLength: Space.m)
                SheetCheckbox(isOn: configuration.isOn).scaleEffect(14 / 16)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
