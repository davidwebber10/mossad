import AppKit
import SwiftUI

extension EnvironmentValues {
    /// False while the window or panel cannot be seen: animations stop instead of drawing for nobody.
    @Entry var animationsActive = true
}

/// A status dot; recording dots pulse with a fading ring.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.animationsActive) private var active

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay {
                if pulsing, !reduceMotion, active {
                    // Core Animation runs the pulse on its own, outside SwiftUI's view updates.
                    PulseRing(color: NSColor(color.opacity(0.5)), size: size)
                        .frame(width: size, height: size)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// A ring that grows and fades from the dot, repeated by Core Animation.
private struct PulseRing: NSViewRepresentable {
    let color: NSColor
    let size: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: size, height: size), transform: nil)
        ring.frame = CGRect(x: 0, y: 0, width: size, height: size)
        ring.fillColor = nil
        ring.strokeColor = color.cgColor
        ring.lineWidth = 2
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = (size + 14) / size
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 1.6
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.repeatCount = .infinity
        ring.add(group, forKey: "pulse")
        view.layer?.addSublayer(ring)
        // The ring grows past the dot's own frame.
        view.layer?.masksToBounds = false
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
