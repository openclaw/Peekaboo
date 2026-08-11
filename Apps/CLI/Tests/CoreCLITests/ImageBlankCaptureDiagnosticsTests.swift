import AppKit
import Darwin
import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(.serialized)
struct ImageBlankCaptureDiagnosticsTests {
    @Test
    func `Missing artifact still diagnoses current capture pixels`() throws {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-missing-\(UUID().uuidString).png")
            .path
        let capture = try self.capture(
            imageData: self.pngData(width: 32, height: 32) { _, _ in (0, 0, 0, 255) },
            savedPath: missingPath
        )

        let warnings = ImageBlankCaptureDiagnostics.warnings(capture: capture)

        #expect(warnings.count == 1)
        #expect(try #require(warnings.first).contains("solid black"))
        #expect(!FileManager.default.fileExists(atPath: missingPath))
    }

    @Test
    func `Stale artifact cannot replace current capture pixels`() throws {
        let staleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-stale-\(UUID().uuidString).png")
        try self.pngData(width: 32, height: 32) { _, _ in (255, 255, 255, 255) }
            .write(to: staleURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: staleURL) }
        let capture = try self.capture(
            imageData: self.pngData(width: 32, height: 32) { _, _ in (0, 0, 0, 255) },
            savedPath: staleURL.path
        )

        let warnings = ImageBlankCaptureDiagnostics.warnings(capture: capture)

        #expect(warnings.count == 1)
        let warning = try #require(warnings.first)
        #expect(warning.contains("solid black"))
        #expect(!warning.contains("blank white"))
    }

    @Test
    func `Current nonblank pixels ignore a stale blank artifact`() throws {
        let staleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-stale-blank-\(UUID().uuidString).png")
        try self.pngData(width: 32, height: 32) { _, _ in (0, 0, 0, 255) }
            .write(to: staleURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: staleURL) }
        let capture = try self.capture(
            imageData: self.pngData(width: 32, height: 32) { x, y in
                (UInt8((x * 17) % 255), UInt8((y * 29) % 255), UInt8(((x + y) * 11) % 255), 255)
            },
            savedPath: staleURL.path
        )

        #expect(ImageBlankCaptureDiagnostics.warnings(capture: capture).isEmpty)
    }

    @Test
    func `Large window PNG and JPEG diagnostics benchmark avoids artifact bytes`() throws {
        let pngData = try self.pngData(width: 1920, height: 1080) { x, y in
            let mixed = UInt32(truncatingIfNeeded: x &* 1_103_515_245 &+ y &* 12345)
            return (
                UInt8(truncatingIfNeeded: mixed),
                UInt8(truncatingIfNeeded: mixed >> 8),
                UInt8(truncatingIfNeeded: mixed >> 16),
                255
            )
        }
        let bitmap = try #require(NSBitmapImageRep(data: pngData))
        let jpegData = try #require(bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.92]
        ))
        let iterations = 3

        let png = try self.benchmark(
            artifactData: pngData,
            currentCaptureData: pngData,
            fileExtension: "png",
            iterations: iterations
        )
        let jpeg = try self.benchmark(
            artifactData: jpegData,
            currentCaptureData: pngData,
            fileExtension: "jpg",
            iterations: iterations
        )

        #expect(png.bytesRead == pngData.count * iterations)
        #expect(jpeg.bytesRead == jpegData.count * iterations)
        #expect(png.legacySignature == png.currentSignature)
        #expect(abs(jpeg.legacySignature - jpeg.currentSignature) / jpeg.currentSignature < 0.05)
        self.printBenchmark("png", fileBytes: pngData.count, iterations: iterations, result: png)
        self.printBenchmark("jpeg", fileBytes: jpegData.count, iterations: iterations, result: jpeg)
    }

    private func capture(imageData: Data, savedPath: String) throws -> CaptureResult {
        let bitmap = try #require(NSBitmapImageRep(data: imageData))
        return CaptureResult(
            imageData: imageData,
            savedPath: savedPath,
            metadata: CaptureMetadata(
                size: CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh),
                mode: .window,
                timestamp: Date()
            )
        )
    }

    private func pngData(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let bytes = try #require(bitmap.bitmapData)
        for y in 0..<height {
            for x in 0..<width {
                let (red, green, blue, alpha) = pixel(x, y)
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = red
                bytes[offset + 1] = green
                bytes[offset + 2] = blue
                bytes[offset + 3] = alpha
            }
        }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func diagnosticSignature(data: Data) throws -> Double {
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let xStep = max(1, width / min(width, 20))
        let yStep = max(1, height / min(height, 20))
        var signature = 0.0
        for y in stride(from: 0, to: height, by: yStep) {
            for x in stride(from: 0, to: width, by: xStep) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                signature += Double(color.redComponent + color.greenComponent + color.blueComponent)
            }
        }
        return signature
    }

    private struct BenchmarkResult {
        let bytesRead: Int
        let legacySignature: Double
        let currentSignature: Double
        let legacyWall: Double
        let currentWall: Double
        let legacyCPU: Double
        let currentCPU: Double
    }

    private func benchmark(
        artifactData: Data,
        currentCaptureData: Data,
        fileExtension: String,
        iterations: Int
    ) throws -> BenchmarkResult {
        let artifactURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-blank-benchmark-\(UUID().uuidString).\(fileExtension)")
        try artifactData.write(to: artifactURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: artifactURL) }

        _ = try self.diagnosticSignature(data: Data(contentsOf: artifactURL))
        _ = try self.diagnosticSignature(data: currentCaptureData)

        var legacyBytesRead = 0
        var legacySignature = 0.0
        let legacyStart = ContinuousClock.now
        let legacyCPUStart = Self.processCPUTime()
        for _ in 0..<iterations {
            let bytes = try Data(contentsOf: artifactURL)
            legacyBytesRead += bytes.count
            legacySignature += try self.diagnosticSignature(data: bytes)
        }
        let legacyCPU = Self.processCPUTime() - legacyCPUStart
        let legacyWall = Self.milliseconds(legacyStart.duration(to: ContinuousClock.now))

        var currentSignature = 0.0
        let currentStart = ContinuousClock.now
        let currentCPUStart = Self.processCPUTime()
        for _ in 0..<iterations {
            currentSignature += try self.diagnosticSignature(data: currentCaptureData)
        }
        let currentCPU = Self.processCPUTime() - currentCPUStart
        let currentWall = Self.milliseconds(currentStart.duration(to: ContinuousClock.now))

        return BenchmarkResult(
            bytesRead: legacyBytesRead,
            legacySignature: legacySignature,
            currentSignature: currentSignature,
            legacyWall: legacyWall,
            currentWall: currentWall,
            legacyCPU: legacyCPU,
            currentCPU: currentCPU
        )
    }

    private func printBenchmark(
        _ format: String,
        fileBytes: Int,
        iterations: Int,
        result: BenchmarkResult
    ) {
        print(
            "blank-diagnostics benchmark format=\(format) " +
                "file_bytes=\(fileBytes) iterations=\(iterations) avoided_bytes=\(result.bytesRead) " +
                "legacy_wall_ms=\(String(format: "%.3f", result.legacyWall)) " +
                "current_wall_ms=\(String(format: "%.3f", result.currentWall)) " +
                "legacy_cpu_ms=\(String(format: "%.3f", result.legacyCPU * 1000)) " +
                "current_cpu_ms=\(String(format: "%.3f", result.currentCPU * 1000))"
        )
    }

    private static func processCPUTime() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds * 1000) +
            Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
