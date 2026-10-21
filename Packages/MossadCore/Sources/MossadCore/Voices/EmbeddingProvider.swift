import FluidAudio
import Foundation

/// Turns 16 kHz mono speech into a voice fingerprint.
public protocol EmbeddingProvider: Sendable {
    func embedding(for samples: [Float]) async throws -> [Float]
}

/// On-device speaker embeddings from FluidAudio's CoreML models (downloaded once on first use).
public actor FluidEmbeddingProvider: EmbeddingProvider {
    private var manager: DiarizerManager?

    public init() {}

    public func embedding(for samples: [Float]) async throws -> [Float] {
        let manager = try await loadedManager()
        return try manager.extractSpeakerEmbedding(from: samples)
    }

    private func loadedManager() async throws -> DiarizerManager {
        if let manager { return manager }
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager()
        manager.initialize(models: models)
        self.manager = manager
        Log.info("Voice models loaded")
        return manager
    }
}
