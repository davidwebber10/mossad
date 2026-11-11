#if os(macOS)
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// Pictures of the call's own window through ScreenCaptureKit: one stream with a single-window filter, a frame each
/// 3 s at most, on the screen queue. It never captures a display or another app's window, and it stops as soon as
/// the window's title no longer shows the meeting (in a browser, the owner chose another tab). Of a browser window
/// it hands on only the page, not the tabs, the address, or the bookmarks.
///
/// It needs the Screen & System Audio Recording permission and never asks for it: without it, nothing is found.
public final class WindowFrameSource: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let frameInterval: TimeInterval = 3
    static let longEdge = 1600
    /// How often the windows are looked at while there is no good window, and while there is one.
    static let searchInterval: TimeInterval = 10
    static let reviewInterval: TimeInterval = 30
    /// A Teams title that Accessibility did not prove is asked about again after this long.
    static let proofRetry: TimeInterval = 60
    static let proofRetryMax: TimeInterval = 480

    private let platform: Platform
    private let bundleID: String
    private let meetingID: String?
    private let queue = ScreenRecorder.queue

    private struct Chosen {
        var id: CGWindowID
        var owner: String
        var kind: MeetingWindow.Kind
        var size: CGSize
        var crop: CGRect
        var title: String
        var page: Page?
    }

    /// A browser window's page: the Accessibility elements of the window and of the page, and the page's frame
    /// inside the window when the stream began. Read again at each check; when it moved, the crop is no longer the
    /// page. Both frames come from Accessibility, so a window that the owner moves gives the same answer.
    private struct Page {
        var window: AXUIElement
        var element: AXUIElement
        var frame: CGRect
    }

    /// A browser window that is not captured, so the walk is not made again at each search. A sure answer (no page,
    /// two pages) waits a minute. An answer that is not sure (the browser was busy) is tried again at the next
    /// search, then after 20 s, then each minute.
    private struct Refusal {
        var id: CGWindowID
        var size: CGSize
        var title: String
        var at: Date
        var tries: Int
        var wait: TimeInterval

        func covers(_ w: WindowCandidate) -> Bool {
            id == w.id && title == w.title && size == CGSize(width: w.width, height: w.height)
        }
    }

    /// What other threads read.
    private struct Shared {
        var active = false
        var chosen: Chosen?
        var teamsNames: Set<String> = []
    }
    private let shared = NSLock()
    private var sharedState = Shared()
    private var chosen: Chosen? { shared.withLock { sharedState.chosen } }

    // The rest only on `queue`.
    private var handler: ((FrameEvent) -> Void)?
    private var generation = 0
    private var stream: SCStream?
    private var searching = false
    private var searchAgain = false
    private var lastSearch = Date.distantPast
    private var timer: DispatchSourceTimer?
    private var proven: Set<String> = []
    private var refused: [String: (at: Date, wait: TimeInterval)] = [:]
    private var refusedPage: Refusal?
    private var lastPageWalk = Date.distantPast
    private var loggedNoContent = false

    public init(platform: Platform, bundleID: String, meetingID: String?) {
        self.platform = platform
        self.bundleID = bundleID
        self.meetingID = meetingID
    }

    /// The title of the window that is captured now, for the read of the presenter from that window. Any thread.
    public var windowTitle: String? { chosen?.title }

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

    /// How the window can be seen, and the check that it still is the meeting with its page in the same place.
    /// One request for the window, one for the windows above it, and for a browser four to Accessibility (the
    /// window's frame and the page's; eight when they do not agree at first); the recorder asks each 3 s.
    public var windowSight: WindowSight? {
        guard let chosen else { return nil }
        guard let now = Self.describe(chosen.id), stillMeeting(chosen, now), !pageMoved(chosen) else {
            queue.async { [weak self] in self?.windowChanged(chosen.id) }
            return nil
        }
        guard now.onScreen else { return .hidden }
        return WindowCover.isCovered(now.frame, by: Self.framesAbove(chosen.id)) ? .covered : .visible
    }

    /// True when a browser's page is no longer where the stream's crop expects it (a bookmarks bar, a side panel,
    /// a toolbar that slid in), or when its frame cannot be read.
    private func pageMoved(_ chosen: Chosen) -> Bool {
        guard let page = chosen.page else { return false }
        func place() -> CGRect? {
            guard let window = AXWalk.frame(page.window), let area = AXWalk.frame(page.element) else { return nil }
            return area.offsetBy(dx: -window.minX, dy: -window.minY)
        }
        guard MeetingWindow.pageMoved(from: page.frame, to: place()) else { return false }
        // The two frames are read one after the other, so a window in motion can give one false answer. Once more.
        return MeetingWindow.pageMoved(from: page.frame, to: place())
    }

    /// True for a browser's own window with tabs: the one kind of window of which only a part is kept.
    private func hasTabs(_ w: WindowCandidate) -> Bool {
        guard case .browser(let browser)? = MeetingMatcher.appKind(bundleID: bundleID) else { return false }
        return w.layer == 0 && w.bundleID.lowercased() == browser.lowercased()
    }

    /// The pages of a browser window, with their frames counted from the window's own Accessibility frame.
    private func readPages(_ w: WindowCandidate) -> (page: Page?, areas: [CGRect])? {
        lastPageWalk = Date()
        guard case .pages(let window, let frame, let found) = WebAreaProbe.read(bundleID: w.bundleID, windowTitle: w.title,
                                                                                windowFrame: Self.describe(w.id)?.frame) else { return nil }
        let inside = found.map { (element: $0.element, frame: $0.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)) }
        let largest = inside.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        return (largest.map { Page(window: window, element: $0.element, frame: $0.frame) }, inside.map(\.frame))
    }

    /// While a browser stream runs, the whole window is walked again now and then: a second page that opened
    /// over the page without moving it does not show in the page's own frame. A walk with no sure answer changes
    /// nothing; the checks of the page's frame go on.
    private func recheckPages(_ w: WindowCandidate) {
        guard let chosen, chosen.page != nil, Date().timeIntervalSince(lastPageWalk) >= Self.reviewInterval,
              let read = readPages(w) else { return }
        guard MeetingWindow.keptPart(of: w, bundleID: bundleID, webAreas: read.areas) == nil else { return }
        Log.info("The meeting window is no longer captured: it shows a second page")
        refusedPage = Refusal(id: w.id, size: CGSize(width: w.width, height: w.height), title: w.title, at: Date(), tries: 1, wait: Self.proofRetry)
        windowChanged(chosen.id, searchNow: false)
    }

    // MARK: CoachFinding the window

    /// Looks at the windows again when there is no window, when the window is hidden or is only a small view
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

    /// The app that holds the call, without its helpers.
    private var appID: String? {
        switch MeetingMatcher.appKind(bundleID: bundleID) {
        case .zoomApp: MeetingMatcher.zoomBundleID
        case .teamsApp: MeetingMatcher.teamsBundleID
        case .browser(let id): id
        default: nil
        }
    }

    /// Only the call app's own windows are listed, from the window server, with no capture call. ScreenCaptureKit
    /// is asked only when one of them is the meeting and needs a stream.
    private func search() {
        // Without the permission the window list has no titles, and ScreenCaptureKit would ask; a call never asks.
        guard shared.withLock({ sharedState.active }), CGPreflightScreenCaptureAccess(), let appID else { return }
        guard !searching else {
            searchAgain = true
            return
        }
        lastSearch = Date()
        let windows = Self.windows(of: appID)
        var confirmed: Set<String> = []
        if case .teamsApp? = MeetingMatcher.appKind(bundleID: bundleID) {
            // A title of the form "<name> | Microsoft Teams" is the meeting only with proof: the call's controls in it.
            let now = Date()
            let open = MeetingWindow.teamsTitlesToProve(windows.map(\.title))
            proven.formIntersection(open)
            let ask = open.filter { title in
                guard !proven.contains(title) else { return false }
                return refused[title].map { now.timeIntervalSince($0.at) >= $0.wait } ?? true
            }
            if !ask.isEmpty {
                let found = CallWindowProbe.callTitles(bundleID: appID, among: Set(ask))
                proven.formUnion(found)
                // A page that is not a call is asked about less and less often.
                for title in ask where !found.contains(title) {
                    refused[title] = (now, min((refused[title]?.wait ?? Self.proofRetry / 2) * 2, Self.proofRetryMax))
                }
            }
            confirmed = proven
        }
        guard let best = MeetingWindow.choose(windows, platform: platform, bundleID: bundleID, meetingID: meetingID, confirmed: confirmed),
              let kind = MeetingWindow.kind(of: best, among: windows, platform: platform, bundleID: bundleID, confirmed: confirmed) else {
            if let old = chosen { windowChanged(old.id, searchNow: false) }
            return
        }
        let names = MeetingWindow.teamsMeetingNames(windows.map(\.title), confirmed: confirmed)
        shared.withLock { sharedState.teamsNames = names }
        if chosen?.id == best.id, stream != nil {
            recheckPages(best)
            return
        }
        if let old = chosen { windowChanged(old.id, searchNow: false) }
        // Of a browser window only the page is kept. Without the page's frame, or with two pages in the window,
        // nothing is captured; the read is tried again later, not at each search.
        var page: Page?
        var areas: [CGRect]?
        var sure = true
        if hasTabs(best) {
            if let r = refusedPage, r.covers(best), Date().timeIntervalSince(r.at) < r.wait { return }
            if let read = readPages(best) {
                page = read.page
                areas = read.areas
            } else {
                sure = false
            }
        }
        guard let crop = MeetingWindow.keptPart(of: best, bundleID: bundleID, webAreas: areas) else {
            let tries = (refusedPage.flatMap { $0.covers(best) ? $0.tries : nil } ?? 0) + 1
            if tries == 1 { Log.info("The meeting window is not captured: the page's place in the browser window is not sure") }
            refusedPage = Refusal(id: best.id, size: CGSize(width: best.width, height: best.height), title: best.title, at: Date(),
                                  tries: tries, wait: sure ? Self.proofRetry : tries == 1 ? 0 : tries == 2 ? 20 : Self.proofRetry)
            return
        }
        refusedPage = nil
        searching = true
        let generation = generation, queue = queue
        Task.detached(priority: .utility) { [weak self] in
            // Windows on every Space, also ones that are not on screen.
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let window = content?.windows.first { $0.windowID == best.id }
            queue.async { [weak self] in
                guard let self else { return }
                self.searching = false
                if generation == self.generation, let window { self.begin(window, candidate: best, kind: kind, crop: crop, page: page) }
                if self.searchAgain {
                    self.searchAgain = false
                    self.search()
                }
            }
        }
    }

    private func begin(_ window: SCWindow, candidate: WindowCandidate, kind: MeetingWindow.Kind, crop: CGRect,
                       page: Page?) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = max(1, Double(filter.pointPixelScale))
        // The kept part, not the whole window, is at most `longEdge` wide or high.
        let size = Self.fit(width: window.frame.width * scale, height: window.frame.height * scale,
                            longEdge: Int(Double(Self.longEdge) / max(0.3, max(crop.width, crop.height))))
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.scalesToFit = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.queueDepth = 3
        // The shadow is not part of the window: with it, the kept part would be counted from a larger picture.
        configuration.ignoreShadowsSingleWindow = true
        // A browser's child windows (the card of another tab, the address suggestions) hang over the page.
        if page != nil { configuration.includeChildWindows = false }
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
        let chosen = Chosen(id: candidate.id, owner: candidate.bundleID, kind: kind, size: window.frame.size, crop: crop, title: candidate.title, page: page)
        shared.withLock { sharedState.chosen = chosen }
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
        shared.withLock { sharedState.chosen = nil }
    }

    /// The window is gone or shows something else: stop now, tell the recorder, and look for the meeting's window again.
    private func windowChanged(_ id: CGWindowID, searchNow: Bool = true) {
        guard chosen?.id == id else { return }
        dropStream()
        handler?(.lost)
        if searchNow { search() }
    }

    private struct Described {
        var title: String
        var onScreen: Bool
        var frame: CGRect
        var layer: Int
    }

    private static func described(_ info: [CFString: Any]) -> Described {
        let bounds = (info[kCGWindowBounds] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
        return Described(title: info[kCGWindowName] as? String ?? "", onScreen: info[kCGWindowIsOnscreen] as? Bool ?? false,
                         frame: bounds, layer: info[kCGWindowLayer] as? Int ?? 0)
    }

    /// The window as it is now, with one cheap request for this window only. Nil when it is gone.
    private static func describe(_ id: CGWindowID) -> Described? {
        let ids = [id as CFNumber] as CFArray
        guard let list = CGWindowListCreateDescriptionFromArray(ids) as? [[CFString: Any]], let info = list.first else { return nil }
        return described(info)
    }

    /// The frames of the normal windows in front of a window.
    private static func framesAbove(_ id: CGWindowID) -> [CGRect] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], id) as? [[CFString: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowAlpha] as? Double ?? 1) > 0.9 else { return nil }
            let d = described(info)
            return d.layer == 0 ? d.frame : nil
        }
    }

    /// The windows of one app (and of the sites it runs as apps), on every desktop, from the window server.
    private static func windows(of appID: String) -> [WindowCandidate] {
        let base = appID.lowercased()
        var owners: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, id.lowercased() == base || id.lowercased().hasPrefix(base + ".app.") else { continue }
            owners[app.processIdentifier] = id
        }
        guard !owners.isEmpty, let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[CFString: Any]] else { return [] }
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID] as? pid_t, let owner = owners[pid], let id = info[kCGWindowNumber] as? CGWindowID else { return nil }
            let d = described(info)
            return WindowCandidate(id: id, bundleID: owner, title: d.title, width: d.frame.width, height: d.frame.height, onScreen: d.onScreen, layer: d.layer)
        }
    }

    private func stillMeeting(_ chosen: Chosen, _ now: Described) -> Bool {
        let window = WindowCandidate(id: chosen.id, bundleID: chosen.owner, title: now.title, width: now.frame.width,
                                     height: now.frame.height, onScreen: now.onScreen, layer: now.layer)
        let names = shared.withLock { sharedState.teamsNames }
        guard MeetingWindow.stillMeeting(window, platform: platform, bundleID: bundleID, meetingNames: names) else { return false }
        // A window that changed its size, on either edge, gets a new stream, with the page's place read again.
        return !MeetingWindow.sizeChanged(from: chosen.size, to: now.frame.size)
    }

    // MARK: Frames

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, stream === self.stream, sampleBuffer.isValid, shared.withLock({ sharedState.active }),
              let handler, let chosen else { return }
        switch Self.status(of: sampleBuffer) {
        case .complete:
            // Checked for each frame: one click on another tab makes the same window show something else, and a
            // bar or a panel of the browser moves the page out of the kept part.
            guard let now = Self.describe(chosen.id), stillMeeting(chosen, now), !pageMoved(chosen) else {
                windowChanged(chosen.id)
                return
            }
            guard let buffer = sampleBuffer.imageBuffer else { return }
            // The window's picture can be a part of the frame only; the kept part is counted inside that part.
            // When the stream does not say where it is, a frame of which only a part may be kept is not kept.
            let content = Self.content(of: sampleBuffer)
            if content == nil, chosen.page != nil {
                if !loggedNoContent { Log.error("The screen capture gave no place of the window in its frames; frames of the browser window are dropped") }
                loggedNoContent = true
                return
            }
            handler(.picture(PixelPicture(buffer: buffer, crop: chosen.crop, content: content),
                             window: "\(chosen.owner)#\(chosen.id)"))
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
            self.shared.withLock { self.sharedState.chosen = nil }
            self.handler?(.lost)
        }
    }

    /// Where the window's picture is in the frame, in pixels: the content rectangle times the scale factor.
    private static func content(of sampleBuffer: CMSampleBuffer) -> CGRect? {
        guard let list = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = list.first, let dictionary = info[.contentRect] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
        // Without the scale the rectangle's size in pixels is not known.
        guard let scale = (info[.scaleFactor] as? Double) ?? (info[.scaleFactor] as? NSNumber)?.doubleValue, scale > 0 else { return nil }
        return CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
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
    /// The part of the frame that is kept, in parts of it from the top left. The rest is never read or copied.
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Where the window's picture is in the frame, in pixels; nil when the stream did not say (then the whole frame).
    var content: CGRect?

    /// The kept part as a place in the frame's memory: its first byte, its size in pixels, and the row length.
    private func withBytes<T>(_ body: (UnsafeRawPointer, Int, Int, Int) -> T?) -> T? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let part = PixelCrop.pixels(crop, in: content, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        guard part.width > 0, part.height > 0 else { return nil }
        return body(UnsafeRawPointer(base) + part.y * bytesPerRow + part.x * 4, part.width, part.height, bytesPerRow)
    }

    var thumb: FrameThumb? {
        withBytes { FrameThumb(bgra: $0, width: $1, height: $2, bytesPerRow: $3) }
    }

    /// The one copy: the stream needs its surface back long before the candidate is decided.
    func held() -> HeldPicture? {
        withBytes { base, width, height, bytesPerRow in
            // The last row ends at its last kept pixel, so nothing outside the kept part is read.
            HeldPixels(data: Data(bytes: base, count: bytesPerRow * (height - 1) + width * 4), width: width, height: height, bytesPerRow: bytesPerRow)
        }
    }
}

/// A kept part in whole pixels, inside the frame.
enum PixelCrop {
    /// `content` is the part of the frame that holds the window's picture, in pixels; the kept part is a part of
    /// that, not of the whole frame. Nil, or a rectangle that makes no sense, means the whole frame.
    static func pixels(_ crop: CGRect, in content: CGRect? = nil, width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        let frame = CGRect(x: 0, y: 0, width: Double(width), height: Double(height))
        var area = content.map { $0.intersection(frame) } ?? frame
        if area.isNull || area.width < 2 || area.height < 2 { area = frame }
        let x = min(max(0, Int((area.minX + crop.minX * area.width).rounded(.up))), width)
        let y = min(max(0, Int((area.minY + crop.minY * area.height).rounded(.up))), height)
        let right = min(width, max(x, Int((area.minX + crop.maxX * area.width).rounded(.down))))
        let bottom = min(height, max(y, Int((area.minY + crop.maxY * area.height).rounded(.down))))
        return (x, y, right - x, bottom - y)
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
