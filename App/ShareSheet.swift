import AppKit
import MossadCore
import SwiftUI

/// Share one meeting by a private link. The sheet first holds every setting and creates nothing: Share puts the
/// meeting on the server, and the same sheet then shows the link to copy. It closes with its X, with Escape, with
/// Command-period, with a click outside it, with Cancel before Share, and with Done after. A close while Share works
/// cancels the share: a new link is taken off the server again, and nothing goes to the clipboard.
struct ShareSheet: View {
    enum Phase { case settings, result }

    @EnvironmentObject var controller: AppController
    @Environment(\.dismiss) private var dismiss
    let record: CallRecord
    /// Opens on the settings of a meeting that is already shared, as the Shares page asks for.
    var startInSettings = false

    @State private var phase = Phase.settings
    @State private var draft = ShareDraft(existing: nil, hasRecording: false)
    @State private var link: MeetingLink?
    /// "Link created" or "Changes saved", after Share in this sheet.
    @State private var done: String?
    @State private var working = false
    /// The share that runs now, so a close can cancel it.
    @State private var sharing: Task<Void, Never>?
    /// The sheet was closed: a share that ends after this keeps nothing new and copies nothing.
    @State private var closed = false
    @State private var error: FriendlyError?
    @State private var copied: String?
    /// The server's word on the link's PIN: the sheet shows the PIN only when the server confirms it.
    @State private var remote: ServerShare?
    @State private var answered = false
    /// The PIN call of the Share in this sheet just answered, which confirms the PIN.
    @State private var justSet = false
    @State private var confirmStop = false

    /// Development hook for screenshots, in a preview: MOSSAD_SHARE=none is the state with no server, =new the
    /// settings of a new share, =pin the same with the PIN on, =link a made-up link, and =shared a made-up link
    /// with a PIN just after Share.
    private static let preview: String? = CommandLine.arguments.contains("--ui-preview")
        ? ProcessInfo.processInfo.environment["MOSSAD_SHARE"] : nil
    private var hasServer: Bool {
        switch Self.preview {
        case "none": false
        case .some: true
        default: controller.serverConnection != nil
        }
    }
    private var canUsePIN: Bool { Self.preview != nil || controller.serverHasShareNumbers }

