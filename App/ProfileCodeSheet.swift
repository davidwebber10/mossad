import MossadCore
import SwiftUI

/// "Show code for iPhone…": the active profile's code, for an iPhone where iCloud Keychain is off. Only this
/// profile's own sync and server: the app has no other profile's secret. A code with a secret hides after a minute.
struct ProfileCodeSheet: View {
    @EnvironmentObject var controller: AppController
    @State private var shown = Date()

    var body: some View {
        let profile = controller.activeProfile
        let code = ProfileCode.make(profile: profile, sync: controller.syncWith, server: controller.serverConnection)
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(icon: .qrLarge, title: ProfileSettingsWords.codeTitle(profile.name), close: close)
            VStack(alignment: .leading, spacing: Rhythm.groupGap) {
                if let code {
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
                    VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                        ForEach(Array(ProfileSettingsWords.codeSteps.enumerated()), id: \.offset) { i, step in
                            Text("\(i + 1). \(step)").fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.ink)
                    if code.holdsSecret {
                        TimelineView(.periodic(from: shown, by: 1)) { context in
                            let left = max(0, 60 - Int(context.date.timeIntervalSince(shown)))
                            note(ProfileSettingsWords.codeSecretNote(seconds: left))
                                .monospacedDigit()
                                .onChange(of: left) { _, l in if l == 0 { close() } }
                        }
                    } else {
                        note(ProfileSettingsWords.codeICloudNote)
                    }
                } else {
                    note(controller.syncWith == .off ? ProfileSettingsWords.codeNoSync : ProfileSettingsWords.codeNoServer)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            SheetFooter {
                Button("Done", action: close).buttonStyle(.sheetPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .mossadSheet(width: 440)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func close() { controller.profileSheet = nil }
}
