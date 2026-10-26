import SwiftUI

/// The first launch: what Mossad does, the permissions it needs with live checks, and the owner's name. Each
/// permission says why before it asks, and the one next action is the prominent button.
struct WelcomeView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var permissions: PermissionsMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: intro
                case 1: access
                default: name
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(32)
            .id(step)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                              removal: .move(edge: .leading).combined(with: .opacity)))
            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Capsule().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: i == step ? 18 : 6, height: 6)
                    }
                }
                .animation(.snappy, value: step)
                .accessibilityLabel("Step \(step + 1) of 3")
                Spacer()
                if step > 0 { Button("Back") { go(-1) } }
                Button(step == 2 ? "Start" : "Continue") { step == 2 ? finish() : go(1) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 620, height: 520)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Mossad takes your meeting notes").font(.largeTitle.weight(.bold))
            Text("When a Zoom, Google Meet, or Teams call starts, Mossad records it. After the call it writes the transcript with names, a summary, your action items, and a few lines from your coach. You do nothing.")
                .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                point("lock.shield", "Voice fingerprints stay on this Mac. Recordings stay here unless you turn on a cloud archive.")
                point("waveform", "Audio goes to your transcription service only to make the transcript.")
                point("bell.slash", "No reminders, no buttons to press during a call.")
            }
            .padding(.top, 6)
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Let Mossad hear the call").font(.largeTitle.weight(.bold))
            Text("Each permission is for one part of the notes. You can change them later in Settings.")
                .font(.title3).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(permissions.items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.state.isGood ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.title2).foregroundStyle(item.state.isGood ? Color.green : Color.secondary)
                            .contentTransition(.symbolEffect(.replace))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.headline)
                            Text(item.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if !item.state.isGood {
                            Button("Allow…") { permissions.fix(item) }.buttonStyle(.glass)
                        }
                    }
                    .padding(.vertical, 10)
                    if item.id != permissions.items.last?.id { Divider() }
                }
            }
            .animation(.snappy, value: permissions.problemCount)
        }
        .onAppear { permissions.setInterval(1) }
        .onDisappear { permissions.setInterval(10) }
    }

    private var name: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What should Mossad call you?").font(.largeTitle.weight(.bold))
            Text("Your lines in each transcript use this name, and the coach speaks to you by it.")
                .font(.title3).foregroundStyle(.secondary)
            TextField("Your name", text: $controller.ownerName)
                .textFieldStyle(.roundedBorder).font(.title3).frame(maxWidth: 360)
            Text("Mossad learns your voice in your first call.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).font(.body) } icon: { Image(systemName: symbol).foregroundStyle(.tint) }
    }

    private func go(_ n: Int) { withAnimation(.smooth) { step += n } }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "welcomeDone")
        dismiss()
    }
}
