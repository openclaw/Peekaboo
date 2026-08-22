import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAutomationKit

struct ScreenCaptureImageScalerTests {
    @Test
    func `logical 1x normalizes straight alpha and preserves exact dimensions`() throws {
        let cases: [(CGImageAlphaInfo, CGImageAlphaInfo, CGBitmapInfo)] = [
            (.last, .premultipliedLast, .byteOrder32Big),
            (.first, .premultipliedFirst, .byteOrder32Little),
        ]

        for (sourceAlpha, expectedAlpha, byteOrder) in cases {
            let image = try Self.makeImage(
                width: 8,
                height: 6,
                colorSpace: Self.sRGB,
                alphaInfo: sourceAlpha,
                byteOrder: byteOrder)

            let scaled = ScreenCaptureImageScaler.maybeDownscale(
                image,
                scale: .logical1x,
                fallbackScale: 2)

            #expect(scaled.width == 4)
            #expect(scaled.height == 3)
            #expect(scaled.alphaInfo == expectedAlpha)
            #expect(Self.byteOrder(of: scaled) == byteOrder.rawValue)
            #expect(scaled.colorSpace?.name == Self.sRGB.name)
            #expect(try Self.pixelData(scaled) == Self.pixelData(Self.trustedDownscale(image, fallbackScale: 2)))
        }
    }

    @Test
    func `even opaque Display P3 output remains byte equivalent to the current path`() throws {
        let image = try Self.makeImage(
            width: 10,
            height: 8,
            colorSpace: Self.displayP3,
            alphaInfo: .noneSkipLast,
            byteOrder: .byteOrder32Big)
        let expected = try Self.trustedDownscale(image, fallbackScale: 2)

        let scaled = ScreenCaptureImageScaler.maybeDownscale(
            image,
            scale: .logical1x,
            fallbackScale: 2)

        #expect(scaled.width == 5)
        #expect(scaled.height == 4)
        #expect(scaled.alphaInfo == image.alphaInfo)
        #expect(Self.byteOrder(of: scaled) == Self.byteOrder(of: image))
        #expect(scaled.colorSpace?.name == Self.displayP3.name)
        #expect(Self.pixelData(scaled) == Self.pixelData(expected))
    }

    @Test
    func `odd straight alpha input retains the current fractional draw geometry`() throws {
        let image = try Self.makeImage(
            width: 7,
            height: 5,
            colorSpace: Self.sRGB,
            alphaInfo: .last,
            byteOrder: .byteOrder32Big)
        let expected = try Self.trustedDownscale(image, fallbackScale: 2)

        let scaled = ScreenCaptureImageScaler.maybeDownscale(
            image,
            scale: .logical1x,
            fallbackScale: 2)

        #expect(scaled.width == 4)
        #expect(scaled.height == 3)
        #expect(Self.pixelData(scaled) == Self.pixelData(expected))
    }

    @Test
    func `unsupported destination bitmap retains the original image`() throws {
        let image = try Self.makeIndexedImage(width: 7, height: 5)

        let scaled = ScreenCaptureImageScaler.maybeDownscale(
            image,
            scale: .logical1x,
            fallbackScale: 2)

        #expect(scaled === image)
    }

    @Test
    func `native scale and non Retina logical scale return the original image`() throws {
        let image = try Self.makeImage(
            width: 8,
            height: 6,
            colorSpace: Self.sRGB,
            alphaInfo: .last,
            byteOrder: .byteOrder32Big)

        let native = ScreenCaptureImageScaler.maybeDownscale(
            image,
            scale: .native,
            fallbackScale: 2)
        let logicalOne = ScreenCaptureImageScaler.maybeDownscale(
            image,
            scale: .logical1x,
            fallbackScale: 1)
        let logicalSubOne = ScreenCaptureImageScaler.maybeDownscale(
            image,
            scale: .logical1x,
            fallbackScale: 0.5)

        #expect(native === image)
        #expect(logicalOne === image)
        #expect(logicalSubOne === image)
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    private static let alphaInfoMask: UInt32 = 0x1F
    private static let byteOrderMask: UInt32 = 0x7000

    private static func makeImage(
        width: Int,
        height: Int,
        colorSpace: CGColorSpace,
        alphaInfo: CGImageAlphaInfo,
        byteOrder: CGBitmapInfo) throws -> CGImage
    {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let red = UInt8((x * 31 + y * 7) % 256)
                let green = UInt8((x * 11 + y * 43) % 256)
                let blue = UInt8((x * 53 + y * 17) % 256)
                let alpha = UInt8(64 + (x * 19 + y * 23) % 192)
                if alphaInfo == .first || alphaInfo == .premultipliedFirst {
                    pixels[offset] = alpha
                    pixels[offset + 1] = red
                    pixels[offset + 2] = green
                    pixels[offset + 3] = blue
                } else {
                    pixels[offset] = red
                    pixels[offset + 1] = green
                    pixels[offset + 2] = blue
                    pixels[offset + 3] = alphaInfo == .noneSkipLast ? 255 : alpha
                }
            }
        }

        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let bitmapInfo = CGBitmapInfo(rawValue: alphaInfo.rawValue).union(byteOrder)
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent))
    }

    private static func makeIndexedImage(width: Int, height: Int) throws -> CGImage {
        let data = Data((0..<(width * height)).map { UInt8(($0 * 29) % 256) })
        let provider = try #require(CGDataProvider(data: data as CFData))
        let colorTable: [UInt8] = [
            0, 0, 0,
            255, 255, 255,
        ]
        let colorSpace = try #require(colorTable.withUnsafeBufferPointer { buffer in
            CGColorSpace(
                indexedBaseSpace: Self.sRGB,
                last: 1,
                colorTable: buffer.baseAddress!)
        })
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent))
    }

    private static func trustedDownscale(_ image: CGImage, fallbackScale: CGFloat) throws -> CGImage {
        let targetSize = CGSize(
            width: CGFloat(image.width) / fallbackScale,
            height: CGFloat(image.height) / fallbackScale)
        let normalizedAlpha: CGImageAlphaInfo = switch image.alphaInfo {
        case .first: .premultipliedFirst
        case .last: .premultipliedLast
        default: image.alphaInfo
        }
        let rawBitmapInfo = (image.bitmapInfo.rawValue & ~Self.alphaInfoMask) | normalizedAlpha.rawValue
        let context = try #require(CGContext(
            data: nil,
            width: Int(targetSize.width.rounded()),
            height: Int(targetSize.height.rounded()),
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: rawBitmapInfo))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: targetSize))
        return try #require(context.makeImage())
    }

    private static func byteOrder(of image: CGImage) -> UInt32 {
        image.bitmapInfo.rawValue & self.byteOrderMask
    }

    private static func pixelData(_ image: CGImage) -> Data {
        guard let provider = image.dataProvider,
              let data = provider.data
        else {
            return Data()
        }
        return data as Data
    }
}
