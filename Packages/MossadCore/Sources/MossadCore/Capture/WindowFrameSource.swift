#if os(macOS)
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// Pictures of the call's own window through ScreenCaptureKit: one stream with a single-window filter, a frame each
/// 3 s at most, on the screen queue. It never captures a display or another app's window, and it stops as soon as
/// the window's title no longer shows the meeting (in a browser, the owner chose another tab).
///
/// It needs the Screen & System Audio Recording permission and never asks for it: without it, nothing is found.
public final class WindowFrameSource: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let frameInterval: TimeInterval = 3
    static let longEdge = 1600
    /// How often the window list is read while there is no good window, and while there is one.
    static let searchInterval: TimeInterval = 10
    static let reviewInterval: TimeInterval = 30

    private let platform: Platform
    private let bundleID: String
    private let meetingID: String?
    private let queue = ScreenRecorder.queue

    /// What other threads read.
    private struct Shared {
        var active = false
        var window: CGWindowID?
    }
    private let shared = NSLock()
    private var sharedState = Shared()

    // The rest only on `queue`.
    private var handler: ((FrameEvent) -> Void)?
    private var generation = 0
    private var stream: SCStream?
    private var chosen: (id: CGWindowID, owner: String, kind: MeetingWindow.Kind, size: CGSize)?
    private var teamsNames: Set<String> = []
    private var searching = false
    private var lastSearch = Date.distantPast
    private var timer: DispatchSourceTimer?

    public init(platform: Platform, bundleID: String, meetingID: String?) {
        self.platform = platform
        self.bundleID = bundleID
        self.meetingID = meetingID
    }

    public func start(_ handler: @escaping (FrameEvent) -> Void) {
        shared.withLock { sharedState.active = true }
        nonisolated(unsafe) let handler = handler
        queue.async { [self] in
            generation += 1
            self.handler = handler
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
            t.setEventHandler { [weak self] in self?.review() }
            t.resume()
            timer = t
            search()
        }
    }

    public func stop() {
        shared.withLock { sharedState.active = false }
        queue.async { [self] in
            generation += 1
            handler = nil
            timer?.cancel()
            timer = nil
            dropStream()
        }
    }

    public var windowOnScreen: Bool? {
        guard let id = shared.withLock({ sharedState.window }) else { return nil }
        guard let now = Self.describe(id) else {
            queue.async { [weak self] in self?.windowChanged(id) }
            return nil
        }
        return now.onScreen
    }

    // MARK: Finding the window

    /// Reads the window list again when there is no window, when the window is hidden or is only a small view
    /// (the meeting's own window may be back), and now and then for a better window (a popped-out share).
    private func review() {
        let age = Date().timeIntervalSince(lastSearch)
        guard let chosen else {
            if age >= Self.searchInterval { search() }
            return
        }
        let hidden = Self.describe(chosen.id)?.onScreen != true
        if age >= (hidden || chosen.kind == .small ? Self.searchInterval : Self.reviewInterval) { search() }
    }

    private func search() {
        guard !searching, shared.withLock({ sharedState.active }) else { return }
        searching = true
        lastSearch = Date()
        let generation = generation
        let queue = queue
        Task.detached(priority: .utility) { [weak self] in
            // Windows on every Space, also ones that are not on screen.
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            queue.async { [weak self] in self?.found(content, generation: generation) }
        }
    }

    private func found(_ content: SCShareableContent?, generation: Int) {
        searching = false
        guard generation == self.generation, let content else { return }
        var byID: [CGWindowID: SCWindow] = [:]
        let candidates = content.windows.compactMap { w -> WindowCandidate? in
            guard let app = w.owningApplication else { return nil }
            byID[w.windowID] = w
            return WindowCandidate(id: w.windowID, bundleID: app.bundleIdentifier, title: w.title ?? "", width: w.frame.width,
                                   height: w.frame.height, onScreen: w.isOnScreen, layer: w.windowLayer)
        }
        guard let best = MeetingWindow.choose(candidates, platform: platform, bundleID: bundleID, meetingID: meetingID),
              let window = byID[best.id],
              let kind = MeetingWindow.kind(of: best, among: candidates, platform: platform, bundleID: bundleID) else {
            if chosen != nil { dropStream() }
            return
        }
        teamsNames = Set(candidates.compactMap { MeetingWindow.teamsMeetingName($0.title) })
        if chosen?.id == best.id, stream != nil { return }
        dropStream()
        begin(window, candidate: best, kind: kind)
    }

    private func begin(_ window: SCWindow, candidate: WindowCandidate, kind: MeetingWindow.Kind) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = max(1, Double(filter.pointPixelScale))
        let size = Self.fit(width: window.frame.width * scale, height: window.frame.height * scale)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.scalesToFit = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(seconds: Self.frameInterval, preferredTimescale: 600)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            // Frames arrive on the screen queue and are handled there, with no hop in between.
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            Log.error("The screen capture could not start: \(error.localizedDescription)")
            return
        }
        self.stream = stream
        chosen = (candidate.id, candidate.bundleID, kind, window.frame.size)
        shared.withLock { sharedState.window = candidate.id }
        Log.info("Capturing the meeting window (\(candidate.bundleID), \(Int(window.frame.width)) x \(Int(window.frame.height)))")
        stream.startCapture { [weak self] error in
            guard let error else { return }
            Log.error("The screen capture could not start: \(error.localizedDescription)")
            self?.queue.async { [weak self] in if self?.stream === stream { self?.dropStream() } }
        }
    }

    private func dropStream() {
        if let stream { stream.stopCapture { _ in } }
        stream = nil
        chosen = nil
        shared.withLock { sharedState.window = nil }
    }

    /// The window is gone or shows something else: stop now, and look for the meeting's window again.
    private func windowChanged(_ id: CGWindowID) {
        guard chosen?.id == id else { return }
        dropStream()
        search()
    }

    /// The window as it is now, with one cheap request for this window only. Nil when it is gone.
    private static func describe(_ id: CGWindowID) -> (title: String, onScreen: Bool, size: CGSize, layer: Int)? {
        let ids = [id as CFNumber] as CFArray
        guard let list = CGWindowListCreateDescriptionFromArray(ids) as? [[CFString: Any]], let info = list.first else { return nil }
        let bounds = (info[kCGWindowBounds] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
        return (info[kCGWindowName] as? String ?? "", info[kCGWindowIsOnscreen] as? Bool ?? false, bounds.size, info[kCGWindowLayer] as? Int ?? 0)
    }

    /// True while the chosen window still shows the meeting, at the size the stream was made for.
    private func stillValid() -> Bool {
        guard let chosen, let now = Self.describe(chosen.id) else { return false }
        let window = WindowCandidate(id: chosen.id, bundleID: chosen.owner, title: now.title, width: now.size.width,
                                     height: now.size.height, onScreen: now.onScreen, layer: now.layer)
        guard MeetingWindow.stillMeeting(window, platform: platform, bundleID: bundleID, meetingNames: teamsNames) else { return false }
        // A window that changed its size much gets a new stream of the right size.
        let was = max(chosen.size.width, chosen.size.height), nowLong = max(now.size.width, now.size.height)
        return was > 0 && abs(nowLong - was) / was <= 0.15
    }

    // MARK: Frames

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, stream === self.stream, sampleBuffer.isValid, shared.withLock({ sharedState.active }),
              let handler else { return }
        switch Self.status(of: sampleBuffer) {
        case .complete:
            // Checked for each frame: one click on another tab makes the same window show something else.
            guard stillValid() else {
                if let id = chosen?.id { windowChanged(id) }
                return
            }
            guard let buffer = sampleBuffer.imageBuffer, let chosen else { return }
            handler(.picture(PixelPicture(buffer: buffer), window: "\(chosen.owner)#\(chosen.id)"))
        case .idle:
            handler(.idle)
        default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, self.stream === stream else { return }
            Log.info("The screen capture stopped: \(error.localizedDescription)")
            self.stream = nil
            self.chosen = nil
            self.shared.withLock { self.sharedState.window = nil }
        }
    }

    private static func status(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let list = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = list.first?[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: raw)
    }

    /// The output size for a window: the long edge at most `longEdge`, never larger than the window, even numbers.
    static func fit(width: Double, height: Double, longEdge: Int = longEdge) -> (width: Int, height: Int) {
        guard width >= 1, height >= 1 else { return (2, 2) }
        let scale = min(1, Double(longEdge) / max(width, height))
        func even(_ value: Double) -> Int { max(2, Int((value * scale / 2).rounded()) * 2) }
        return (even(width), even(height))
    }
}

