import AppKit
import MossadCore
import SwiftUI

/// Settings › AI: a group for each job, Transcription and Notes, with its provider, model, ratings, and key; what
/// an hour of meetings costs; and the commands that let other AI apps read the meetings. The provider rows are
/// the ones setup shows (`ProviderRows.swift`).
struct AISettings: View {
    @EnvironmentObject var controller: AppController
    @StateObject private var keys = KeyChecker()
    @State private var editingKey: APIKey?

    var body: some View {
        LabelColumnStack {
            SettingsGroup(label: ProviderJob.transcription.title) {
                TranscriptionRows(keys: keys, ratings: true, edit: edit)
                if controller.liveTranscriptEnabled, controller.transcriptionProvider != .assemblyai {
                    KeyRow(keys: keys, key: .assemblyai, service: .assemblyai, detail: "For the live transcript.",
                           page: KeyCheck.Service.assemblyai.keysPage, edit: edit)
                }
            }
            SettingsGroup(label: ProviderJob.notes.title, footer: "Mossad keeps each key in the macOS Keychain and never shows it again.") {
                NotesRows(keys: keys, ratings: true, edit: edit)
            }
            // Every part that a provider bills with the choices as they are now: the live transcript and the coach
            // are in it while they are on.
            SettingsGroup(label: "Cost", footer: "An estimate from list prices, for one call of an hour. Each provider bills your own account. Chat, and the coach’s questions and briefs, are not in it.") {
                let cost = controller.hourCost
                ChoiceRow(title: "An hour of meetings", detail: [cost.detail, cost.emailDetail].compactMap { $0 }.joined(separator: " ")) {
                    // As tall as a control, so the line under it sits where it does in the other rows.
                    Text(cost.headline).font(.system(size: Rhythm.bodySize, weight: .medium)).monospacedDigit().foregroundStyle(Palette.ink)
                        .fixedSize()
                        .frame(height: 24)
                }
                .accessibilityElement(children: .combine)
            }
            SettingsGroup(label: "Other AI apps",
                          footer: "Read-only. Claude Code, Claude Desktop, and other MCP apps can search and read your meetings, the same way the Chat tab does. Mossad does not need to be open.") {
                MCPSetup()
            }
        }
        .sheet(item: $editingKey) { key in KeySheet(key: key) }
        // A check's result is for the key it tried, not for the one the sheet saved.
        .onChange(of: editingKey) { old, new in if new == nil, let old { keys.forget(old) } }
    }

    private func edit(_ key: APIKey) { editingKey = key }
}

/// The model menu for the AI provider, filled from the provider's own list. OpenRouter has hundreds of
/// models, so it gets a field to type in with a filtered menu beside it.
struct ModelPicker: View {
    @EnvironmentObject var controller: AppController
    let provider: AIProvider
    @Binding var model: String
    @State private var models: [ModelInfo] = []

    /// "Claude Opus 5.5 · $$$".
    private func label(_ m: ModelInfo) -> String {
        guard let r = Rating.model(m, provider: provider), r.price > 0 else { return m.name }
        return "\(m.name) · \(r.dollars)"
    }

    /// "Opus Latest · Claude Opus 5.5": the model the alias asks for now.
    private func label(_ alias: LatestModel.Alias) -> String {
        let id = provider.resolvedModel(alias.id)
        return "\(alias.name) · \(models.first { $0.id == id }?.name ?? id)"
    }

    var body: some View {
        let current = model.isEmpty ? provider.defaultModel : model
        Group {
            if provider == .openrouter {
                HStack(spacing: Space.s) {
                    TextField("Model", text: $model, prompt: Text("provider/model")).textFieldStyle(SettingsFieldStyle(width: 190, monospaced: true))
                    Menu {
                        let q = model.lowercased()
                        let matches = models.filter { q.isEmpty || $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q) }
                        ForEach(Array((matches.isEmpty ? models : matches).prefix(60))) { m in
                            Button(label(m)) { model = m.id; controller.openRouterRating = Rating.model(m, provider: .openrouter) }
                        }
                    } label: {
                        FillMenuLabel(text: "Choose")
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .disabled(models.isEmpty)
                }
            } else if provider == .localServer, models.isEmpty, current.isEmpty {
                Text("Check the server for its models").font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary)
            } else {
                let known = models.contains { $0.id == current } || current.isEmpty || LatestModel.isAlias(current)
                let list = known ? models : [ModelInfo(id: current, name: current)] + models
                let fallback = LatestModel.isAlias(current) ? [] : [(current, current)]
                FillPicker(title: "Model", selection: Binding(get: { current }, set: { model = $0 }),
                           choices: list.isEmpty ? fallback : list.map { ($0.id, label($0)) },
                           leading: LatestModel.aliases(for: provider).map { ($0.id, label($0)) })
            }
        }
        .task(id: "\(provider.rawValue)-\(provider.key.map(controller.hasKey) ?? false)-\(provider == .localServer ? "\(controller.localServerURL)-\(controller.localServerChecks)" : "")") {
            defer { if provider == .openrouter { controller.openRouterRating = models.first { $0.id == model }.flatMap { Rating.model($0, provider: .openrouter) } } }
            let fetched = (try? await ModelCatalog.fetch(provider, apiKey: provider.key.flatMap { controller.keychain.get($0) },
                                                         serverURL: controller.localServerBase)) ?? []
            // A local server's models are all its own: the first one serves until the owner picks.
            if provider == .localServer, model.isEmpty, let first = fetched.first { model = first.id }
            // The list read here is as new as any, so the "Latest" choices follow it at once.
            if LatestModelCache.shared.update(provider, models: fetched), LatestModel.isAlias(model) { controller.rebuildPipeline() }
            models = fetched
        }
    }
}

/// The commands that connect other AI apps to Mossad's MCP server.
private struct MCPSetup: View {
    private var binary: String { DevHooks.shownBinary(Bundle.main.executablePath ?? "/Applications/Mossad.app/Contents/MacOS/Mossad") }
    private var claudeCode: String { "claude mcp add --scope user mossad -- \"\(binary)\" --mcp" }
    private var desktop: String { "\"mossad\": { \"command\": \"\(binary)\", \"args\": [\"--mcp\"] }" }

    var body: some View {
        row("Claude Code", "Run this once in Terminal:", claudeCode)
        row("Claude Desktop", "Add this inside \"mcpServers\" in claude_desktop_config.json:", desktop)
    }

    private func row(_ title: String, _ hint: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: Rhythm.bodySize, weight: .medium)).foregroundStyle(Palette.ink)
            Text(hint).font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary).padding(.top, 2).padding(.bottom, 6)
            CopyField(text: text)
        }
        .padding(.vertical, 9)
    }
}
