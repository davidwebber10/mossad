import Foundation

/// "Opus Latest" and the like: a saved choice that follows the newest model of a family, resolved from the
/// provider's own list.
public enum LatestModel {
    public static let prefix = "latest:"

    public struct Alias: Sendable, Equatable {
        public let id: String
        public let name: String
        /// The id when the list is not known yet; nil uses the provider's default.
        let fallback: String?
    }

    public static func aliases(for provider: AIProvider) -> [Alias] {
        switch provider {
        case .anthropic: [
            Alias(id: "latest:opus", name: "Opus Latest", fallback: "claude-opus-5-5"),
            Alias(id: "latest:fable", name: "Fable Latest", fallback: "claude-fable-5-1"),
            Alias(id: "latest:sonnet", name: "Sonnet Latest", fallback: "claude-sonnet-5-5"),
            Alias(id: "latest:haiku", name: "Haiku Latest", fallback: "claude-haiku-5-5"),
        ]
        case .openai: [
            Alias(id: "latest:gpt", name: "GPT Latest", fallback: nil),
            Alias(id: "latest:gpt-mini", name: "GPT Mini Latest", fallback: nil),
            Alias(id: "latest:gpt-nano", name: "GPT Nano Latest", fallback: nil),
        ]
        case .openrouter: []
        }
    }

    public static func isAlias(_ name: String) -> Bool { name.hasPrefix(prefix) }

    /// The newest model of the alias's family in the provider's list, or nil when none matches.
    public static func resolve(_ alias: String, in models: [ModelInfo]) -> String? {
        let ids = models.map(\.id)
        switch alias {
        // Anthropic lists the newest first.
        case "latest:opus": return ids.first { claude($0, "opus") }
        case "latest:fable": return ids.first { claude($0, "fable") }
        case "latest:sonnet": return ids.first { claude($0, "sonnet") }
        case "latest:haiku": return ids.first { claude($0, "haiku") }
        case "latest:gpt": return newestGPT(models) { !$0.contains("-mini") && !$0.contains("-nano") }
        case "latest:gpt-mini": return newestGPT(models) { $0.contains("-mini") }
        case "latest:gpt-nano": return newestGPT(models) { $0.contains("-nano") }
        default: return nil
        }
    }

    private static func claude(_ id: String, _ family: String) -> Bool {
        id.hasPrefix("claude-") && id.contains("-\(family)-")
    }

    /// Newest by `created`; on a tie the shorter id, so "gpt-6.1-sol" wins over its dated snapshot. Pro models
    /// cost many times more and are left out.
    private static func newestGPT(_ models: [ModelInfo], _ family: (String) -> Bool) -> String? {
        models.filter { m in
            m.id.hasPrefix("gpt-") && !m.id.contains("-pro") && family(m.id)
                && !ModelCatalog.openAIExclusions.contains { m.id.contains($0) }
        }
        .min { a, b in
            let ca = a.created ?? 0, cb = b.created ?? 0
            return ca != cb ? ca > cb : a.id.count < b.id.count
        }?.id
    }
}

/// The last resolved id of each alias, per provider, kept in UserDefaults so a restart does not fall back.
public final class LatestModelCache: @unchecked Sendable {
    public static let shared = LatestModelCache(defaults: .standard)

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var ids: [String: [String: String]]
    private var refreshed: [String: Date]

    private static let idsKey = "latestModelIDs"
    private static let refreshedKey = "latestModelsRefreshed"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        ids = defaults.dictionary(forKey: Self.idsKey) as? [String: [String: String]] ?? [:]
        refreshed = defaults.dictionary(forKey: Self.refreshedKey) as? [String: Date] ?? [:]
    }

    public func id(_ alias: String, provider: AIProvider) -> String? {
        lock.withLock { ids[provider.rawValue]?[alias] }
    }

    /// Resolves every alias of the provider from its list. An empty list keeps what is known. True when an id changed.
    @discardableResult
    public func update(_ provider: AIProvider, models: [ModelInfo], now: Date = Date()) -> Bool {
        guard !models.isEmpty else { return false }
        var found: [String: String] = [:]
        for alias in LatestModel.aliases(for: provider) {
            if let id = LatestModel.resolve(alias.id, in: models) { found[alias.id] = id }
        }
        return lock.withLock {
            let changed = ids[provider.rawValue] ?? [:] != found
            ids[provider.rawValue] = found
            refreshed[provider.rawValue] = now
            defaults.set(ids, forKey: Self.idsKey)
            defaults.set(refreshed, forKey: Self.refreshedKey)
            return changed
        }
    }

    /// True when the provider's list has not been read in the last day.
    public func needsRefresh(_ provider: AIProvider, now: Date = Date()) -> Bool {
        lock.withLock { refreshed[provider.rawValue].map { now.timeIntervalSince($0) > 86_400 } ?? true }
    }

    /// Reads the provider's list and resolves the aliases. True when an id changed.
    public func refresh(_ provider: AIProvider, apiKey: String?) async -> Bool {
        guard !LatestModel.aliases(for: provider).isEmpty,
              let models = try? await ModelCatalog.fetch(provider, apiKey: apiKey) else { return false }
        return update(provider, models: models)
    }
}

extension AIProvider {
    /// The model id a request uses: an alias's newest known model (or its fallback), the default for an empty
    /// choice, and any other id as it is.
    public func resolvedModel(_ name: String, cache: LatestModelCache = .shared) -> String {
        if name.isEmpty { return defaultModel }
        guard LatestModel.isAlias(name) else { return name }
        guard let alias = LatestModel.aliases(for: self).first(where: { $0.id == name }) else { return defaultModel }
        return cache.id(name, provider: self) ?? alias.fallback ?? defaultModel
    }
}