    private func url(_ link: MeetingLink) -> URL? {
        if Self.preview != nil { return link.url(on: URL(string: "https://notes.example.com")!) }
        return controller.shareURL(link)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(icon: .link, title: phase == .result ? "“\(record.title)” is shared" : "Share “\(record.title)”",
                        subtitle: record.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()),
                        close: close)
            if !hasServer { noServer } else if phase == .result, let link { result(link) } else { settings }
        }
        .mossadSheet(width: hasServer ? 480 : 420)
        .closesOnOutsideClick(close)
        .onAppear(perform: start)
        .onDisappear { if working { cancelShare() } }
        .confirmationDialog("Stop sharing this meeting?", isPresented: $confirmStop) {
            Button("Stop sharing", role: .destructive, action: stop)
        } message: {
            Text("The link stops working at once, and the copy on your server is deleted.")
        }
    }

    private func start() {
        link = controller.shareBook.link(for: record.id)
        if let kind = Self.preview, ["link", "shared"].contains(kind), link == nil {
            var made = MeetingLink(token: "Hq3v9pR2xW7mN4kT2bY8cLs5dJ1fG6hZ0aQeUiOpXyV", callID: record.id, title: record.title, options: ShareOptions(),
                                   created: Date(), expires: Date().addingTimeInterval(30 * 86_400))
            if kind == "shared" {
                made.pin = "4821"
                done = "Link created"
                copied = "all"
            }
            link = made
        }
        draft = ShareDraft(existing: link, hasRecording: controller.hasRecording(record))
        if Self.preview == "pin" { draft.pinOn = true }
        phase = link != nil && !startInSettings ? .result : .settings
        if link != nil { Task { await askServer() } }
    }

    private var pinCheck: SharePINCheck {
        guard let link else { return .none }
        if Self.preview != nil { return link.pin.map { .confirmed($0) } ?? .none }
        return SharePINCheck.state(link: link, remote: remote, answered: answered, justSet: justSet)
    }

    /// The PIN to show and to copy: only one that the server confirmed.
    private var shownPIN: String? { if case .confirmed(let pin) = pinCheck { pin } else { nil } }

    private func askServer() async {
        guard Self.preview == nil, let link else { return }
        answered = false
        remote = nil
        if controller.serverHasShareNumbers, let c = controller.serverConnection {
            remote = try? await ServerClient(c).shareDetail(shareID: link.id).share
        }
        answered = true
    }

    private var pinNote: String? {
        switch pinCheck {
        case .checking: "Checking the PIN with your server…"
        case .changed: "This link has a PIN that this Mac does not know. Make a new PIN on the Shares page to copy it."
        case .locked: "The link is locked by too many wrong PINs. Make a new PIN on the Shares page."
        case .unanswered: "Your server did not answer, so the PIN cannot be shown. The Shares page shows it when the server answers."
        case .none, .confirmed: nil
        }
    }

    // MARK: No server

    private var noServer: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                Text("Share links need your own server").fontWeight(.semibold)
                Text("Mossad puts the parts you choose on a small server in your own Cloudflare account and gives you a private link to send. Nobody else runs it, and nobody else can use it.")
                    .foregroundStyle(Palette.secondary).lineSpacing(Rhythm.secondaryLineGap).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            SheetFooter {
                Button("Cancel", action: close).buttonStyle(.sheetSecondary)
                Button("Set up your server…") {
                    UserDefaults.standard.set(SettingsPage.sync.rawValue, forKey: "settingsPage")
                    controller.open(.settings)
                    dismiss()
                }
                .buttonStyle(.sheetPrimary).keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                PartRow(title: "Summary and action items", detail: "The overview, topics, decisions, and action items.", icon: .document, on: $draft.options.summary)
                PartRow(title: "Transcript", detail: "Every line, with names and times.", icon: .meetings, on: $draft.options.transcript)
                PartRow(title: "Recording", detail: controller.hasRecording(record) ? "The audio, with a player. A click on a line plays from there." : "This meeting has no recording.",
                        icon: .waveform, on: $draft.options.recording)
                    .disabled(!controller.hasRecording(record))
                PartRow(title: "Ask for a PIN", detail: canUsePIN ? "People need the link and these 4 digits to open the page." : "Update your server to protect a link with a PIN.",
                        icon: .lock, on: $draft.pinOn, last: !draft.pinOn)
                    .disabled(!canUsePIN)
                if draft.pinOn { pinRow }

                HStack {
                    Text("Link works for")
                    Spacer()
                    GlassSegmented(selection: $draft.options.days, choices: ShareOptions.expiryChoices.map { d in
                        (value: d, title: d.map { "\($0) days" } ?? "Until I stop it")
                    })
                    .accessibilityLabel("Link works for")
                }
                .padding(.top, 14)

                Label {
                    Text("The coach's review is never shared. People who open the page can copy what they see.")
                } icon: {
                    IconImage(.lock, size: 12).foregroundStyle(Palette.tertiaryMark)
                }
                .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

                if let error { ErrorCard(error: error).padding(.top, 12) }
            }
            .padding(EdgeInsets(top: 8, leading: 22, bottom: 16, trailing: 22))

            SheetFooter {
                if link != nil {
                    Button("Stop sharing", role: .destructive) { confirmStop = true }
                        .buttonStyle(.sheetDestructive).disabled(working)
                }
            } trailing: {
                if working { ProgressView().controlSize(.small) }
                Button("Cancel", action: close).buttonStyle(.sheetSecondary)
                if let link {
                    Button("Save changes", action: publish).buttonStyle(.sheetPrimary).keyboardShortcut(.defaultAction)
                        .disabled(working || !draft.canShare || !draft.differs(from: link))
                } else {
                    Button("Share", action: publish).buttonStyle(.sheetPrimary).keyboardShortcut(.defaultAction)
                        .disabled(working || !draft.canShare)
                }
            }
        }
    }

    /// The PIN that the link will have, shown before anything is created, with a way to draw another.
    private var pinRow: some View {
        HStack(spacing: Space.m) {
            Color.clear.frame(width: 20, height: 1)
            PINDigits(pin: draft.pin)
            Spacer(minLength: 8)
            Button("New PIN") { draft.makeNewPIN() }.buttonStyle(.sheetText)
                .help("Draw another random PIN")
        }
        .padding(.top, 2).padding(.bottom, 12)
        .hairline(.bottom)
    }

    // MARK: Result

    private func result(_ link: MeetingLink) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let done {
                    Label { Text(done).fontWeight(.medium) } icon: { IconImage(.checkSmall, size: 13).foregroundStyle(Palette.okText) }
                        .padding(.bottom, 12)
                        .accessibilityAddTraits(.isHeader)
                }
                if let url = url(link) {
                    VStack(alignment: .leading, spacing: Rhythm.itemGap) {
                        Text(url.absoluteString).lineLimit(1).truncationMode(.middle)
                        if let pin = shownPIN { Text("PIN: \(pin)") }
                    }
                    .font(.system(size: Rhythm.secondarySize, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(shownPIN == nil ? "The link" : "The link and the PIN, as they are copied")

                    HStack(spacing: Space.s) {
                        Button { put(ShareMessage.text(url: url, pin: shownPIN), as: "all") } label: {
                            Label { Text(copied == "all" ? "Copied" : shownPIN == nil ? "Copy link" : "Copy link and PIN") }
                                icon: { IconImage(copied == "all" ? .checkSmall : .link, size: 13) }
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.sheetPrimary)
                        if shownPIN != nil {
                            Button(copied == "link" ? "Copied" : "Copy link only") { put(url.absoluteString, as: "link") }
                                .buttonStyle(.sheetSecondary)
                                .help("To send the PIN another way")
                        }
                    }
                    .padding(.top, 10)
                }
                if let pinNote {
                    Text(pinNote)
                        .font(.system(size: Rhythm.secondarySize)).foregroundStyle(pinCheck == .locked ? Palette.recording : Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
                Text(facts(link))
                    .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                if let error { ErrorCard(error: error).padding(.top, 12) }
            }
            .padding(EdgeInsets(top: 16, leading: 22, bottom: 16, trailing: 22))

            SheetFooter {
                Button("Change settings…") { error = nil; done = nil; phase = .settings }.buttonStyle(.sheetText)
            } trailing: {
                Button("Done", action: close).buttonStyle(.sheetSecondary).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// What the link shows and how long it works, in one quiet line.
    private func facts(_ link: MeetingLink) -> String {
        let o = link.options
        let parts = [o.summary ? "the summary" : nil, o.transcript ? "the transcript" : nil, o.recording ? "the recording" : nil].compactMap { $0 }
        let shows = "Shows \(ListFormatter.localizedString(byJoining: parts))."
        let until = link.expires.map { "Works until \($0.formatted(date: .long, time: .omitted))." } ?? "Works until you stop it."
        let pin = shownPIN == nil ? "" : " The PIN is not part of the link: send it with the link, or another way."
        return "\(shows) \(until)\(pin)"
    }

    // MARK: Actions

    /// X, Escape, Command-period, Cancel, Done, and a click outside all come here.
    private func close() {
        cancelShare()
        dismiss()
    }

    private func cancelShare() {
        closed = true
        sharing?.cancel()
    }

    private func publish() {
        working = true
        error = nil
        closed = false
        let first = link == nil
        let before = link?.pinSet
        sharing = Task {
            defer { working = false; sharing = nil }
            do {
                let made = try await controller.share(record, options: draft.options, pin: draft.sentPIN, existing: link)
                // The sheet closed while the server answered: a new link goes again, and nothing is copied.
                if closed {
                    if first { controller.abandonKept(made) }
                    return
                }
                link = made
                justSet = made.pinSet != nil && made.pinSet != before
                if !justSet { Task { await askServer() } }
                draft = ShareDraft(existing: made, hasRecording: controller.hasRecording(record))
                done = first ? "Link created" : "Changes saved"
                phase = .result
                // A new link goes to the clipboard at once, with its PIN when it has one.
                if first, let url = controller.shareURL(made) { put(ShareMessage.text(url: url, pin: shownPIN), as: "all") }
            } catch {
                if closed || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    Log.info("A share was cancelled when its sheet closed")
                    return
                }
                Log.error("Share link failed: \(error)")
                let friendly = FriendlyError(error, context: .sharing, service: "your server")
                if friendly.shouldShow(failures: 1) { self.error = friendly }
            }
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
                Log.error("Share link failed: \(error)")
                let friendly = FriendlyError(error, context: .sharing, service: "your server")
                if friendly.shouldShow(failures: 1) { self.error = friendly }
            }
            working = false
        }
    }

    private func put(_ text: String, as kind: String) {
        copy(text)
        copied = kind
        Task { try? await Task.sleep(for: .seconds(2)); if copied == kind { copied = nil } }
    }
}

/// The 4 digits of a PIN, set apart so they read one by one.
struct PINDigits: View {
    let pin: String
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: size * 0.3) {
            ForEach(Array(pin.enumerated()), id: \.offset) { _, digit in
                Text(String(digit))
                    .font(.system(size: size, weight: .semibold, design: .monospaced))
                    .frame(width: size * 1.35, height: size * 1.7)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .foregroundStyle(Palette.ink)
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PIN \(pin.map(String.init).joined(separator: " "))")
    }
}

/// One part to share: what it is, a line on what it holds, and a switch. The plain button underneath dims it when
/// it cannot be shared.
private struct PartRow: View {
    let title: String
    let detail: String
    let icon: Icon
    let on: Binding<Bool>
    var last = true

    var body: some View {
        Toggle(isOn: on) {
            HStack(spacing: Space.m) {
                IconImage(icon, size: 15).foregroundStyle(Palette.accent).frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(SheetSwitchStyle())
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { if last { Hairline() } }
    }
}
