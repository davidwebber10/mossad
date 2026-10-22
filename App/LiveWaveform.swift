import AppKit
import MossadCore
import SwiftUI

/// Two rows of bars that move with the live audio: your mic and the call audio.
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
            WaveformBars(meter: meter, color: NSColor(color), bars: bars, framesPerSecond: framesPerSecond, running: running)
                .frame(height: rowHeight)
        }
    }
}

/// The bars as a plain layer-backed view with its own timer: each frame redraws this view only, without a
/// SwiftUI update or a window layout pass.
private struct WaveformBars: NSViewRepresentable {
    let meter: LevelMeter
    let color: NSColor
    let bars: Int
    let framesPerSecond: Double
    let running: Bool

    func makeNSView(context: Context) -> WaveformView { WaveformView() }

    func updateNSView(_ view: WaveformView, context: Context) {
        view.meter = meter
        view.color = color
        view.bars = bars
        view.interval = 1 / framesPerSecond
        view.running = running
        view.needsDisplay = true
    }
}

final class WaveformView: NSView {
    var meter: LevelMeter?
    var color: NSColor = .systemBlue
    var bars = 64
    var interval: TimeInterval = 1.0 / 12
    var running = false { didSet { if running != oldValue { updateTimer() } } }
    private var timer: Timer?

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

    override func draw(_ dirtyRect: NSRect) {
        let levels = Array((meter?.history ?? []).suffix(bars))
        let padded = Array(repeating: Float(0), count: max(0, bars - levels.count)) + levels
        let step = bounds.width / CGFloat(bars)
        let width = max(1.5, step * 0.55)
        for (i, level) in padded.enumerated() {
            // Speech sits around 0.02 to 0.2 RMS; a square root makes quiet speech visible.
            let h = max(2, min(1, CGFloat(level / 0.15).squareRoot()) * bounds.height)
            let rect = NSRect(x: CGFloat(i) * step, y: (bounds.height - h) / 2, width: width, height: h)
            color.withAlphaComponent(level > 0.002 ? 1 : 0.35).setFill()
            NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
        }
    }
}
