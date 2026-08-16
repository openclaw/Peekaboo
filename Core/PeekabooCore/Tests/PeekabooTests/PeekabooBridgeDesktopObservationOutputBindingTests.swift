import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeDesktopObservationOutputBindingTests: DesktopObservationBindingFixtureProviding {
    @Test
    @MainActor
    func `requested observation outputs bind live and offline receipts`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-output-binding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawURL = directory.appendingPathComponent("capture.png")
        let rawData = Data("signed raw pixels".utf8)
        try rawData.write(to: rawURL)

        let request = DesktopObservationRequest(
            target: .screen(index: 0),
            detection: .init(mode: .none),
            output: .init(
                path: rawURL.path,
                saveRawScreenshot: true,
                saveSnapshot: true,
                snapshotID: "requested-snapshot"))
        let result = Self.replacingOutput(
            Self.screenResult(index: 0),
            files: .init(
                rawScreenshotPath: rawURL.path,
                publishedSnapshotID: "requested-snapshot"),
            rawData: rawData)

        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: result) == nil)
        let handled = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try await Self.server(provider: ObservationProvider(result: result)).handleAuthorized(
                .desktopObservation(request),
                peer: nil,
                permissions: Self.permissions)
        }
        guard case .desktopObservation = handled.response else {
            Issue.record("Expected a live desktop observation response")
            return
        }

        let signed = try await Self.makeBundle(
            request: .desktopObservation(request),
            response: .desktopObservation(result),
            target: .global)
        try signed.validateIntegrity()
    }

    @Test
    func `observation output omissions and paths fail closed`() {
        let base = Self.screenResult(index: 0)
        let rawPath = "/tmp/peekaboo-output-binding/capture.png"
        let annotatedPath = ObservationOutputWriter.annotatedScreenshotPath(forRawScreenshotPath: rawPath)
        let rawData = Data("raw".utf8)
        let annotatedData = Data("annotated".utf8)
        let request = DesktopObservationRequest(
            target: .screen(index: 0),
            detection: .init(mode: .none),
            output: .init(
                path: rawPath,
                saveRawScreenshot: true,
                saveSnapshot: true,
                snapshotID: "snapshot-output"))
        let valid = Self.replacingOutput(
            base,
            files: .init(
                rawScreenshotPath: rawPath,
                publishedSnapshotID: "snapshot-output"),
            rawData: rawData)

        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: Self.replacingOutput(
                base,
                files: .init(publishedSnapshotID: "snapshot-output")))
            == "requested raw screenshot output")
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: Self.replacingOutput(
                base,
                files: .init(
                    rawScreenshotPath: "/tmp/peekaboo-output-binding/other.png",
                    publishedSnapshotID: "snapshot-output"),
                rawData: rawData))
            == "raw screenshot output path")
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: Self.replacingOutput(
                base,
                files: .init(rawScreenshotPath: rawPath),
                rawData: rawData))
            == "snapshot publication")
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: Self.replacingOutput(
                base,
                files: .init(
                    rawScreenshotPath: rawPath,
                    publishedSnapshotID: "forged-snapshot"),
                rawData: rawData))
            == "snapshot publication")

        var annotatedRequest = request
        annotatedRequest.output.saveAnnotatedScreenshot = true
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: annotatedRequest,
            result: valid) == "requested annotated screenshot output")
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: annotatedRequest,
            result: Self.replacingOutput(
                base,
                files: .init(
                    rawScreenshotPath: rawPath,
                    annotatedScreenshotPath: "/tmp/peekaboo-output-binding/wrong.png",
                    publishedSnapshotID: "snapshot-output"),
                rawData: rawData,
                annotatedData: annotatedData))
            == "requested annotated screenshot output")
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: annotatedRequest,
            result: Self.replacingOutput(
                base,
                files: .init(
                    rawScreenshotPath: rawPath,
                    annotatedScreenshotPath: annotatedPath,
                    publishedSnapshotID: "snapshot-output"),
                rawData: rawData,
                annotatedData: annotatedData)) == nil)

        let pathlessRequest = DesktopObservationRequest(
            target: .screen(index: 0),
            detection: .init(mode: .none))
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: pathlessRequest,
            result: Self.replacingOutput(
                base,
                files: .init(rawScreenshotPath: rawPath),
                rawData: rawData)) == "unexpected raw screenshot output")
        let captureOwnedPath = Self.replacingCaptureSavedPath(base, with: rawPath)
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: pathlessRequest,
            result: Self.replacingOutput(
                captureOwnedPath,
                files: .init(rawScreenshotPath: rawPath),
                rawData: rawData)) == nil)
    }

    @Test
    func `observation snapshot and digest forgeries fail closed`() async throws {
        let base = Self.screenResult(index: 0)
        let rawPath = "/tmp/peekaboo-output-binding/capture.png"
        let rawData = Data("raw".utf8)
        let request = DesktopObservationRequest(
            target: .screen(index: 0),
            detection: .init(mode: .none),
            output: .init(
                path: rawPath,
                saveRawScreenshot: true,
                saveSnapshot: true,
                snapshotID: "snapshot-output"))
        let valid = Self.replacingOutput(
            base,
            files: .init(
                rawScreenshotPath: rawPath,
                publishedSnapshotID: "snapshot-output"),
            rawData: rawData)

        let windowFixture = Self.windowResult(.init(
            processIdentifier: 42,
            generation: 1001,
            bundleIdentifier: "dev.peekaboo.fixture",
            applicationName: "Fixture",
            windowID: 73,
            title: "Document",
            index: 0))
        let detectionOptions = DesktopDetectionOptions(mode: .accessibility)
        let originalContext = try #require(windowFixture.result.target.detectionContext)
        let detectionContext = WindowContext(
            applicationName: originalContext.applicationName,
            applicationBundleId: originalContext.applicationBundleId,
            applicationProcessId: originalContext.applicationProcessId,
            windowTitle: originalContext.windowTitle,
            windowID: originalContext.windowID,
            windowBounds: originalContext.windowBounds,
            windowMutationIdentity: originalContext.windowMutationIdentity,
            shouldFocusWebContent: false,
            includeMenuBarElements: false,
            traversalBudget: detectionOptions.traversalBudget)
        let wrongDetectionSnapshot = Self.replacingElements(
            windowFixture.result,
            with: ElementDetectionResult(
                snapshotId: "forged-detection-snapshot",
                screenshotPath: "",
                elements: .init(),
                metadata: .init(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "fixture",
                    windowContext: detectionContext,
                    isDialog: false)))
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: .init(
                target: .windowID(73),
                detection: detectionOptions,
                output: .init(snapshotID: "requested-detection-snapshot")),
            result: wrongDetectionSnapshot) == "requested snapshot ID")

        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: Self.replacingDigest(valid, with: nil)) == "capture-content digest")
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(
            request: request,
            result: Self.replacingDigest(
                valid,
                with: .init(
                    captureImageData: base.capture.imageData,
                    rawScreenshotData: nil,
                    annotatedScreenshotData: nil))) == "raw screenshot content digest")

        let offlineForgeries = [
            Self.replacingOutput(
                base,
                files: .init(publishedSnapshotID: "snapshot-output")),
            Self.replacingOutput(
                base,
                files: .init(
                    rawScreenshotPath: "/tmp/peekaboo-output-binding/other.png",
                    publishedSnapshotID: "snapshot-output"),
                rawData: rawData),
            Self.replacingOutput(
                base,
                files: .init(
                    rawScreenshotPath: rawPath,
                    publishedSnapshotID: "forged-snapshot"),
                rawData: rawData),
            Self.replacingDigest(valid, with: nil),
        ]
        for forged in offlineForgeries {
            let signed = try await Self.makeBundle(
                request: .desktopObservation(request),
                response: .desktopObservation(forged),
                target: .global)
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try signed.validateIntegrity()
            }
        }
    }
}
