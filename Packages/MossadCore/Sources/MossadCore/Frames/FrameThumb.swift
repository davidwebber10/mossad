import Foundation

/// A small grayscale copy of a frame. All change detection works on this, never on the full image.
public struct FrameThumb: Equatable, Sendable {
    public static let width = 32
    public static let height = 18

    public let pixels: [UInt8]

    public init?(pixels: [UInt8]) {
        guard pixels.count == Self.width * Self.height else { return nil }
        self.pixels = pixels
    }

    /// From a BGRA picture in memory, with no copy of it: each cell is the mean of a few sampled pixels.
    public init?(bgra base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) {
        guard width >= Self.width, height >= Self.height, bytesPerRow >= width * 4 else { return nil }
        let samples = 6
        var out = [UInt8](repeating: 0, count: Self.width * Self.height)
        for cy in 0..<Self.height {
            for cx in 0..<Self.width {
                var sum = 0
                for sy in 0..<samples {
                    let y = min(height - 1, (cy * samples + sy) * height / (Self.height * samples))
                    let row = base + y * bytesPerRow
                    for sx in 0..<samples {
                        let x = min(width - 1, (cx * samples + sx) * width / (Self.width * samples))
                        let p = row.load(fromByteOffset: x * 4, as: UInt32.self)
                        // Blue, green, red in the low three bytes; green counts twice.
                        sum += Int(p & 0xFF) + 2 * Int((p >> 8) & 0xFF) + Int((p >> 16) & 0xFF)
                    }
                }
                out[cy * Self.width + cx] = UInt8(sum / (4 * samples * samples))
            }
        }
        pixels = out
    }

    /// The mean absolute difference, from 0 (the same picture) to 1 (black against white).
    public func difference(from other: FrameThumb) -> Double {
        var sum = 0
        for i in 0..<pixels.count { sum += abs(Int(pixels[i]) - Int(other.pixels[i])) }
        return Double(sum) / (255.0 * Double(pixels.count))
    }
}
