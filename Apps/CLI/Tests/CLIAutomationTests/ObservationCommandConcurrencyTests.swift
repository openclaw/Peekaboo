import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
@MainActor
struct ObservationCommandConcurrencyTests {
    @Test
    func `Slow See detection does not block Image capture`() async throws {
        let probe = ObservationCommandConcurrencyProbe()
        let app = ServiceApplicationInfo(
            processIdentifier: 4242,
            bundleIdentifier: "com.example.concurrent",
            name: "ConcurrentApp",
            isActive: true,
            windowCount: 1
        )
        let window = ServiceWindowInfo(
            windowID: 101,
            title: "Concurrent Window",
            bounds: CGRect(x: 20, y: 30, width: 800, height: 600),
            isMainWindow: true
        )
        let windowCapture = CaptureResult(
            imageData: Data(repeating: 0xAB, count: 32),
            metadata: CaptureMetadata(
                size: window.bounds.size,
                mode: .window,
                applicationInfo: app,
                windowInfo: window
            )
        )
        let screenCapture = StubScreenCaptureService(permissionGranted: true)
        screenCapture.defaultCaptureResult = windowCapture
        screenCapture.captureScreenHandler = { _, _ in
            probe.markImageCaptureStarted()
            return CaptureResult(
                imageData: Data(repeating: 0xCD, count: 32),
                metadata: CaptureMetadata(
                    size: CGSize(width: 320, height: 240),
                    mode: .screen,
                    displayInfo: DisplayInfo(
                        index: 0,
                        name: "Fixture Display",
                        bounds: CGRect(x: 0, y: 0, width: 320, height: 240),
                        scaleFactor: 1
                    )
                )
            )
        }

        let automation = StubAutomationService()
        automation.detectElementsHandler = { _, snapshotID, _ in
            await probe.suspendSeeDetection()
            return ElementDetectionResult(
                snapshotId: snapshotID ?? "see-snapshot",
                screenshotPath: "/tmp/ignored.png",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "stub",
                    windowContext: WindowContext(
                        applicationName: app.name,
                        applicationBundleId: app.bundleIdentifier,
                        applicationProcessId: app.processIdentifier,
                        windowTitle: window.title,
                        windowID: window.windowID,
                        windowBounds: window.bounds
                    )
                )
            )
        }

        let windowsByApp = [
            app.name: [window],
            "com.example.concurrent": [window],
        ]
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [app], windowsByApp: windowsByApp),
            windows: StubWindowService(windowsByApp: windowsByApp),
            automation: automation,
            screenCapture: screenCapture
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-observation-concurrency-\(UUID().uuidString)", isDirectory: true)
        let seePath = directory.appendingPathComponent("see.png")
        let imagePath = directory.appendingPathComponent("image.png")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var see = try SeeCommand.parse([
            "--mode", "frontmost",
            "--no-web-focus",
            "--path", seePath.path,
        ])
        let seeRuntime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: false, logLevel: nil),
            services: services
        )
        let seeTask = Task { @MainActor in
            try await see.run(using: seeRuntime)
        }
        defer {
            probe.releaseSeeDetection()
            seeTask.cancel()
        }

        try await probe.waitForSeeDetection()

        var image = try SeeCommand.parse([
            "--mode", "screen",
            "--screen-index", "0",
            "--no-elements",
            "--path", imagePath.path,
        ])
        let imageRuntime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: false, logLevel: nil),
            services: services
        )
        let imageTask = Task { @MainActor in
            try await image.run(using: imageRuntime)
        }
        defer { imageTask.cancel() }

        try await probe.waitForImageCapture()
        probe.releaseSeeDetection()

        try await seeTask.value
        try await imageTask.value
        #expect(FileManager.default.fileExists(atPath: seePath.path))
        #expect(FileManager.default.fileExists(atPath: imagePath.path))
    }
}

@MainActor
private final class ObservationCommandConcurrencyProbe {
    private var seeDetectionStarted = false
    private var imageCaptureStarted = false
    private var seeDetectionReleased = false
    private var seeDetectionContinuation: CheckedContinuation<Void, Never>?

    func suspendSeeDetection() async {
        self.seeDetectionStarted = true
        guard !self.seeDetectionReleased else { return }
        await withCheckedContinuation { continuation in
            self.seeDetectionContinuation = continuation
        }
    }

    func releaseSeeDetection() {
        self.seeDetectionReleased = true
        self.seeDetectionContinuation?.resume()
        self.seeDetectionContinuation = nil
    }

    func markImageCaptureStarted() {
        self.imageCaptureStarted = true
    }

    func waitForSeeDetection() async throws {
        try await self.waitUntil { self.seeDetectionStarted }
    }

    func waitForImageCapture() async throws {
        try await self.waitUntil { self.imageCaptureStarted }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ObservationCommandConcurrencyError.timedOut
    }
}

private enum ObservationCommandConcurrencyError: Error {
    case timedOut
}
