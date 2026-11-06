import AppKit
import MossadCore
import SwiftUI

/// Two rows of bars that move with the live audio: your mic and the call audio. The list row's small copy.
struct LiveWaveform: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.animationsActive) private var active
    var bars = 64
    var rowHeight: CGFloat = 36
    var showLabels = true
    /// Redraws a second; the small copy in the list row needs fewer.
    var framesPerSecond: Double = 12

    var body: some View {
        let meters = controller.meters
        let running = active && !controller.isPaused
        VStack(alignment: .leading, spacing: 8) {
            row(controller.isMuted ? "Muted" : "You", meters.me, color: controller.isMuted ? Theme.unknown : Theme.speakerPalette[0], running: running)
                .opacity(controller.isMuted ? 0.5 : 1)
            row("Call audio", meters.them, color: Theme.speakerPalette[1], running: running)
        }
        .opacity(controller.isPaused ? 0.4 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live audio levels")
    }

    private func row(_ label: String, _ meter: LevelMeter, color: Color, running: Bool) -> some View {
        HStack(spacing: 10) {
            if showLabels {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            }
            WaveformBars(style: .row(meter, NSColor(color)), bars: bars, framesPerSecond: framesPerSecond, running: running)
                .frame(height: rowHeight)
        }
    }
}

/// The meeting band's one row: each bar is the louder of your mic and the call audio, in your hue or the call's,
/// and silence is a short neutral bar. A room has one mic that hears everyone, so its bars take the voices' hues.
struct LiveBandWaveform: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.animationsActive) private var active
    var room = false
    var bars = 64

    var body: some View {
        let meters = controller.meters
        WaveformBars(style: .merged(me: meters.me, them: meters.them, muted: controller.isMuted, room: room),
                     bars: bars, framesPerSecond: 12, running: active && !controller.isPaused)
            .frame(height: 40)
            .opacity(controller.isPaused ? 0.4 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live audio levels")
    }
}

/// The bars as a plain layer-backed view with its own timer: each frame redraws this view only, without a
/// SwiftUI update or a window layout pass.
private struct WaveformBars: NSViewRepresentable {
    let style: WaveformView.Style
    let bars: Int
    let framesPerSecond: Double
    let running: Bool

    func makeNSView(context: Context) -> WaveformView { WaveformView() }

    func updateNSView(_ view: WaveformView, context: Context) {
        view.style = style
        view.bars = bars
        view.interval = 1 / framesPerSecond
        view.running = running
        view.needsDisplay = true
    }
}

final class WaveformView: NSView {
    enum Style {
        case row(LevelMeter, NSColor)
        case merged(me: LevelMeter, them: LevelMeter, muted: Bool, room: Bool)
    }

    var style: Style?
    var bars = 64
    var interval: TimeInterval = 1.0 / 12
    var running = false { didSet { if running != oldValue { updateTimer() } } }
    private var timer: Timer?
    private let me = NSColor(Palette.speaker(0))
    // The call audio is many voices, not one speaker: the canvas gives it hue 85, apart from the owner's.
    private let them = NSColor(Palette.speaker(2))
    private let silent = NSColor(Palette.bar)
    /// The canvas's room: the first four hues, so the bars read as several voices without a rainbow.
    private let voices = Palette.speakers.prefix(4).map { NSColor($0) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        // Leaving the window stops the timer, so a closed view never keeps redrawing.
        guard running, window != nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.needsDisplay = true }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func levels(_ meter: LevelMeter?) -> [Float] {
        let levels = Array((meter?.history ?? []).suffix(bars))
        return Array(repeating: Float(0), count: max(0, bars - levels.count)) + levels
    }

    /// Speech sits around 0.02 to 0.2 RMS; a square root makes quiet speech visible.
    private func height(_ level: Float, minimum: CGFloat) -> CGFloat {
        max(minimum, min(1, CGFloat(level / 0.15).squareRoot()) * bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .row(let meter, let color): drawRow(meter, color)
        case .merged(let meMeter, let themMeter, let muted, let room): drawMerged(meMeter, themMeter, muted: muted, room: room)
        case nil: break
        }
    }

    private func drawRow(_ meter: LevelMeter, _ color: NSColor) {
        let step = bounds.width / CGFloat(bars)
        let width = max(1.5, step * 0.55)
        for (i, level) in levels(meter).enumerated() {
            let h = height(level, minimum: 2)
            let rect = NSRect(x: CGFloat(i) * step, y: (bounds.height - h) / 2, width: width, height: h)
            color.withAlphaComponent(level > 0.002 ? 1 : 0.35).setFill()
            NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
        }
    }

    private func drawMerged(_ meMeter: LevelMeter, _ themMeter: LevelMeter, muted: Bool, room: Bool) {
        let gap: CGFloat = 2
        let width = max(1.5, (bounds.width - gap * CGFloat(bars - 1)) / CGFloat(bars))
        // Muted, the mic records silence; the bars show only the call.
        let mine = muted ? Array(repeating: Float(0), count: bars) : levels(meMeter)
        let theirs = room ? Array(repeating: Float(0), count: bars) : levels(themMeter)
        for i in 0..<bars {
            let level = max(mine[i], theirs[i])
            let speaking = level > 0.002
            let h = speaking ? height(level, minimum: 3) : 3
            let rect = NSRect(x: CGFloat(i) * (width + gap), y: (bounds.height - h) / 2, width: width, height: h)
            let color = !speaking ? silent : room ? voices[i % voices.count] : mine[i] >= theirs[i] ? me : them
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }
}
