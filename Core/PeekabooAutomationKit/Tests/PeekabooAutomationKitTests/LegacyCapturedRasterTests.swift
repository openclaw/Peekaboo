import CoreGraphics
import Foundation
import ImageIO
import PeekabooFoundation
import Testing
import UniformTypeIdentifiers
import zlib
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
    func `bad CRC and invalid IDAT fail before source bytes can be retained`() throws {
        let validPNG = try Self.pngData(image: Self.makeImage(width: 64, height: 48))
        let idatChunks = Self.chunks(ofType: Self.idat, in: validPNG)
        let firstIDAT = try #require(idatChunks.first)

        var badCRC = validPNG
        badCRC[firstIDAT.crcOffset] ^= 0x01
        #expect(CGImageSourceCreateWithData(badCRC as CFData, nil) != nil)
        #expect(!LegacyPNGValidator.hasValidStructureAndCRC(badCRC))
        #expect(throws: PeekabooError.self) {
            try LegacyCapturedRaster(systemScreencapturePNG: badCRC)
        }

        var invalidIDAT = validPNG
        for chunk in idatChunks {
            for index in chunk.dataRange {
                invalidIDAT[index] = 0
            }
            Self.rewriteCRC(for: chunk, in: &invalidIDAT)
        }
        #expect(CGImageSourceCreateWithData(invalidIDAT as CFData, nil) != nil)
        #expect(LegacyPNGValidator.hasValidStructureAndCRC(invalidIDAT))
        #expect(throws: PeekabooError.self) {
            try LegacyCapturedRaster(systemScreencapturePNG: invalidIDAT)
        }
    }

    @Test
    func `missing IEND truncation and overflowing chunk lengths fail structurally`() throws {
        let validPNG = try Self.pngData(image: Self.makeImage(width: 8, height: 6))
        let iend = try #require(Self.chunks(ofType: Self.iend, in: validPNG).first)
        let idat = try #require(Self.chunks(ofType: Self.idat, in: validPNG).first)
        let missingIEND = Data(validPNG[..<iend.offset])
        let truncatedIDAT = Data(validPNG.prefix(idat.dataRange.lowerBound + max(idat.dataRange.count / 2, 1)))
        let overflowingLength = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0xFF, 0xFF, 0xFF, 0xFF, 0x49, 0x44, 0x41, 0x54,
            0x00, 0x00, 0x00, 0x00,
        ])
        let invalidInputs = [missingIEND, truncatedIDAT, overflowingLength]

        for data in invalidInputs {
            #expect(!LegacyPNGValidator.hasValidStructureAndCRC(data))
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

    private struct PNGChunk {
        let offset: Int
        let typeOffset: Int
        let dataRange: Range<Int>
        let crcOffset: Int
    }

    private static let idat: UInt32 = 0x4944_4154
    private static let iend: UInt32 = 0x4945_4E44

    private static func chunks(ofType expectedType: UInt32, in data: Data) -> [PNGChunk] {
        data.withUnsafeBytes { bytes in
            var chunks: [PNGChunk] = []
            var offset = 8
            while offset < bytes.count {
                guard bytes.count - offset >= 12 else { break }
                let length = Int(Self.uint32(bytes, at: offset))
                guard length <= bytes.count - offset - 12 else { break }
                let typeOffset = offset + 4
                let dataOffset = typeOffset + 4
                let crcOffset = dataOffset + length
                if Self.uint32(bytes, at: typeOffset) == expectedType {
                    chunks.append(PNGChunk(
                        offset: offset,
                        typeOffset: typeOffset,
                        dataRange: dataOffset..<crcOffset,
                        crcOffset: crcOffset))
                }
                offset = crcOffset + 4
            }
            return chunks
        }
    }

    private static func rewriteCRC(for chunk: PNGChunk, in data: inout Data) {
        let checksum = data.withUnsafeBytes { bytes -> UInt32 in
            let count = chunk.dataRange.count + 4
            let pointer = bytes.baseAddress!
                .advanced(by: chunk.typeOffset)
                .assumingMemoryBound(to: Bytef.self)
            return UInt32(truncatingIfNeeded: zlib.crc32_z(0, pointer, count))
        }
        data[chunk.crcOffset] = UInt8(truncatingIfNeeded: checksum >> 24)
        data[chunk.crcOffset + 1] = UInt8(truncatingIfNeeded: checksum >> 16)
        data[chunk.crcOffset + 2] = UInt8(truncatingIfNeeded: checksum >> 8)
        data[chunk.crcOffset + 3] = UInt8(truncatingIfNeeded: checksum)
    }

    private static func uint32(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 |
            UInt32(bytes[offset + 1]) << 16 |
            UInt32(bytes[offset + 2]) << 8 |
            UInt32(bytes[offset + 3])
    }
}
