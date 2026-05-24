import AppKit
import CoreGraphics
import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

#if !PEEKABOO_SKIP_AUTOMATION
@MainActor
extension ImageCommandTests {
    @Test(.tags(.imageCapture))
    func `JSON output includes observation diagnostics`() async throws {
        let captureResult = Self.makeScreenCaptureResult(size: CGSize(width: 1200, height: 800), scale: 1.0)
        let captureService = StubScreenCaptureService(permissionGranted: true)
        captureService.captureScreenHandler = { _, _ in
            captureResult
        }

        let services = TestServicesFactory.makePeekabooServices(
            screenCapture: captureService
        )
        let path = Self.makeTempCapturePath("diagnostics.png")

        let result = try await InProcessCommandRunner.run(
            [
                "image",
                "--mode", "screen",
                "--path", path,
                "--json",
            ],
            services: services
        )

        #expect(result.exitStatus == 0)
        let response = try JSONDecoder().decode(
            CodableJSONResponse<ImageCaptureResult>.self,
            from: Data(result.combinedOutput.utf8)
        )
        #expect(response.data.files.count == 1)
        #expect(response.data.observations.count == 1)
        #expect(response.data.observations[0].spans.contains { $0.name == "capture.screen" })
        #expect(response.data.observations[0].state_snapshot != nil)
        let coordinates = try #require(response.data.observations[0].coordinates)
        #expect(coordinates.coordinate_space == "global_display_points")
        #expect(coordinates.image_size_pixels.width == 1200)
        #expect(coordinates.image_size_pixels.height == 800)
        #expect(coordinates.logical_bounds?.width == 1200)
        #expect(coordinates.scale_factor == 1)
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test(.tags(.imageCapture))
    func `JSON output warns when captured window is solid black`() async throws {
        let appName = "BlankApp"
        let window = ServiceWindowInfo(
            windowID: 42,
            title: "Blank",
            bounds: CGRect(x: 20, y: 30, width: 120, height: 80)
        )
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 4242,
            bundleIdentifier: "dev.blank",
            name: appName,
            windowCount: 1
        )
        let metadata = CaptureMetadata(
            size: CGSize(width: 120, height: 80),
            mode: .window,
            applicationInfo: appInfo,
            windowInfo: window
        )
        let captureService = StubScreenCaptureService(permissionGranted: true)
        captureService.captureWindowByIdHandler = { _, _ in
            try CaptureResult(
                imageData: Self.solidPNG(width: 120, height: 80, color: .black),
                metadata: metadata
            )
        }

        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [appInfo], windowsByApp: [appName: [window]]),
            windows: StubWindowService(windowsByApp: [appName: [window]]),
            screenCapture: captureService
        )
        let path = Self.makeTempCapturePath("solid-black.png")

        let result = try await InProcessCommandRunner.run(
            [
                "image",
                "--app", appName,
                "--capture-focus", "background",
                "--path", path,
                "--json",
            ],
            services: services
        )

        #expect(result.exitStatus == 0)
        let response = try JSONDecoder().decode(
            CodableJSONResponse<ImageCaptureResult>.self,
            from: Data(result.combinedOutput.utf8)
        )
        #expect(response.data.observations[0].warnings.contains {
            $0.contains("solid black")
        })
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func solidPNG(width: Int, height: Int, color: NSColor) throws -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
#endif
