import MossadCore
import SwiftUI

/// The local AI server's address with the Ollama and LM Studio presets, Check, and a link to get Ollama. Check
/// lists the server's models and picks the first when none is chosen. An address off this Mac gets a warning,
/// since the meeting text would go to that computer.
struct LocalServerSetup: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.rowStyle) private var style
    @State private var state: CheckState = .idle

    enum CheckState: Equatable { case idle, checking, found(Int), failed(FriendlyError) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Server").font(.system(size: style.titleSize, weight: .medium)).foregroundStyle(Palette.ink)
                    RowLink(text: "Get Ollama", destination: LocalServer.getOllama, spoken: "Get Ollama on its website")
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
        .padding(.vertical, style.padding)
        .onChange(of: controller.localServerURL) { _, _ in state = .idle }
    }

    private var checkButton: some View {
        Button(action: check) {
            if state == .checking { ProgressView().controlSize(.small).frame(width: 40) } else { Text("Check") }
        }
        .rowButton()
        .disabled(state == .checking)
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
