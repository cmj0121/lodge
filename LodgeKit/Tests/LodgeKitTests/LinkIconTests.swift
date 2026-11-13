import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import LodgeKit

@Suite struct LinkIconTests {
    /// A `width`×`height` image; `noise` fills it with random pixels, which PNG cannot compress.
    private func image(width: Int, height: Int, noise: Bool = false) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if noise, let pixels = context.data?.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height) {
            for pixel in stride(from: 0, to: context.bytesPerRow * height, by: 4) {
                let alpha = UInt8.random(in: 1...255)
                for channel in 0..<3 { pixels[pixel + channel] = .random(in: 0...alpha) }
                pixels[pixel + 3] = alpha
            }
        } else {
            context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try #require(context.makeImage())
    }

    private func decoded(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test func limitsAre64PixelsAnd16KB() {
        #expect(LinkIcon.maxPixels == 64)
        #expect(LinkIcon.maxBytes == 16_384)
    }

    @Test func aLargeIconIsScaledDownKeepingItsShape() throws {
        let data = try #require(LinkIcon.png(from: try image(width: 256, height: 128)))
        let png = try decoded(data)
        #expect((png.width, png.height) == (64, 32))
        #expect(data.count <= LinkIcon.maxBytes)
    }

    @Test func aSmallIconIsNotScaledUp() throws {
        let png = try decoded(try #require(LinkIcon.png(from: try image(width: 16, height: 16))))
        #expect((png.width, png.height) == (16, 16))
    }

    @Test func anIconOverTheByteLimitIsRefused() throws {
        #expect(LinkIcon.png(from: try image(width: 64, height: 64, noise: true)) == nil)
    }

    @Test func onlyAPNGWithinTheByteLimitIsValid() throws {
        let png = try #require(LinkIcon.png(from: try image(width: 16, height: 16)))
        #expect(LinkIcon.isValid(png))
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(LinkIcon.isValid(signature + Data(count: LinkIcon.maxBytes - signature.count)))
        #expect(!LinkIcon.isValid(signature + Data(count: LinkIcon.maxBytes - signature.count + 1)))
        #expect(!LinkIcon.isValid(Data([1, 2, 3])))
        #expect(!LinkIcon.isValid(Data("GIF89a".utf8)))
        #expect(!LinkIcon.isValid(Data()))
    }

    @Test func aStoredIconDecodesOnlyAsPNG() throws {
        let png = try #require(LinkIcon.png(from: try image(width: 16, height: 16)))
        let decoded = try #require(LinkIcon.image(from: png))
        #expect((decoded.width, decoded.height) == (16, 16))
        #expect(LinkIcon.image(from: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])) == nil)
        let tiff = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(tiff, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(width: 16, height: 16), nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(LinkIcon.image(from: tiff as Data) == nil)
    }
}
