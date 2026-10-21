import AVFoundation
import MossadCore
import SwiftUI

/// Plays one meeting: the compressed recording, or both raw tracks mixed live when it does not exist yet.
@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var time: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var rate: Float = 1 {
        didSet { if isPlaying { player.rate = rate } }
    }
    @Published private(set) var isAvailable = false

    private let player = AVPlayer()
    // Only touched on the main actor and in deinit, when nothing else can reach them.
    nonisolated(unsafe) private var observer: Any?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?

    init(callDirectory dir: URL) {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.time = t.seconds.isFinite ? t.seconds : 0 }
        }
        Task { await load(dir) }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    private func load(_ dir: URL) async {
        let recording = Recording.url(in: dir)
        let asset: AVAsset
        if FileManager.default.fileExists(atPath: recording.path) {
            asset = AVURLAsset(url: recording)
        } else {
            let composition = AVMutableComposition()
            for track in [Track.me, .them] {
                let url = dir.appendingPathComponent(track.fileName)
                guard FileManager.default.fileExists(atPath: url.path),
                      let source = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first,
                      let range = try? await source.load(.timeRange),
                      let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                try? target.insertTimeRange(range, of: source, at: .zero)
            }
            guard !composition.tracks.isEmpty else { return }
            asset = composition
        }
        let seconds: Double
        do { seconds = try await asset.load(.duration).seconds } catch {
            Log.error("Loading audio for \(dir.lastPathComponent) failed: \(error)")
            return
        }
        guard seconds > 0 else { return }
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
        duration = seconds
        isAvailable = true
    }

    /// Streams the recording from the cloud archive when no local audio exists.
    func loadRemote(_ url: URL) async {
        guard !isAvailable else { return }
        let asset = AVURLAsset(url: url)
        guard let seconds = try? await asset.load(.duration).seconds, seconds > 0 else {
            Log.error("The archived recording could not be loaded")
            return
        }
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
        duration = seconds
        isAvailable = true
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        if duration > 0, time >= duration - 0.5 { seek(to: 0) }
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        let t = max(0, min(seconds, duration))
        time = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ seconds: TimeInterval) { seek(to: time + seconds) }

    /// Moves to a transcript line and plays from there.
    func play(from seconds: TimeInterval) {
        seek(to: seconds)
        play()
    }
}
