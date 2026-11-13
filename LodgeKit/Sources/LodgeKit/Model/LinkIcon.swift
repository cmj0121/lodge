import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The icon bytes an Anonymous bookmark keeps: a PNG no larger than `maxPixels` on a side and `maxBytes` long.
public enum LinkIcon {
    public static let maxPixels = 64
    public static let maxBytes = 16_384

    private static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// Whether stored bytes may be kept: no longer than `maxBytes` and starting with the PNG signature.
    public static func isValid(_ data: Data) -> Bool {
        data.count <= maxBytes && data.starts(with: signature)
    }

    /// The stored icon decoded as PNG only; nil when it is not `isValid` or does not decode.
    public static func image(from data: Data) -> CGImage? {
        guard isValid(data) else { return nil }
        let options = [kCGImageSourceTypeIdentifierHint: UTType.png.identifier] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
            CGImageSourceGetType(source) as String? == UTType.png.identifier
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

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
