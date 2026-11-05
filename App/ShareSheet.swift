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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if controller.serverConnection == nil { noServer } else { form }
        }
        .frame(width: 460)
        .background(Theme.background)
        .onAppear {
            link = controller.shareBook.link(for: record.id)
            if let link { options = link.options }
            if !controller.hasRecording(record) { options.recording = false }
        }
        .confirmationDialog("Stop sharing this meeting?", isPresented: $confirmStop) {
            Button("Stop sharing", role: .destructive, action: stop)
        } message: {
            Text("The link stops working at once, and the copy on your server is deleted.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "link").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 38, height: 38).background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Share “\(record.title)”").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(record.start.formatted(.dateTime.weekday(.wide).month().day().hour().minute())).foregroundStyle(.secondary)
            }
        }
        .padding(18)
    }

    private var noServer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Share links need your own server").font(.system(size: 13, weight: .semibold))
            Text("Mossad puts the parts you choose on a small server in your own Cloudflare account, and gives you a private link to send. Nobody else runs it, and nobody else can use it.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set up your server…") {
                    UserDefaults.standard.set(SettingsPage.sync.rawValue, forKey: "settingsPage")
                    controller.open(.settings)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 12))
        .padding(18)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                part("Summary and action items", "The overview, topics, decisions, and action items.", "text.alignleft", $options.summary)
                Divider().padding(.leading, 44)
                part("Transcript", "Every line, with names and times.", "text.quote", $options.transcript)
                Divider().padding(.leading, 44)
                part("Recording", controller.hasRecording(record) ? "The audio, with a player. Tap a line to jump there." : "This meeting has no recording.",
                     "waveform", $options.recording)
                    .disabled(!controller.hasRecording(record))
                Divider().padding(.leading, 44)
                part("AI chat", chatDetail, "sparkles", $options.chat)
                    .disabled(!controller.serverHasChat || !(options.summary || options.transcript))
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.separator))

            HStack {
                Text("Link works for")
                Spacer()
                Picker("Link works for", selection: $options.days) {
                    ForEach(ShareOptions.expiryChoices, id: \.self) { d in Text(d.map { "\($0) days" } ?? "Until I stop it").tag(d) }
                }
                .labelsHidden().fixedSize()
            }
            .padding(.horizontal, 4)

            Label("The coach's review is never shared. People with the link can copy what they see.", systemImage: "lock")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            if let link, let url = controller.shareURL(link) {
                HStack(spacing: 8) {
                    Text(url.absoluteString).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: 7))
                    Button(copied ? "Copied" : "Copy link") { copyLink(url) }.buttonStyle(.borderedProminent)
                }
                if let expires = link.expires {
                    Text("Works until \(expires.formatted(date: .long, time: .omitted)).").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.recording).fixedSize(horizontal: false, vertical: true) }

            HStack {
                if link != nil {
                    Button("Stop sharing", role: .destructive) { confirmStop = true }.disabled(working)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                if link == nil {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Create link", action: publish).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(working || !options.showsAnything)
                } else if changed {
                    Button("Update link", action: publish).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(working || !options.showsAnything)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .font(.system(size: 12))
        .padding(18)
    }

    private var chatDetail: String {
        if !controller.serverHasChat { return "Add an Anthropic key to your server to turn this on." }
        if !(options.summary || options.transcript) { return "Share the summary or the transcript for the chat to read." }
        return "Visitors can ask about what you share. Your server's key pays."
    }

    private func part(_ title: String, _ detail: String, _ symbol: String, _ on: Binding<Bool>) -> some View {
        Toggle(isOn: on) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Color.accentColor).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 12).padding(.vertical, 9)
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