/// A frame of the stream. The thumb is read from the frame's memory in place; nothing is copied for a frame that
/// is not a candidate.
struct PixelPicture: FramePicture {
    let buffer: CVPixelBuffer

    private func withBytes<T>(_ body: (UnsafeRawPointer, Int, Int, Int) -> T?) -> T? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        return body(UnsafeRawPointer(base), CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), CVPixelBufferGetBytesPerRow(buffer))
    }

    var thumb: FrameThumb? {
        withBytes { FrameThumb(bgra: $0, width: $1, height: $2, bytesPerRow: $3) }
    }

    /// The one copy: the stream needs its surface back long before the candidate is decided.
    func held() -> HeldPicture? {
        withBytes { base, width, height, bytesPerRow in
            HeldPixels(data: Data(bytes: base, count: bytesPerRow * height), width: width, height: height, bytesPerRow: bytesPerRow)
        }
    }
}

final class HeldPixels: HeldPicture {
    static let quality = 0.6
    let data: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int

    init(data: Data, width: Int, height: Int, bytesPerRow: Int) {
        self.data = data
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }

    func write(to url: URL) -> Bool {
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return false }
        // Written beside the final name and moved, so a reader never sees half a picture.
        let temp = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".tmp")
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, UTType.heic.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: Self.quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        do {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temp, to: url)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
    }
}
#endif
