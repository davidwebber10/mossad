import MossadCore
import SwiftUI

/// The local AI server's address with the Ollama and LM Studio presets, Check, and a link to get Ollama. Check
/// lists the server's models and picks the first when none is chosen. An address off this Mac gets a warning,
/// since the meeting text would go to that computer.
struct LocalServerSetup: View {
    @EnvironmentObject var controller: AppController
    /// Setup's sheet buttons in place of the Settings ones.
    var onboarding = false
    @State private var state: CheckState = .idle

    enum CheckState: Equatable { case idle, checking, found(Int), failed(FriendlyError) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Server").font(.system(size: onboarding ? 13.5 : 13, weight: .medium)).foregroundStyle(Palette.ink)
                    Link(destination: LocalServer.getOllama) {
                        HStack(spacing: 3) {
                            Text("Get Ollama")
                            IconImage(.arrowUp, size: 10).rotationEffect(.degrees(45))
                        }
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
                    .accessibilityLabel("Get Ollama on its website")
                }
                Spacer(minLength: Space.m)
                TextField("Server address", text: $controller.localServerURL, prompt: Text(LocalServer.ollama.absoluteString))
                    .textFieldStyle(SettingsFieldStyle(width: 200, monospaced: true))
                    .onSubmit(check)
                Menu {
                    Button("Ollama") { use(LocalServer.ollama) }
                    Button("LM Studio") { use(LocalServer.lmStudio) }
                } label: {
                    FillMenuLabel(text: "Presets")
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                checkButton
            }
            switch state {
            case .found(let count):
                PassLine(text: count == 0 ? "The server is running, but it has no models yet" : "Found \(count) \(count == 1 ? "model" : "models")")
            case .failed(let error):
                InlineError(error: error)
            case .idle, .checking:
                EmptyView()
            }
            if !LocalServer.isOnThisMac(controller.localServerBase) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    WarningMark(size: 13).foregroundStyle(Palette.accent)
                    Text("This address is not on this Mac. Your meeting text goes to that computer.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, onboarding ? Onboard.rowPadding : 9)
        .onChange(of: controller.localServerURL) { _, _ in state = .idle }
    }

    @ViewBuilder
    private var checkButton: some View {
        let label = Group {
            if state == .checking { ProgressView().controlSize(.small).frame(width: 40) } else { Text("Check") }
        }
        if onboarding {
            Button(action: check) { label }.buttonStyle(SheetButtonStyle(kind: .secondary, compact: true)).disabled(state == .checking)
        } else {
            Button(action: check) { label }.buttonStyle(SettingsButtonStyle()).disabled(state == .checking)
        }
    }

    private func use(_ url: URL) {
        controller.localServerURL = url.absoluteString
        check()
    }

    private func check() {
        let base = controller.localServerBase
        let key = controller.keychain.get(.localServer)
        if let typed = LocalServer.url(from: controller.localServerURL) { controller.localServerURL = typed.absoluteString }
        state = .checking
        Task {
            do {
                let models = try await ModelCatalog.fetch(.localServer, apiKey: key, serverURL: base)
                state = .found(models.count)
                if !models.contains(where: { $0.id == controller.aiModel }), let first = models.first { controller.aiModel = first.id }
                controller.localServerChecks += 1
                controller.rebuildPipeline()
            } catch {
                Log.error("Checking the local AI server failed: \(FriendlyError(error, context: .checkingKey).technical)")
                state = .failed(FriendlyError(error, context: .checkingKey, service: "the local server"))
            }
        }
    }
}

/// Whether Apple's on-device model can run here, and why not when it cannot.
struct AppleModelStatus: View {
    var body: some View {
        if let reason = AppleModelInfo.unavailableReason() {
            InlineError(error: FriendlyError(reason, context: .general))
        } else {
            PassLine(text: "Ready on this Mac")
        }
    }
}
