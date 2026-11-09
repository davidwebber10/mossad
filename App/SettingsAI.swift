import AppKit
import MossadCore
import SwiftUI

/// Settings › AI: the transcription and AI providers with their ratings and keys, and the commands that let
/// other AI apps read the meetings.
struct AISettings: View {
    @EnvironmentObject var controller: AppController
    @State private var editingKey: APIKey?

    var body: some View {
        LabelColumnStack {
            SettingsGroup(label: "Providers", footer: "Keys are stored in the Keychain. Each provider bills your own account.") {
                transcription
                if let key = controller.transcriptionProvider.key {
                    keyRow(controller.transcriptionProvider.displayName, "Transcribes your calls after they end", key)
                }
                ai
                keyRow(controller.aiProvider.displayName, "Answers with your chosen model", controller.aiProvider.key)
                if controller.liveTranscriptEnabled, controller.transcriptionProvider != .assemblyai {
                    keyRow("AssemblyAI", "The live transcript while recording uses AssemblyAI", .assemblyai)
                }
            }
            SettingsGroup(label: "Use your meetings in other AI apps",
                          footer: "Read-only. Claude Code, Claude Desktop, and other MCP apps can search and read your meetings, the same way the Chat tab does. Mossad does not need to be open.") {
                MCPSetup()
            }
        }
        .sheet(item: $editingKey) { key in KeySheet(key: key) }
    }

    private var transcription: some View {
        ProviderRow(title: "Transcription", detail: controller.transcriptionProvider.note) {
            FillPicker(title: "Transcription provider", selection: $controller.transcriptionProvider,
                       choices: TranscriptionProvider.allCases.map { ($0, $0.displayName) })
            if controller.transcriptionProvider.models.count > 1 {
                FillPicker(title: "Transcription model", selection: $controller.transcriptionModel,
                           choices: controller.transcriptionProvider.models.map { ($0.id, $0.name) })
            }
        } rating: {
            RatingView(rating: controller.transcriptionProvider.rating, aspects: Rating.transcriptionAspects)
        }
        .onChange(of: controller.transcriptionProvider) { _, p in
            controller.transcriptionModel = p.models.first?.id ?? ""
            controller.rebuildPipeline()
        }
    }

    private var ai: some View {
        ProviderRow(title: "AI", detail: "Summaries, the coach, the weekly email, and chat") {
            FillPicker(title: "AI provider", selection: $controller.aiProvider,
                       choices: AIProvider.allCases.map { ($0, $0.displayName) })
            ModelPicker(provider: controller.aiProvider, model: $controller.aiModel)
        } rating: {
            if let rating = Rating.model(controller.aiModel.isEmpty ? controller.aiProvider.defaultModel : controller.aiModel, provider: controller.aiProvider)
                ?? (controller.aiProvider == .openrouter ? controller.openRouterRating : nil) {
                RatingView(rating: rating, aspects: Rating.modelAspects)
            }
        }
        .onChange(of: controller.aiProvider) { _, _ in
            controller.aiModel = ""
            controller.rebuildPipeline()
        }
        .onChange(of: controller.aiModel) { _, _ in controller.rebuildPipeline() }
    }

    private func keyRow(_ title: String, _ detail: String, _ key: APIKey) -> some View {
        SettingsRow(title: title, detail: detail) {
            KeyStatus(key: key) { editingKey = $0 }
        }
    }
}

/// A provider: its name with the menus beside it, what it does, and its ratings across the full width.
private struct ProviderRow<Pickers: View, Ratings: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var pickers: Pickers
    @ViewBuilder var rating: Ratings

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: Space.m) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink).padding(.top, 3)
                Spacer(minLength: Space.m)
                HStack(spacing: 6) { pickers }
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, -6)
            rating.padding(.top, 4)
        }
        .padding(.vertical, 9)
    }
}

/// Stars for each aspect and the price level; the tooltip says what they rest on.
private struct RatingView: View {
    let rating: Rating
    let aspects: [String]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(aspects.filter { rating.stars[$0] != nil }, id: \.self) { aspect in
                let stars = rating.stars[aspect] ?? 0
                HStack(spacing: 5) {
                    Text(aspect)
                    Text("\(Text(String(repeating: "★", count: stars)))\(Text(String(repeating: "★", count: max(0, 5 - stars))).foregroundStyle(Palette.ring))")
                        .tracking(1)
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(aspect): \(stars) of 5")
            }
            if rating.free {
                Text("Free").fontWeight(.semibold).foregroundStyle(Palette.okText)
            } else if rating.price > 0 {
                Text("\(Text(rating.dollars))\(Text(String(repeating: "$", count: 4 - rating.price)).foregroundStyle(Palette.ring))")
                    .accessibilityLabel("Price level \(rating.price) of 4")
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Palette.secondary)
        .help(rating.basis)
    }
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

    var body: some View {
        let current = model.isEmpty ? provider.defaultModel : model
        Group {
            if provider == .openrouter {
                HStack(spacing: 6) {
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
            } else {
                let list = models.contains { $0.id == current } || current.isEmpty ? models : [ModelInfo(id: current, name: current)] + models
                FillPicker(title: "Model", selection: Binding(get: { current }, set: { model = $0 }),
                           choices: list.isEmpty ? [(current, current)] : list.map { ($0.id, label($0)) })
            }
        }
        .task(id: "\(provider.rawValue)-\(controller.hasKey(provider.key))") {
            defer { if provider == .openrouter { controller.openRouterRating = models.first { $0.id == model }.flatMap { Rating.model($0, provider: .openrouter) } } }
            models = (try? await ModelCatalog.fetch(provider, apiKey: controller.keychain.get(provider.key))) ?? []
        }
    }
}

/// The commands that connect other AI apps to Mossad's MCP server.
private struct MCPSetup: View {
    private var binary: String { Bundle.main.executablePath ?? "/Applications/Mossad.app/Contents/MacOS/Mossad" }
    private var claudeCode: String { "claude mcp add --scope user mossad -- \"\(binary)\" --mcp" }
    private var desktop: String { "\"mossad\": { \"command\": \"\(binary)\", \"args\": [\"--mcp\"] }" }

    var body: some View {
        row("Claude Code", "Run this once in Terminal:", claudeCode)
        row("Claude Desktop", "Add this inside \"mcpServers\" in claude_desktop_config.json:", desktop)
    }

    private func row(_ title: String, _ hint: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
            Text(hint).font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.top, 2).padding(.bottom, 6)
            CopyField(text: text)
        }
        .padding(.vertical, 9)
    }
}
