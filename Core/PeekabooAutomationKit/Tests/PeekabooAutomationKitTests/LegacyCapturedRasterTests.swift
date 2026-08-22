import CoreGraphics
import Foundation
import ImageIO
import PeekabooFoundation
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAutomationKit

struct LegacyCapturedRasterTests {
    @Test
    func `native and true 1x delivery retain exact source PNG bytes`() throws {
        let sourceImage = try Self.makeImage(width: 8, height: 6)
        let sourcePNG = try Self.pngData(image: sourceImage, marker: "peekaboo-source-marker")
        let raster = try LegacyCapturedRaster(systemScreencapturePNG: sourcePNG)

        let native = ScreenCaptureImageScaler.maybeDownscale(
            raster.image,
            scale: .native,
            fallbackScale: 2)
        let logicalOne = ScreenCaptureImageScaler.maybeDownscale(
            raster.image,
            scale: .logical1x,
            fallbackScale: 1)

        #expect(native === raster.image)
        #expect(logicalOne === raster.image)
        #expect(raster.sourcePNG == sourcePNG)
        #expect(try raster.pngData(for: native) == sourcePNG)
        #expect(try raster.pngData(for: logicalOne) == sourcePNG)
        #expect(sourcePNG.range(of: Data("peekaboo-source-marker".utf8)) != nil)
    }

    @Test
    func `Retina logical 1x delivery discards source bytes and encodes transformed dimensions`() throws {
        let sourceImage = try Self.makeImage(width: 8, height: 6)
        let sourcePNG = try Self.pngData(image: sourceImage, marker: "must-not-survive-transform")
        let raster = try LegacyCapturedRaster(systemScreencapturePNG: sourcePNG)

        let logicalOne = ScreenCaptureImageScaler.maybeDownscale(
            raster.image,
            scale: .logical1x,
            fallbackScale: 2)
        let deliveredPNG = try raster.pngData(for: logicalOne)
        let deliveredImage = try Self.decodedImage(deliveredPNG)

        #expect(logicalOne !== raster.image)
        #expect(deliveredPNG != sourcePNG)
        #expect(deliveredPNG.range(of: Data("must-not-survive-transform".utf8)) == nil)
        #expect(deliveredImage.width == 4)
        #expect(deliveredImage.height == 3)
    }

    @Test
    func `corrupt and truncated system PNGs fail the full decode gate`() throws {
        let validPNG = try Self.pngData(image: Self.makeImage(width: 4, height: 3))
        let invalidInputs = [
            Data([0x89, 0x50, 0x4E, 0x47]),
            Data(validPNG.prefix(16)),
        ]

        for data in invalidInputs {
            #expect(throws: PeekabooError.self) {
                try LegacyCapturedRaster(systemScreencapturePNG: data)
            }
        }
    }

    @Test
    func `image-only private SCK raster has no source bytes and encodes the image`() throws {
        let sourceImage = try Self.makeImage(width: 5, height: 3)
        let raster = LegacyCapturedRaster(image: sourceImage)
        let encoded = try raster.pngData(for: sourceImage)
        let decoded = try Self.decodedImage(encoded)

        #expect(raster.sourcePNG == nil)
        #expect(!encoded.isEmpty)
        #expect(decoded.width == 5)
        #expect(decoded.height == 3)
    }

    private static func makeImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private static func pngData(image: CGImage, marker: String? = nil) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil))
        let properties: CFDictionary? = marker.map { marker in
            [
                kCGImagePropertyPNGDictionary: [
                    kCGImagePropertyPNGDescription: marker,
                ],
            ] as CFDictionary
        }
        CGImageDestinationAddImage(destination, image, properties)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func decodedImage(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}
