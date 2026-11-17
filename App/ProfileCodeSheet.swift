import MossadCore
import SwiftUI

/// "Show code for iPhone…": the active profile's code, for an iPhone where iCloud Keychain is off. Only this
/// profile's own sync and server: the app has no other profile's secret. The secret is read once when the sheet
/// opens, off the main actor, and dropped when the sheet closes or the minute ends; the code is drawn only inside
/// the timed view, so it is gone after a minute whatever ticks.
struct ProfileCodeSheet: View {
    @EnvironmentObject var controller: AppController
    @State private var shown = Date()
    @State private var code: ProfileCode?
    @State private var read = false

    var body: some View {
        let profile = controller.activeProfile
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(icon: .qrLarge, title: ProfileSettingsWords.codeTitle(profile.name), close: close)
            VStack(alignment: .leading, spacing: Rhythm.groupGap) {
                if let code {
                    TimelineView(.periodic(from: shown, by: 1)) { context in
                        let left = code.holdsSecret ? max(0, 60 - Int(context.date.timeIntervalSince(shown))) : 60
                        VStack(alignment: .leading, spacing: Rhythm.groupGap) {
                            if left > 0 {
                                qr(code)
                                steps
                                note(code.holdsSecret ? ProfileSettingsWords.codeSecretNote(seconds: left) : ProfileSettingsWords.codeICloudNote)
                                    .monospacedDigit()
                            }
                        }
                        .onChange(of: left) { _, l in if l == 0 { close() } }
                    }
                } else if read {
                    note(controller.syncWith == .off ? ProfileSettingsWords.codeNoSync : ProfileSettingsWords.codeNoServer)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            SheetFooter {
                Button("Done", action: close).buttonStyle(.sheetPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .mossadSheet(width: 440)
        .task { await load(profile) }
        .onDisappear { code = nil }
    }

    /// The Keychain is read once, off the main actor.
    private func load(_ profile: Profile) async {
        let sync = controller.syncWith
        let address = ServerConnection.address(from: controller.serverAddress)
        let keychain = controller.keychain
        let sample = ServerSample.isOn ? ServerSample.connection : nil
        let server: ServerConnection? = await Task.detached(priority: .userInitiated) {
            if let sample { return sample }
            guard sync == .server, let address, let secret = keychain.get(.serverSecret) else { return nil }
            return ServerConnection(address: address, secret: secret)
        }.value
        code = ProfileCode.make(profile: profile, sync: sync, server: server)
        shown = Date()
        read = true
    }

    private func qr(_ code: ProfileCode) -> some View {
        Group {
            if let image = QRCode.image(code.text) {
                Image(nsImage: image).interpolation(.none).resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: 200, height: 200)
        .padding(Space.m)
        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Profile code")
    }

    private var steps: some View {
        // The gap between steps is wider than a line's, so a wrapped step never reads as two.
        VStack(alignment: .leading, spacing: Rhythm.itemGap) {
            ForEach(Array(ProfileSettingsWords.codeSteps.enumerated()), id: \.offset) { i, step in
                Text("\(i + 1). \(step)").fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.ink)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func close() {
        code = nil
        controller.profileSheet = nil
    }
}
