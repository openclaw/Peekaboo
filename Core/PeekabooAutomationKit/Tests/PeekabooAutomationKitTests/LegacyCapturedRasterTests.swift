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
        let sourceImage = try CapturePNGTestFixtures.makeImage(width: 8, height: 6)
        let sourcePNG = try CapturePNGTestFixtures.pngData(image: sourceImage, marker: "peekaboo-source-marker")
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
        let sourceImage = try CapturePNGTestFixtures.makeImage(width: 8, height: 6)
        let sourcePNG = try CapturePNGTestFixtures.pngData(image: sourceImage, marker: "must-not-survive-transform")
        let raster = try LegacyCapturedRaster(systemScreencapturePNG: sourcePNG)

        let logicalOne = ScreenCaptureImageScaler.maybeDownscale(
            raster.image,
            scale: .logical1x,
            fallbackScale: 2)
        let deliveredPNG = try raster.pngData(for: logicalOne)
        let deliveredImage = try CapturePNGTestFixtures.decodedImage(deliveredPNG)

        #expect(logicalOne !== raster.image)
        #expect(deliveredPNG != sourcePNG)
        #expect(deliveredPNG.range(of: Data("must-not-survive-transform".utf8)) == nil)
        #expect(deliveredImage.width == 4)
        #expect(deliveredImage.height == 3)
    }

    @Test
    func `bad CRC and invalid IDAT fail before source bytes can be retained`() throws {
        let validPNG = try CapturePNGTestFixtures.pngData(image: CapturePNGTestFixtures.makeImage(
            width: 64,
            height: 48))
        let idatChunks = CapturePNGTestFixtures.chunks(ofType: CapturePNGTestFixtures.idat, in: validPNG)
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
            CapturePNGTestFixtures.rewriteCRC(for: chunk, in: &invalidIDAT)
        }
        #expect(CGImageSourceCreateWithData(invalidIDAT as CFData, nil) != nil)
        #expect(LegacyPNGValidator.hasValidStructureAndCRC(invalidIDAT))
        #expect(throws: PeekabooError.self) {
            try LegacyCapturedRaster(systemScreencapturePNG: invalidIDAT)
        }
    }

    @Test
    func `missing IEND truncation and overflowing chunk lengths fail structurally`() throws {
        let validPNG = try CapturePNGTestFixtures.pngData(image: CapturePNGTestFixtures.makeImage(width: 8, height: 6))
        let iend = try #require(CapturePNGTestFixtures.chunks(ofType: CapturePNGTestFixtures.iend, in: validPNG).first)
        let idat = try #require(CapturePNGTestFixtures.chunks(ofType: CapturePNGTestFixtures.idat, in: validPNG).first)
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
        let sourceImage = try CapturePNGTestFixtures.makeImage(width: 5, height: 3)
        let raster = LegacyCapturedRaster(image: sourceImage)
        let encoded = try raster.pngData(for: sourceImage)
        let decoded = try CapturePNGTestFixtures.decodedImage(encoded)

        #expect(raster.sourcePNG == nil)
        #expect(!encoded.isEmpty)
        #expect(decoded.width == 5)
        #expect(decoded.height == 3)
    }
}
