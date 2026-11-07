import AppKit
import MossadCore
import SwiftUI

/// Four steps, each checked before the next opens: deploy, the address, the secret, the first sync. A step
/// that is done folds to one line, so the open step is the only one with controls.
struct ServerSetupSheet: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.dismiss) private var dismiss

    enum Check: Equatable { case idle, checking, ok, failed(String) }

    @State private var deployed = false
    @State private var address = ""
    @State private var addressCheck = Check.idle
    @State private var foundAddress: URL?
    @State private var makeNew = true
    @State private var newSecret = ServerConnection.newSecret()
    @State private var pasted = ""
    @State private var secretCheck = Check.idle
    @State private var hello: ServerClient.Hello?
    @State private var started = false
    @State private var copiedSecret = false
    /// Sync the iPhone through the server too. Off while iCloud works, so the iPhone keeps getting meetings.
    @State private var syncThere = !AppController.hasICloud

    private static let guide = URL(string: "https://github.com/davidwebber10/mossad/tree/main/server#readme")!
    private static let commands = """
    cd server && npm install && npx wrangler login
    npx wrangler d1 create mossad
    npx wrangler r2 bucket create mossad-files
    npx wrangler kv namespace create OAUTH_KV
    """
    private static let secretCommand = "npx wrangler secret put OWNER_SECRET && npx wrangler deploy"

    private var secret: String { makeNew ? newSecret : pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var syncDone: Bool { started && !controller.syncRunning && (controller.syncActivity.last != nil || controller.syncWith != .server) }
    private var deployDone: Bool { deployed || foundAddress != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(icon: .cloud, title: "Set up your server",
                        subtitle: "About 5 minutes. Your meetings stay in your own Cloudflare account.")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SetupStep(number: 1, title: "Deploy the server", state: deployDone ? .done : .active,
                              summary: "Deployed in your Cloudflare account.") {
                        Text("The server is a small Cloudflare Worker that runs in your own Cloudflare account. One person’s use is free.")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Space.s) {
                            Button("Open the setup guide") { NSWorkspace.shared.open(Self.guide) }.buttonStyle(.sheetSecondary)
                            Button("Copy the first commands") { copy(Self.commands) }.buttonStyle(.sheetSecondary)
                        }
                        Text("Already deployed? Go on to step 2.").font(.system(size: 11.5)).foregroundStyle(Palette.tertiary)
                    }
                    SetupStep(number: 2, title: "Address", state: foundAddress != nil ? .done : .active,
                              summary: foundAddress.map { "\($0.host ?? "") · answers" }, monospacedSummary: true) {
                        HStack(spacing: Space.s) {
                            TextField("Address", text: $address, prompt: Text("notes.example.com"))
                                .textFieldStyle(SheetFieldStyle(monospaced: true))
                                .onSubmit(checkAddress)
                                .onChange(of: address) { _, _ in if addressCheck != .checking { addressCheck = .idle; foundAddress = nil } }
                            Button("Check", action: checkAddress).buttonStyle(.sheetPrimary)
                                .disabled(ServerConnection.address(from: address) == nil || addressCheck == .checking)
                        }
                        CheckLabel(check: addressCheck, ok: "Found your Mossad server.")
                    }
                    SetupStep(number: 3, title: "Secret", state: hello != nil ? .done : (foundAddress == nil ? .todo : .active),
                              summary: "Your server accepts it. Mossad keeps it in the Keychain.") {
                        GlassSegmented(selection: $makeNew, choices: [(true, "Make a new secret"), (false, "I have a secret")])
                            .onChange(of: makeNew) { _, _ in secretCheck = .idle; hello = nil }
                        if makeNew {
                            Text("Put this secret on your server. In the server folder, run the command, paste the secret when it asks, then deploy again.")
                                .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                            Text(Self.secretCommand)
                                .font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            HStack(spacing: Space.s) {
                                Button(copiedSecret ? "Secret copied" : "Copy secret") {
                                    copy(newSecret)
                                    copiedSecret = true
                                }
                                .buttonStyle(.sheetSecondary)
                                Button("Copy command") { copy(Self.secretCommand) }.buttonStyle(.sheetSecondary)
                                Spacer(minLength: 0)
                                Button("Check", action: checkSecret).buttonStyle(.sheetPrimary).disabled(secretCheck == .checking)
                            }
                        } else {
                            HStack(spacing: Space.s) {
                                SecureField("Secret", text: $pasted, prompt: Text("Paste your secret"))
                                    .textFieldStyle(SheetFieldStyle(monospaced: true))
                                    .onSubmit(checkSecret)
                                Button("Check", action: checkSecret).buttonStyle(.sheetPrimary).disabled(secret.isEmpty || secretCheck == .checking)
                            }
                            Text("Mossad keeps it in the Keychain. Paste the same secret into the server.")
                                .font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                        }
                        CheckLabel(check: secretCheck, ok: "Your server accepts this secret.")
                    }
                    SetupStep(number: 4, title: "Move your meetings", state: syncDone ? .done : (hello == nil ? .todo : .active),
                              summary: "Your meetings are on your server.", last: true,
                              todoDetail: "Sends your \(controller.meetings.count) meetings to the server. Audio stays on this Mac.") {
                        Text("Mossad sends your meetings’ notes and transcripts to your server, so ChatGPT can read them. Audio stays on this Mac.")
                            .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                        if AppController.hasICloud {
                            Toggle(isOn: $syncThere) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Sync my iPhone through the server, not iCloud").font(.system(size: 13))
                                    Text("Then connect the iPhone with the code in Settings. Leave this off to keep iCloud.")
                                        .font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                                }
                            }
                            .toggleStyle(SheetSwitchStyle())
                            .disabled(started)
                        }
                        if !started {
                            Button("Start syncing", action: start).buttonStyle(.sheetPrimary)
                        } else if let error = controller.syncActivity.error {
                            CheckLabel(check: .failed(error), ok: "")
                            Button("Try again") { controller.syncNow() }.buttonStyle(.sheetSecondary)
                        } else {
                            HStack(spacing: Space.s) {
                                ProgressView().controlSize(.small)
                                Text(controller.syncActivity.progress.map { "Sending your meetings… \($0.done) of \($0.total)" } ?? "Sending your meetings…")
                                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).monospacedDigit()
                            }
                        }
                    }
                }
                .padding(EdgeInsets(top: 4, leading: 22, bottom: 12, trailing: 22))
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
            SheetFooter {
                Button("Cancel") { dismiss() }.buttonStyle(.sheetSecondary).keyboardShortcut(.cancelAction)
                // Continue runs the open step's check; Done comes with the last step.
                Button(started ? "Done" : "Continue", action: next)
                    .buttonStyle(.sheetPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
        .mossadSheet(width: 560)
        .onAppear {
            if let c = controller.serverConnection {
                address = c.address.host ?? ""
                deployed = true
                makeNew = false
                pasted = c.secret
            }
        }
    }

    private var canContinue: Bool {
        if started { return true }
        if foundAddress == nil { return ServerConnection.address(from: address) != nil && addressCheck != .checking }
        if hello == nil { return !secret.isEmpty && secretCheck != .checking }
        return true
    }

    private func next() {
        if started { dismiss() } else if foundAddress == nil { checkAddress() } else if hello == nil { checkSecret() } else { start() }
    }

    private func checkAddress() {
        guard let url = ServerConnection.address(from: address) else { return }
        addressCheck = .checking
        Task {
            do {
                _ = try await ServerClient(ServerConnection(address: url, secret: "")).hello()
                foundAddress = url
                addressCheck = .ok
            } catch {
                foundAddress = nil
                addressCheck = .failed(error is ServerError ? "That address answers, but not like a Mossad server." : "Mossad could not reach that address. Check it, and that the server is deployed.")
            }
        }
    }

    private func checkSecret() {
        guard let url = foundAddress, !secret.isEmpty else { return }
        secretCheck = .checking
        Task {
            do {
                let h = try await ServerClient(ServerConnection(address: url, secret: secret)).hello()
                if h.authorized {
                    hello = h
                    secretCheck = .ok
                } else {
                    hello = nil
                    secretCheck = .failed(makeNew ? "Not yet. Run the command, paste the secret, and deploy, then check again." : "Your server does not accept this secret.")
                }
            } catch {
                secretCheck = .failed("Mossad could not reach your server.")
            }
        }
    }

    private func start() {
        guard let url = foundAddress, let hello else { return }
        started = true
        controller.connectServer(ServerConnection(address: url, secret: secret), hello: hello, syncThere: syncThere)
    }
}

