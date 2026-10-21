import MossadCore
import SwiftUI

/// Two rows of bars that move with the live audio: your mic and the call audio.
struct LiveWaveform: View {
    @EnvironmentObject var controller: AppController
    var bars = 64
    var rowHeight: CGFloat = 36
    var showLabels = true

    var body: some View {
        let meters = controller.meters
        TimelineView(.animation(minimumInterval: 0.08, paused: controller.isPaused)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                row("You", meters.me.history, color: Theme.speakerPalette[0])
                row("Call audio", meters.them.history, color: Theme.speakerPalette[1])
            }
        }
        .opacity(controller.isPaused ? 0.4 : 1)
        .accessibilityLabel("Live audio levels")
    }

    private func row(_ label: String, _ history: [Float], color: Color) -> some View {
        HStack(spacing: 10) {
            if showLabels {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            }
            Canvas { context, size in
                let levels = Array(history.suffix(bars))
                let padded = Array(repeating: Float(0), count: max(0, bars - levels.count)) + levels
                let step = size.width / CGFloat(bars)
                let width = max(1.5, step * 0.55)
                for (i, level) in padded.enumerated() {
                    // Speech sits around 0.02 to 0.2 RMS; a square root makes quiet speech visible.
                    let h = max(2, min(1, CGFloat(level / 0.15).squareRoot()) * size.height)
                    let rect = CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2, width: width, height: h)
                    context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(color.opacity(level > 0.002 ? 1 : 0.35)))
                }
            }
            .frame(height: rowHeight)
        }
    }
}
