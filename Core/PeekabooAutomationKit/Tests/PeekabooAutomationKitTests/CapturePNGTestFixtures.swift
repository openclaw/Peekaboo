import CoreGraphics
import Foundation
import ImageIO
import PeekabooFoundation
import Testing
import UniformTypeIdentifiers
import zlib
@testable import PeekabooAutomationKit

enum CapturePNGTestFixtures {
    static func makeImage(width: Int, height: Int) throws -> CGImage {
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

    static func pngData(image: CGImage, marker: String? = nil) throws -> Data {
        try self.encodedData(images: [image], type: .png, marker: marker)
    }

    static func encodedData(images: [CGImage], type: UTType, marker: String? = nil) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            images.count,
            nil))
        let properties: CFDictionary? = marker.map { marker in
            [
                kCGImagePropertyPNGDictionary: [
                    kCGImagePropertyPNGDescription: marker,
                ],
            ] as CFDictionary
        }
        for image in images {
            CGImageDestinationAddImage(destination, image, properties)
        }
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func decodedImage(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    struct PNGChunk {
        let offset: Int
        let typeOffset: Int
        let dataRange: Range<Int>
        let crcOffset: Int
    }

    static let idat: UInt32 = 0x4944_4154
    static let iend: UInt32 = 0x4945_4E44

    static func chunks(ofType expectedType: UInt32, in data: Data) -> [PNGChunk] {
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

    static func rewriteCRC(for chunk: PNGChunk, in data: inout Data) {
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

    static func uint32(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 |
            UInt32(bytes[offset + 1]) << 16 |
            UInt32(bytes[offset + 2]) << 8 |
            UInt32(bytes[offset + 3])
    }
}
