import AppKit
import MossadCore
import SwiftUI

/// The rows of the two provider jobs, Transcription and Notes: one row for the provider, one for the model, and
/// one for the key. Setup's AI step and Settings › AI both show these rows, each inside its own group, so a
/// change to one shows in the other.

/// Tries keys with one free request, and keeps each result while its window is open.
@MainActor
final class KeyChecker: ObservableObject {
    enum State: Equatable {
        case idle, checking, passed
        case failed(FriendlyError)
    }

    @Published private var states: [APIKey: State] = [:]

    func state(_ key: APIKey) -> State { states[key] ?? .idle }

    /// A result says nothing about the next key.
    func forget(_ key: APIKey) { states[key] = nil }
    func reset() { states = [:] }

    /// A typed key that works is saved to the Keychain. Without one, the saved key is tried and nothing is written.
    func check(_ service: KeyCheck.Service, typed: String? = nil, key apiKey: APIKey, controller: AppController) {
        let key = (typed ?? controller.keychain.get(apiKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        states[apiKey] = .checking
        Task {
            do {
                try await KeyCheck.run(service, key: key)
                guard typed != nil else {
                    states[apiKey] = .passed
                    return
                }
                do {
                    try controller.keychain.set(key, for: apiKey)
                    controller.rebuildPipeline()
                    states[apiKey] = .passed
                    controller.keysChanged()
                } catch {
                    Log.error("Saving the \(apiKey.rawValue) key failed")
                    states[apiKey] = .failed(FriendlyError(error, context: .checkingKey, service: "the Keychain"))
                }
            } catch {
                Log.error("Checking the \(service.displayName) key failed: \(FriendlyError(error, context: .checkingKey).technical)")
                states[apiKey] = .failed(FriendlyError(error, context: .checkingKey, service: service.displayName))
            }
        }
    }
}

// MARK: Transcription

struct TranscriptionRows: View {
    @EnvironmentObject var controller: AppController
    @ObservedObject var keys: KeyChecker
    /// Settings shows the stars; setup keeps to the choice.
    var ratings = false
    var edit: ((APIKey) -> Void)?
    @Environment(\.rowStyle) private var style

    var body: some View {
        let provider = controller.transcriptionProvider
        ChoiceRow(title: "Provider", detail: [ProviderJob.transcription.detail, provider == .local ? nil : provider.note]
            .compactMap { $0 }.joined(separator: " ")) {
            FillPicker(title: "Transcription provider", selection: $controller.transcriptionProvider,
                       choices: TranscriptionProvider.allCases.map { ($0, $0.displayName) })
        } below: {
            if ratings { RatingView(rating: provider.rating, aspects: Rating.transcriptionAspects) }
        }
        .onChange(of: controller.transcriptionProvider) { _, p in
            controller.transcriptionModel = p.models.first?.id ?? ""
            controller.rebuildPipeline()
        }
        .onChange(of: controller.transcriptionModel) { _, _ in controller.rebuildPipeline() }
        // Only the local models differ enough to need their own line.
        ChoiceRow(title: "Model", detail: provider == .local ? provider.note(model: controller.transcriptionModel) : nil) {
            if provider.models.count > 1 {
                FillPicker(title: "Transcription model", selection: $controller.transcriptionModel,
                           choices: provider.models.map { ($0.id, $0.name) })
            } else {
                Text(provider.models.first?.name ?? "Default").font(.system(size: style.detailSize)).foregroundStyle(Palette.secondary)
            }
        }
        if let key = provider.key, let service = KeyCheck.Service(provider) {
            KeyRow(keys: keys, key: key, service: service, page: service.keysPage, edit: edit).id(key)
        } else {
            HStack(spacing: Space.s) {
                PassLine(text: "No key needed")
                Text("It runs on this Mac. The model downloads once, on first use.")
                    .font(.system(size: style.detailSize)).foregroundStyle(Palette.secondary)
            }
            .padding(.vertical, style.padding)
        }
    }
}

// MARK: Notes

struct NotesRows: View {
    @EnvironmentObject var controller: AppController
    @ObservedObject var keys: KeyChecker
    var ratings = false
    var edit: ((APIKey) -> Void)?
    @Environment(\.rowStyle) private var style

    private var rating: Rating? {
        Rating.model(controller.aiProvider.resolvedModel(controller.aiModel), provider: controller.aiProvider)
            ?? (controller.aiProvider == .openrouter ? controller.openRouterRating : nil)
    }

    var body: some View {
        let provider = controller.aiProvider
        ChoiceRow(title: "Provider", detail: [ProviderJob.notes.detail, provider.note].compactMap { $0 }.joined(separator: " ")) {
            FillPicker(title: "Notes provider", selection: $controller.aiProvider,
                       choices: AIProvider.allCases.map { ($0, $0.displayName) })
        }
        .onChange(of: controller.aiProvider) { _, _ in
            controller.aiModel = ""
            controller.rebuildPipeline()
        }
        .onChange(of: controller.aiModel) { _, _ in controller.rebuildPipeline() }
        // The provider's own list once its key is saved, with the price.
        ChoiceRow(title: "Model") {
            ModelPicker(provider: provider, model: $controller.aiModel)
        } below: {
            if ratings, let rating { RatingView(rating: rating, aspects: Rating.modelAspects) }
        }
        switch provider {
        case .localServer:
            LocalServerSetup()
            // Setup leaves this out: a server on this Mac asks for no key.
            if edit != nil {
                KeyRow(keys: keys, key: .localServer, detail: "Only when the server asks for one.", optional: true, edit: edit)
            }
        case .apple:
            appleRow
        case .anthropic, .openai, .openrouter:
            if let key = provider.key, let service = KeyCheck.Service(provider) {
                KeyRow(keys: keys, key: key, service: service, page: service.keysPage, edit: edit).id(key)
            }
        }
    }

    /// Whether Apple's on-device model can run here, and why not when it cannot.
    private var appleRow: some View {
        let reason = AppleModelInfo.unavailableReason()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Space.m) {
                SettingsRowText(title: "Apple Intelligence", detail: "No key needed. The model runs on this Mac, and nothing leaves it.")
                Spacer(minLength: Space.m)
                if reason == nil { PassLine(text: "Ready on this Mac") }
            }
            if let reason { InlineError(error: FriendlyError(reason, context: .general)) }
        }
        .padding(.vertical, style.padding)
    }
}

