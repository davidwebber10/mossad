import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small copies of a saved frame, decoded at the size asked for and never at full size first.
public enum FrameImage {
    /// The long edge of a picture handed to another AI app.
    public static let sharedLongEdge = 1568

    public static func thumbnail(at url: URL, longEdge: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: longEdge,
                                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The frame as JPEG data, its long edge at most `longEdge`.
    public static func jpeg(at url: URL, longEdge: Int = sharedLongEdge, quality: Double = 0.8) -> Data? {
        guard let image = thumbnail(at: url, longEdge: longEdge) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
