import AppKit
import CoreImage.CIFilterBuiltins
import MossadCore
import SwiftUI

/// The pairing tile and its switches, for Settings and for setup's sync step.
struct PhonePairingRows: View {
    @EnvironmentObject var controller: AppController
    @State private var showCode = false

    var body: some View {
        Group {
            HStack(alignment: .center, spacing: Space.xl) {
                VStack(spacing: Rhythm.rowGap) {
                    IconImage(.qrLarge, size: 28).foregroundStyle(Palette.tertiaryMark)
                        .accessibilityHidden(true)
                    Button("Show code") { showCode = true }.buttonStyle(.settings)
                        .popover(isPresented: $showCode, arrowEdge: .trailing) { PairingCard() }
                }
                .frame(width: 120, height: 120)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Connect Mossad on your iPhone").font(.system(size: Rhythm.bodySize, weight: .semibold)).foregroundStyle(Palette.ink)
                    VStack(alignment: .leading, spacing: 0) {
                        step(1, "Open Mossad on your iPhone.")
                        step(2, "Tap the gear on the Meetings screen.")
                        step(3, "Choose Your server, then Scan code.")
                    }
                    .padding(.top, 6)
                    Text("The code holds your secret, so it hides again after a minute.")
                        .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.tertiary).padding(.top, 6)
                }
            }
            .padding(.top, 9).padding(.bottom, 12)
            SettingsSwitchRow(title: "Also send it through iCloud Keychain", detail: "Your iPhone then finds the server on its own, with no code.",
                              isOn: $controller.serverOnPhone)
                .disabled(!AppController.hasICloud)
                .onChange(of: controller.serverOnPhone) { _, _ in controller.updateSharedServer() }
            AIKeyToggle()
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(spacing: Space.m) {
            Text("\(n)").font(.system(size: Rhythm.noteSize, weight: .bold)).foregroundStyle(Palette.secondary)
                .frame(width: 18, height: 18).background(Palette.fill, in: Circle())
                .accessibilityHidden(true)
            Text(text).font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.ink)
        }
        .padding(.vertical, 3)
    }
}

/// The code itself, black on white so any camera reads it, with a countdown to when it hides.
private struct PairingCard: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.dismiss) private var dismiss
    @State private var shown = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Connect Mossad on your iPhone").font(.system(size: Rhythm.bodySize, weight: .semibold)).foregroundStyle(Palette.ink)
            Group {
                if let c = controller.serverConnection, let image = QRCode.image(ServerPairing.code(for: c)) {
                    Image(nsImage: image).interpolation(.none).resizable()
                } else {
                    Color.clear
                }
            }
            .frame(width: 160, height: 160)
            .padding(10)
            .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .accessibilityLabel("Pairing code")
            VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                Text("1. Open Mossad on your iPhone.")
                Text("2. Tap the gear on the Meetings screen.")
                Text("3. Choose Your server, then Scan code.")
            }
            .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.ink)
            .padding(.top, 14)
            TimelineView(.periodic(from: shown, by: 1)) { context in
                let left = max(0, 60 - Int(context.date.timeIntervalSince(shown)))
                Text("The code holds your secret, so it hides again in 0:\(String(format: "%02d", left)).")
                    .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary).monospacedDigit()
                    .onChange(of: left) { _, l in if l == 0 { dismiss() } }
            }
            .padding(.top, Space.s)
        }
        .padding(18)
        .frame(width: 300)
    }
}

/// Lets Chat and the coach on the iPhone use this Mac's AI provider and key.
struct AIKeyToggle: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        SettingsSwitchRow(title: "Use my AI key on my iPhone",
                          detail: "Chat and the coach on the iPhone use the provider and key chosen here, through iCloud Keychain.",
                          isOn: $controller.shareAIKey)
            .onChange(of: controller.shareAIKey) { _, _ in controller.updateSharedAIKey() }
    }
}

enum QRCode {
    static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