// MARK: The key

/// A provider's key: its name with "Get a key", whether one is saved, Check, and Change. The key never shows.
struct KeyRow: View {
    @EnvironmentObject var controller: AppController
    @ObservedObject var keys: KeyChecker
    let key: APIKey
    /// The provider's free request; nil for a key that no such request can try.
    var service: KeyCheck.Service?
    var detail: String?
    /// A key the provider can work without: its absence asks for nothing.
    var optional = false
    var page: URL?
    /// Settings changes a key in its sheet, and saves it as typed. Without this the field is in the row, and a
    /// key is saved when its check passes.
    var edit: ((APIKey) -> Void)?
    @State private var typed = ""
    @State private var replacing = false
    @Environment(\.rowStyle) private var style

    var body: some View {
        let state = keys.state(key)
        let saved = controller.hasKey(key)
        VStack(alignment: .leading, spacing: style == .setup ? 10 : 6) {
            HStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsRowText(title: key.displayName, titleNote: optional ? "optional" : nil).fixedSize()
                    // What the key is for and where to get one, on one line when there is room for both.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { about(saved: saved) }
                        VStack(alignment: .leading, spacing: 2) { about(saved: saved) }
                    }
                }
                Spacer(minLength: Space.m)
                if edit == nil, !saved || replacing {
                    field(state)
                } else {
                    status(state, saved: saved)
                }
            }
            if case .failed(let error) = state { InlineError(error: error) }
        }
        .padding(.vertical, style.padding)
        .onChange(of: state) { _, s in if s == .passed { replacing = false; typed = "" } }
    }

    @ViewBuilder
    private func about(saved: Bool) -> some View {
        if let detail {
            Text(detail).font(.system(size: style.detailSize)).foregroundStyle(Palette.secondary).fixedSize()
        }
        if let page {
            RowLink(text: "Get a key", destination: page, quiet: edit != nil && saved,
                    spoken: "Get a \(key.displayName) on its website")
                .fixedSize()
        }
    }

    @ViewBuilder
    private func status(_ state: KeyChecker.State, saved: Bool) -> some View {
        let status = KeyCheck.Status(saved: saved, passed: state == .passed)
        switch status {
        case .works: PassLine(text: status.label)
        case .saved: Text(status.label).font(.system(size: style.detailSize)).foregroundStyle(Palette.secondary)
        case .missing: Text(status.label).font(.system(size: style.detailSize)).foregroundStyle(optional ? Palette.secondary : Palette.accent)
        }
        if let service, status == .saved {
            Button { keys.check(service, key: key, controller: controller) } label: {
                if state == .checking { ProgressView().controlSize(.small).frame(width: 36) } else { Text("Check") }
            }
            .rowButton()
            .disabled(state == .checking)
            .help("Tries the saved key with one free request.")
            .accessibilityLabel("Check the \(key.displayName)")
        }
        Button(saved ? "Change" : "Set key…") {
            if let edit { edit(key) } else { replacing = true; typed = "" }
        }
        .rowButton(accent: !saved && !optional)
        .accessibilityLabel(saved ? "Change the \(key.displayName)" : "Set the \(key.displayName)")
    }

    @ViewBuilder
    private func field(_ state: KeyChecker.State) -> some View {
        SecureField(key.displayName, text: $typed, prompt: Text("Paste the key"))
            .textFieldStyle(SheetFieldStyle(monospaced: true))
            .frame(width: 250)
            .onSubmit(check)
        Button("Paste") { typed = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? typed }
            .rowButton()
        Button(action: check) {
            if state == .checking { ProgressView().controlSize(.small).frame(width: 40) } else { Text("Check") }
        }
        .rowButton(accent: true)
        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty || state == .checking)
    }

    private func check() {
        guard let service else { return }
        keys.check(service, typed: typed, key: key, controller: controller)
    }
}

// MARK: Ratings

/// Stars for each aspect and the price level; the tooltip says what they rest on.
struct RatingView: View {
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
