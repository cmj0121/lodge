import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The icon bytes an Anonymous bookmark keeps: a PNG no larger than `maxPixels` on a side and `maxBytes` long.
public enum LinkIcon {
    public static let maxPixels = 64
    public static let maxBytes = 16_384

    /// `image` scaled down (never up) to fit `maxPixels`, as PNG; nil when it cannot be drawn or encoded, or the
    /// PNG is over `maxBytes`.
    public static func png(from image: CGImage) -> Data? {
        let scale = min(1, Double(maxPixels) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination), data.length <= maxBytes else { return nil }
        return data as Data
    }
}
