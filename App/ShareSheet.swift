import AppKit
import MossadCore
import SwiftUI

/// Share one meeting by a private link: pick the parts, how long it lasts, then copy the link.
struct ShareSheet: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.dismiss) private var dismiss
    let record: CallRecord

    @State private var options = ShareOptions()
    @State private var link: MeetingLink?
    @State private var working = false
    @State private var error: String?
    @State private var copied = false
    @State private var confirmStop = false

    private var saved: ShareOptions? { link?.options }
    private var changed: Bool { link != nil && saved != options }

    /// Development hook for screenshots: MOSSAD_SHARE=link shows a made-up link on a made-up server, and
    /// MOSSAD_SHARE=none the state with no server.
    private static let preview: String? = CommandLine.arguments.contains("--ui-preview")
        ? ProcessInfo.processInfo.environment["MOSSAD_SHARE"] : nil
    private var hasServer: Bool {
        switch Self.preview {
        case "none": false
        case "link": true
        default: controller.serverConnection != nil
        }
    }

    private func url(_ link: MeetingLink) -> URL? {
        if Self.preview == "link" { return link.url(on: URL(string: "https://notes.example.com")!) }
        return controller.shareURL(link)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(icon: .link, title: "Share “\(record.title)”",
                        subtitle: record.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))
            if hasServer { form } else { noServer }
        }
        .mossadSheet(width: hasServer ? 480 : 420)
        .onAppear {
            link = controller.shareBook.link(for: record.id)
            if Self.preview == "link", link == nil {
                link = MeetingLink(token: "Hq3v9pR2xW7mN4kT2", callID: record.id, title: record.title, options: ShareOptions(),
                                   created: Date(), expires: Date().addingTimeInterval(30 * 86400))
            }
            if let link { options = link.options }
            if !controller.hasRecording(record) { options.recording = false }
        }
        .confirmationDialog("Stop sharing this meeting?", isPresented: $confirmStop) {
            Button("Stop sharing", role: .destructive, action: stop)
        } message: {
            Text("The link stops working at once, and the copy on your server is deleted.")
        }
    }

    private var noServer: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Share links need your own server").fontWeight(.semibold)
                Text("Mossad puts the parts you choose on a small server in your own Cloudflare account and gives you a private link to send. Nobody else runs it, and nobody else can use it.")
                    .foregroundStyle(Palette.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            SheetFooter {
                Button("Cancel") { dismiss() }.buttonStyle(.sheetSecondary).keyboardShortcut(.cancelAction)
                Button("Set up your server…") {
                    UserDefaults.standard.set(SettingsPage.sync.rawValue, forKey: "settingsPage")
                    controller.open(.settings)
                    dismiss()
                }
                .buttonStyle(.sheetPrimary).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                part("Summary and action items", "The overview, topics, decisions, and action items.", .document, $options.summary)
                part("Transcript", "Every line, with names and times.", .meetings, $options.transcript)
                part("Recording", controller.hasRecording(record) ? "The audio, with a player. Tap a line to jump there." : "This meeting has no recording.",
                     .waveform, $options.recording)
                    .disabled(!controller.hasRecording(record))
                part("AI chat", chatDetail, .sparkle, $options.chat)
                    .disabled(!controller.serverHasChat || !(options.summary || options.transcript))

                HStack {
                    Text("Link works for")
                    Spacer()
                    GlassSegmented(selection: $options.days, choices: ShareOptions.expiryChoices.map { d in
                        (value: d, title: d.map { "\($0) days" } ?? "Until I stop it")
                    })
                    .accessibilityLabel("Link works for")
                }
                .padding(.top, 14)

                Label {
                    Text("The coach's review is never shared. People with the link can copy what they see.")
                } icon: {
                    IconImage(.lock, size: 12).foregroundStyle(Palette.tertiaryMark)
                }
                .font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

                if let link, let url = url(link) {
                    HStack(spacing: 8) {
                        Text(url.absoluteString)
                            .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                            .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Button { copyLink(url) } label: {
                            Label { Text(copied ? "Copied" : "Copy link") } icon: { IconImage(copied ? .checkSmall : .link, size: 13) }
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.sheetPrimary)
                    }
                    .padding(.top, 14)
                    if let expires = link.expires {
                        Text("Works until \(expires.formatted(date: .long, time: .omitted)).")
                            .font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                            .padding(.top, 6)
                    }
                }
                if let error {
                    Label { Text(error) } icon: { IconImage(.warning, size: 13) }
                        .font(.system(size: 12)).foregroundStyle(Palette.recording)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
            }
            .padding(EdgeInsets(top: 8, leading: 22, bottom: 16, trailing: 22))

            SheetFooter {
                if link != nil {
                    Button("Stop sharing", role: .destructive) { confirmStop = true }
                        .buttonStyle(.sheetDestructive).disabled(working)
                }
            } trailing: {
                if working { ProgressView().controlSize(.small) }
                if link == nil {
                    Button("Cancel") { dismiss() }.buttonStyle(.sheetSecondary).keyboardShortcut(.cancelAction)
                    Button("Create link", action: publish).buttonStyle(.sheetPrimary).keyboardShortcut(.defaultAction)
                        .disabled(working || !options.showsAnything)
                } else if changed {
                    Button("Update link", action: publish).buttonStyle(.sheetPrimary).keyboardShortcut(.defaultAction)
                        .disabled(working || !options.showsAnything)
                } else {
                    Button("Done") { dismiss() }.buttonStyle(.sheetSecondary).keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var chatDetail: String {
        if !controller.serverHasChat { return "Add an Anthropic key to your server to turn this on." }
        if !(options.summary || options.transcript) { return "Share the summary or the transcript for the chat to read." }
        return "Visitors can ask about what you share. Your server's key pays."
    }

    private func part(_ title: String, _ detail: String, _ icon: Icon, _ on: Binding<Bool>) -> some View {
        PartRow(title: title, detail: detail, icon: icon, on: on)
    }

    private func publish() {
        working = true
        error = nil
        Task {
            do {
                let made = try await controller.share(record, options: options, existing: link)
                let first = link == nil
                link = made
                if first, let url = controller.shareURL(made) { copyLink(url) }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            working = false
        }
    }

    private func stop() {
        guard let link else { return }
        working = true
        Task {
            do {
                try await controller.stopSharing(link)
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            working = false
        }
    }

    private func copyLink(_ url: URL) {
        copy(url.absoluteString)
        copied = true
        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
    }
}

/// One part to share: what it is, a line on what it holds, and a switch. The plain button underneath dims it when
/// it cannot be shared.
private struct PartRow: View {
    let title: String
    let detail: String
    let icon: Icon
    let on: Binding<Bool>

    var body: some View {
        Toggle(isOn: on) {
            HStack(spacing: 12) {
                IconImage(icon, size: 15).foregroundStyle(Palette.accent).frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(SheetSwitchStyle())
        .padding(.vertical, 11)
        .hairline(.bottom)
    }
}
