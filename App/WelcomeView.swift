import MossadCore
import SwiftUI

/// The first launch, in three steps: what Mossad does, the permissions it needs with live checks, and the
/// owner with the keys for the services it uses. Each permission says why before it asks, and the one next
/// action is the accent button.
struct WelcomeView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var permissions: PermissionsMonitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var keys: [APIKey: String] = [:]

    /// The keys the chosen providers need; one already in the Keychain shows as set.
    private var providerKeys: [APIKey] {
        var list: [APIKey] = []
        for key in [controller.transcriptionProvider.key, controller.aiProvider.key].compactMap({ $0 }) where !list.contains(key) {
            list.append(key)
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Step \(step + 1) of 3").textRole(.label).foregroundStyle(Palette.tertiary)
                Text(title)
                    .font(.system(size: 24, weight: .semibold)).tracking(-0.48)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.s)
                    .accessibilityAddTraits(.isHeader)
                Group {
                    switch step {
                    case 0: intro
                    case 1: access
                    default: you
                    }
                }
                .padding(.top, 14)
            }
            .padding(EdgeInsets(top: 26, leading: 26, bottom: 18, trailing: 26))
            .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
            .id(step)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                              removal: .move(edge: .leading).combined(with: .opacity)))
            HStack(spacing: Space.s) {
                if step == 2 {
                    Text("You can change all of this in Settings.").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                } else {
                    progress
                }
                Spacer(minLength: Space.s)
                if step > 0 { Button("Back") { go(-1) }.buttonStyle(.sheetSecondary) }
                Button(step == 2 ? "Start" : "Continue") { step == 2 ? finish() : go(1) }
                    .buttonStyle(.sheetPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 26).padding(.vertical, 14)
            .hairline(.top)
        }
        .mossadSheet(width: 440)
        .clipped()
        .onAppear {
            // Development hook for screenshots: MOSSAD_WELCOME_STEP=1|2|3 opens that step in a preview.
            if CommandLine.arguments.contains("--ui-preview"),
               let n = ProcessInfo.processInfo.environment["MOSSAD_WELCOME_STEP"].flatMap(Int.init), (1...3).contains(n) {
                step = n - 1
            }
        }
    }

    private var title: String {
        switch step {
        case 0: "Mossad takes your meeting notes"
        case 1: "Let Mossad hear the call"
        default: "You, and the services Mossad uses"
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Capsule().fill(i <= step ? Palette.accentFill : Palette.bar).frame(width: i == step ? 18 : 6, height: 6)
            }
        }
        .animation(.snappy, value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step + 1) of 3")
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("When a Zoom, Google Meet, or Teams call starts, Mossad records it. After the call it writes the transcript with names, a summary, your action items, and a few lines from your coach. You do nothing.")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Space.s) {
                point("lock", "Voice fingerprints stay on this Mac. Recordings stay here unless you turn on a cloud archive.")
                point("waveform", "Audio goes to your transcription service only to make the transcript.")
                point("bell.slash", "No reminders, no buttons to press during a call.")
            }
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(permissions.items) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.state.isGood ? "checkmark.circle" : "circle.dashed")
                        .font(.system(size: 15)).foregroundStyle(item.state.isGood ? Palette.ok : Palette.accent)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                        Text(item.reason).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Space.s)
                    if item.state.isGood {
                        Text("Granted").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    } else {
                        Button("Grant…") { permissions.fix(item) }
                            .buttonStyle(SheetButtonStyle(kind: .primary, compact: true))
                            .accessibilityLabel("Grant \(item.title)")
                    }
                }
                .padding(.vertical, 9)
                .hairline(.bottom)
                .accessibilityElement(children: .combine)
            }
            Text("Each permission is for one part of the notes. You can change them later in Settings.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.secondary).padding(.top, 10)
        }
        .animation(.snappy, value: permissions.problemCount)
        .onAppear { permissions.setInterval(1) }
        .onDisappear { permissions.setInterval(10) }
    }

    private var you: some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    label("Your name")
                    TextField("Your name", text: $controller.ownerName).textFieldStyle(SheetFieldStyle())
                }
                GridRow {
                    label("Company")
                    TextField("Company", text: $controller.organization, prompt: Text("optional")).textFieldStyle(SheetFieldStyle())
                }
                ForEach(providerKeys) { key in
                    GridRow {
                        label(key.displayName)
                        if controller.hasKey(key) {
                            Text("Key set").font(.system(size: 12.5)).foregroundStyle(Palette.secondary).frame(height: 30)
                        } else {
                            SecureField(key.displayName, text: Binding(get: { keys[key, default: ""] }, set: { keys[key] = $0 }),
                                        prompt: Text("Paste the key"))
                                .textFieldStyle(SheetFieldStyle(monospaced: true))
                        }
                    }
                }
            }
            Text("Keys stay in the Keychain. Each provider bills your own account. Mossad learns your voice in your first call.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Palette.secondary).frame(width: 110, alignment: .leading)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent).frame(width: 16)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func go(_ n: Int) { withAnimation(.smooth) { step += n } }

    private func finish() {
        for (key, value) in keys {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            do { try controller.keychain.set(trimmed, for: key) } catch { Log.error("Saving the \(key.rawValue) key failed") }
        }
        controller.rebuildPipeline()
        UserDefaults.standard.set(true, forKey: "welcomeDone")
        dismiss()
    }
}
