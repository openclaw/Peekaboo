import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@_spi(Testing) @testable import PeekabooAutomationKit

struct LegacyWindowCaptureGeometryTests {
    @Test(arguments: [1, 2])
    func `parent and attached union cannot be published as an offset popup`(density: Int) throws {
        let geometry = try Self.geometry(density: density, preference: .logical1x)
        let parent = try Self.image(width: 900 * density, height: 700 * density)
        let union = try Self.image(width: 980 * density, height: 745 * density)
        for image in [parent, union] {
            #expect(throws: PeekabooError.self) {
                try geometry.deliver(LegacyCapturedRaster(image: image), sourceScale: CGFloat(density))
            }
        }
    }

    @Test
    func `observed 1891 by 1490 raster is refused for 448 by 240 popup`() throws {
        let raster = try LegacyCapturedRaster(image: Self.image(width: 1891, height: 1490))
        for density in [1, 2] {
            let geometry = try Self.geometry(density: density, preference: .logical1x)
            #expect(throws: PeekabooError.self) {
                try geometry.deliver(raster, sourceScale: CGFloat(density))
            }
        }
    }

    @Test(arguments: [1, 2], [CaptureScalePreference.logical1x, .native])
    func `exact popup preserves asymmetric pixels and global mapping`(
        density: Int,
        preference: CaptureScalePreference) throws
    {
        let geometry = try Self.geometry(density: density, preference: preference)
        let original = try Self.image(width: 448 * density, height: 240 * density)
        let raster = try LegacyCapturedRaster(systemScreencapturePNG: original.pngData())
        let delivered = try geometry.deliver(raster, sourceScale: CGFloat(density))
        let outputDensity = preference == .native ? density : 1
        #expect(delivered.image.width == 448 * outputDensity)
        #expect(delivered.image.height == 240 * outputDensity)
        #expect(try Self.pixel(delivered.image, x: 20 * outputDensity, y: 20 * outputDensity) == [255, 0, 0, 255])
        #expect(try Self.pixel(delivered.image, x: 300 * outputDensity, y: 20 * outputDensity) == [0, 255, 0, 255])
        #expect(try Self.pixel(delivered.image, x: 20 * outputDensity, y: 200 * outputDensity) == [0, 0, 255, 255])
        #expect(try Self.pixel(delivered.image, x: 300 * outputDensity, y: 200 * outputDensity) == [255, 255, 0, 255])

        let context = CaptureCoordinateContext(metadata: CaptureMetadata(
            size: CGSize(width: delivered.image.width, height: delivered.image.height),
            mode: .window,
            displayInfo: DisplayInfo(
                index: 0,
                name: nil,
                bounds: geometry.bounds,
                scaleFactor: CGFloat(outputDensity))))
        let global = try CaptureCoordinateMapper.globalPoint(
            for: CGPoint(x: 71 * outputDensity, y: 113 * outputDensity),
            in: .imagePixels,
            context: context)
        #expect(global == CGPoint(x: -229, y: 313))
        #expect(context.outputScale == CGFloat(outputDensity))
        if density == outputDensity {
            #expect(delivered.image === raster.image)
            #expect(delivered.sourcePNG == raster.sourcePNG)
        } else {
            #expect(delivered.sourcePNG == nil)
        }
    }

    @Test
    func `already logical private capture is not downscaled twice`() throws {
        let geometry = try Self.geometry(density: 2, preference: .logical1x)
        let raster = try LegacyCapturedRaster(image: Self.image(width: 448, height: 240))
        let delivered = try geometry.deliver(raster, sourceScale: 1)
        #expect(delivered.image === raster.image)
    }

    @Test
    func `failed downscale cannot publish native pixels as logical 1x`() throws {
        let palette: [UInt8] = [0, 0, 0, 255, 255, 255]
        let colorSpace = try #require(palette.withUnsafeBufferPointer {
            CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(), last: 1, colorTable: $0.baseAddress!)
        })
        let provider = try #require(CGDataProvider(data: Data(repeating: 0, count: 896 * 480) as CFData))
        let image = try #require(CGImage(
            width: 896,
            height: 480,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: 896,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent))
        let geometry = try Self.geometry(density: 2, preference: .logical1x)
        #expect(throws: PeekabooError.self) {
            try geometry.deliver(LegacyCapturedRaster(image: image), sourceScale: 2)
        }
    }

    @Test
    func `uniform oversized and anisotropic rasters are not reinterpreted as Retina`() throws {
        let geometry = try Self.geometry(density: 1, preference: .logical1x)
        for size in [CGSize(width: 896, height: 480), CGSize(width: 448, height: 480)] {
            let raster = try LegacyCapturedRaster(image: Self.image(width: Int(size.width), height: Int(size.height)))
            #expect(throws: PeekabooError.self) {
                try geometry.deliver(raster, sourceScale: 1)
            }
        }
    }

    @Test
    func `invalid and unrepresentable geometry fails closed`() throws {
        let invalidBounds = [
            CGRect.zero,
            CGRect(x: 0, y: 0, width: -448, height: 240),
            CGRect(x: CGFloat.nan, y: 0, width: 448, height: 240),
            CGRect(x: 0, y: CGFloat.infinity, width: 448, height: 240),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 240),
            CGRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 240),
            CGRect(x: 0, y: 0, width: 448.25, height: 240),
        ]
        for bounds in invalidBounds {
            #expect(throws: PeekabooError.self) {
                try Self.geometry(bounds: bounds, density: 2, preference: .logical1x)
            }
        }
        for scale in [CGFloat.zero, -1, .nan, .infinity] {
            #expect(throws: PeekabooError.self) {
                try LegacyWindowCaptureGeometry(
                    bounds: CGRect(x: 0, y: 0, width: 448, height: 240),
                    scalePlan: ScreenCaptureScaleResolver.Plan(
                        preference: .native, nativeScale: scale, outputScale: scale, source: .fallback1x))
            }
        }
    }

    private static func geometry(
        bounds: CGRect = CGRect(x: -300, y: 200, width: 448, height: 240),
        density: Int,
        preference: CaptureScalePreference) throws -> LegacyWindowCaptureGeometry
    {
        try LegacyWindowCaptureGeometry(
            bounds: bounds,
            scalePlan: ScreenCaptureScaleResolver.Plan(
                preference: preference,
                nativeScale: CGFloat(density),
                outputScale: preference == .native ? CGFloat(density) : 1,
                source: .screenBackingScaleFactor))
    }

    private static func image(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colors: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]]
        for y in 0..<height {
            for x in 0..<width {
                let color = colors[(y < height / 3 ? 0 : 2) + (x < width / 4 ? 0 : 1)]
                let offset = (y * width + x) * 4
                bytes.replaceSubrange(offset..<(offset + 4), with: color)
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent))
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try #require(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = y * context.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: data + offset, count: 4))
    }
}