/// One step: a 22 pt mark (green check when done, the accent number when open, a ring when not yet), the
/// title, and either its one-line summary or its controls.
private struct SetupStep<Content: View>: View {
    enum State { case todo, active, done }

    let number: Int
    let title: String
    let state: State
    var summary: String?
    var monospacedSummary = false
    var last = false
    var todoDetail: String?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            mark
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(state == .todo ? Palette.tertiary : Palette.ink)
                    .frame(minHeight: 22)
                switch state {
                case .done:
                    if let summary {
                        Text(summary)
                            .font(monospacedSummary ? .system(size: 12, design: .monospaced) : .system(size: 12))
                            .foregroundStyle(Palette.secondary).padding(.top, 2)
                    }
                case .active:
                    VStack(alignment: .leading, spacing: 10) { content }.padding(.top, Space.s)
                case .todo:
                    if let todoDetail { Text(todoDetail).font(.system(size: 12)).foregroundStyle(Palette.tertiary).padding(.top, 2) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { if !last { Hairline() } }
        .animation(.smooth, value: state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number), \(title), \(state == .done ? "done" : state == .active ? "open" : "not yet")")
    }

    private var mark: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Palette.ok)
                IconImage(.check, size: 12).foregroundStyle(.white)
            case .active:
                Circle().fill(Palette.accentFill)
                Text("\(number)").font(.system(size: 11.5, weight: .bold)).foregroundStyle(Palette.onAccent)
            case .todo:
                Circle().strokeBorder(Palette.ring, lineWidth: 1.5)
                Text("\(number)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.tertiary)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

private struct CheckLabel: View {
    let check: ServerSetupSheet.Check
    let ok: String

    var body: some View {
        switch check {
        case .idle: EmptyView()
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(Palette.secondary) }.font(.system(size: 12))
        case .ok:
            Label { Text(ok).foregroundStyle(Palette.okText) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ok) }
                .font(.system(size: 12))
        case .failed(let message):
            Label { Text(message).foregroundStyle(Palette.ink) } icon: { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.recording) }
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
