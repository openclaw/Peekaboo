import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
struct SeeToolImageOwnershipTests {
    @Test
    func `concurrent calls sharing a public path return their own pixels`() async throws {
        let firstPixels = Data("first-capture".utf8)
        let secondPixels = Data("second-capture".utf8)
        let observation = await MainActor.run {
            CoordinatedFileOnlyObservationService(imageData: [firstPixels, secondPixels])
        }
        let context = await self.makeContext(desktopObservation: observation)
        let tool = SeeTool(context: context)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-see-shared-\(UUID().uuidString).png")
        let annotatedURL = URL(fileURLWithPath: ObservationOutputWriter.annotatedScreenshotPath(
            forRawScreenshotPath: outputURL.path))
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: annotatedURL)
        }

        async let firstResponse = tool.execute(arguments: ToolArguments(raw: [
            "path": outputURL.path,
            "annotate": true,
        ]))
        async let secondResponse = tool.execute(arguments: ToolArguments(raw: [
            "path": outputURL.path,
            "annotate": true,
        ]))
        let responses = try await [firstResponse, secondResponse]
        let returnedPixels = try responses.map(Self.imageData)

        #expect(Set(returnedPixels) == Set([firstPixels, secondPixels]))
        let observationPaths = await MainActor.run { observation.observationPaths }
        #expect(observationPaths.count == 2)
        #expect(Set(observationPaths).count == 2)
        #expect(!observationPaths.contains(outputURL.path))
        #expect(observationPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        #expect(observationPaths.allSatisfy {
            !FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).deletingLastPathComponent().path)
        })
        for response in responses {
            let summary = try Self.summary(response)
            #expect(summary.contains(annotatedURL.path))
            #expect(!summary.contains("peekaboo-see-response-"))
        }
    }

    @Test
    func `annotated response returns annotated pixels while raw file stays raw`() async throws {
        let rawPixels = Data("raw-capture".utf8)
        let annotatedPixels = Data("annotated-capture".utf8)
        let observation = await MainActor.run {
            AnnotatedFileOnlyObservationService(rawData: rawPixels, annotatedData: annotatedPixels)
        }
        let context = await self.makeContext(desktopObservation: observation)
        let tool = SeeTool(context: context)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-see-annotated-\(UUID().uuidString).png")
        let annotatedURL = URL(fileURLWithPath: ObservationOutputWriter.annotatedScreenshotPath(
            forRawScreenshotPath: outputURL.path))
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: annotatedURL)
        }

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "path": outputURL.path,
            "annotate": true,
        ]))

        #expect(response.isError == false)
        #expect(try Self.imageData(response) == annotatedPixels)
        #expect(try Data(contentsOf: outputURL) == rawPixels)
        #expect(try Data(contentsOf: annotatedURL) == annotatedPixels)
        let summary = try Self.summary(response)
        #expect(summary.contains(annotatedURL.path))
        #expect(!summary.contains("peekaboo-see-response-"))
    }

    @Test
    func `caller path replacement cannot redirect returned pixels`() async throws {
        let rawPixels = Data("owned-capture".utf8)
        let sentinel = Data("do-not-replace".utf8)
        let observation = await MainActor.run {
            AnnotatedFileOnlyObservationService(rawData: rawPixels, annotatedData: Data("unused".utf8))
        }
        let context = await self.makeContext(desktopObservation: observation)
        let tool = SeeTool(context: context)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-see-symlink-\(UUID().uuidString)", isDirectory: true)
        let victimURL = directory.appendingPathComponent("victim.png")
        let outputURL = directory.appendingPathComponent("output.png")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try sentinel.write(to: victimURL)
        try FileManager.default.createSymbolicLink(at: outputURL, withDestinationURL: victimURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        let response = try await tool.execute(arguments: ToolArguments(raw: ["path": outputURL.path]))

        #expect(response.isError == false)
        #expect(try Self.imageData(response) == rawPixels)
        #expect(try Data(contentsOf: victimURL) == sentinel)
    }

    @Test
    func `response ignores untrusted in memory pixels and returns its owned artifact`() async throws {
        let ownedPixels = Data("owned-artifact".utf8)
        let untrustedPixels = Data("untrusted-in-memory-capture".utf8)
        let observation = await MainActor.run {
            AnnotatedFileOnlyObservationService(
                rawData: ownedPixels,
                annotatedData: Data("unused".utf8),
                captureData: untrustedPixels)
        }
        let context = await self.makeContext(desktopObservation: observation)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-see-owned-raster-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let response = try await SeeTool(context: context).execute(arguments: ToolArguments(raw: [
            "path": outputURL.path,
        ]))

        #expect(response.isError == false)
        #expect(try Self.imageData(response) == ownedPixels)
        #expect(try Self.imageData(response) != untrustedPixels)
        #expect(try Data(contentsOf: outputURL) == ownedPixels)
    }

    @Test
    func `post-processing failure preserves dispatched web focus outcome and process target`() async throws {
        let observation = await MainActor.run { OutcomeMissingArtifactObservationService() }
        let context = await self.makeContext(desktopObservation: observation)

        let response = try await SeeTool(context: context).execute(arguments: ToolArguments(raw: [
            "web_focus": true,
        ]))

        #expect(response.isError)
        guard case let .object(meta)? = response.meta,
              case let .object(targetReceipt)? = meta["target_receipt"]
        else {
            Issue.record("Expected canonical action metadata")
            return
        }
        #expect(meta["state"] == .string("dispatched_unverified"))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["requires_fresh_observation"] == .bool(true))
        #expect(targetReceipt["pid"] == .int(5351))
        #expect(targetReceipt["process_start_identity_decimal"] == .string("6351"))
        #expect(targetReceipt["window_id"] == nil)
    }

    @Test
    func `See rejects a nonthrowing suspected-noop provider outcome before publication`() async throws {
        let target = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 5352,
            processStartIdentity: 6352))
        let observation = await MainActor.run {
            OutcomeFileObservationService(
                outcome: .suspectedNoop(
                    route: .bridge,
                    delivery: .init(mechanism: .accessibilityAction, mode: .background),
                    unitCount: .one),
                targetIdentity: target)
        }
        let context = await self.makeContext(desktopObservation: observation)

        let response = try await SeeTool(context: context).execute(arguments: ToolArguments(raw: [
            "web_focus": true,
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        let receipt = try #require(meta["target_receipt"]?.objectValue)
        #expect(meta["state"] == .string("suspected_noop"))
        #expect(meta["dispatched_unit_count"] == .int(1))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(receipt["pid"] == .int(5352))
        #expect(receipt["process_start_identity_decimal"] == .string("6352"))
        #expect(receipt["window_id"] == nil)
    }

    @Test
    func `ROI response exposes local elements and snapshot bound coordinate metadata`() async throws {
        let observation = await MainActor.run { ROIFileObservationService() }
        let context = await self.makeContext(desktopObservation: observation)
        let response = try await SeeTool(context: context).execute(arguments: ToolArguments(raw: [
            "window_id": 42,
            "roi": "10,20,30,20",
        ]))

        #expect(response.isError == false)
        #expect(try Self.summary(response).contains("at (5, 5) size 10×5"))
        let request = try #require(await MainActor.run { observation.lastRequest })
        #expect(request.target == .windowID(42))
        #expect(request.capture.roi?.bounds == CGRect(x: 10, y: 20, width: 30, height: 20))

        guard case let .object(meta) = response.meta,
              case let .string(snapshotID)? = meta["snapshot_id"],
              case let .object(context)? = meta["coordinate_context"],
              case let .object(viewport)? = context["viewport"],
              case let .object(logicalBounds)? = viewport["logical_bounds"],
              case let .double(logicalX)? = logicalBounds["x"],
              case let .double(logicalWidth)? = logicalBounds["width"]
        else {
            Issue.record("Expected ROI coordinate metadata in See response")
            return
        }
        #expect(logicalX == 210)
        #expect(logicalWidth == 30)
        #expect(!snapshotID.isEmpty)
    }

    private func makeContext(
        desktopObservation: any DesktopObservationServiceProtocol) async -> MCPToolContext
    {
        let base = await MCPToolTestHelpers.makeContext()
        return await MainActor.run {
            MCPToolContext(
                automation: base.automation,
                menu: base.menu,
                windows: base.windows,
                applications: base.applications,
                dialogs: base.dialogs,
                dock: base.dock,
                screenCapture: base.screenCapture,
                desktopObservation: desktopObservation,
                snapshots: base.snapshots,
                screens: base.screens,
                agent: base.agent,
                permissions: base.permissions,
                clipboard: base.clipboard,
                browser: base.browser,
                snapshotMutationCoordinator: base.snapshotMutationCoordinator,
                snapshotExecutionGate: base.snapshotExecutionGate)
        }
    }

    private static func imageData(_ response: ToolResponse) throws -> Data {
        guard response.isError == false,
              let image = response.content.first(where: {
                  if case .image = $0 {
                      return true
                  }
                  return false
              }),
              case let .image(data: base64, mimeType: _, annotations: _, _meta: _) = image,
              let data = Data(base64Encoded: base64)
        else {
            throw PeekabooError.operationError(message: "Expected successful image response")
        }
        return data
    }

    private static func summary(_ response: ToolResponse) throws -> String {
        guard let text = response.content.first,
              case let .text(summary, annotations: _, _meta: _) = text
        else {
            throw PeekabooError.operationError(message: "Expected text summary")
        }
        return summary
    }
}

@MainActor
private final class CoordinatedFileOnlyObservationService: DesktopObservationServiceProtocol {
    private let imageData: [Data]
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private(set) var observationPaths: [String] = []

    init(imageData: [Data]) {
        self.imageData = imageData
    }

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        let index = self.observationPaths.count
        let path = try #require(request.output.path)
        let annotatedPath = ObservationOutputWriter.annotatedScreenshotPath(forRawScreenshotPath: path)
        self.observationPaths.append(path)
        let pixels = self.imageData[index]
        try pixels.write(to: URL(fileURLWithPath: path), options: .atomic)
        try pixels.write(to: URL(fileURLWithPath: annotatedPath), options: .atomic)

        if index == 0 {
            await withCheckedContinuation { continuation in
                self.firstContinuation = continuation
            }
        } else {
            self.firstContinuation?.resume()
            self.firstContinuation = nil
        }

        return Self.result(path: path, annotatedPath: annotatedPath)
    }

    private static func result(path: String, annotatedPath: String) -> DesktopObservationResult {
        DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: Data(),
                savedPath: path,
                metadata: CaptureMetadata(
                    size: CGSize(width: 1, height: 1),
                    mode: .screen,
                    timestamp: Date())),
            elements: nil,
            files: DesktopObservationFiles(
                rawScreenshotPath: path,
                annotatedScreenshotPath: annotatedPath))
    }
}

@MainActor
private final class AnnotatedFileOnlyObservationService: DesktopObservationServiceProtocol {
    private let rawData: Data
    private let annotatedData: Data
    private let captureData: Data

    init(rawData: Data, annotatedData: Data, captureData: Data = Data()) {
        self.rawData = rawData
        self.annotatedData = annotatedData
        self.captureData = captureData
    }

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        let path = try #require(request.output.path)
        let annotatedPath = ObservationOutputWriter.annotatedScreenshotPath(forRawScreenshotPath: path)
        try self.rawData.write(to: URL(fileURLWithPath: path), options: .atomic)
        try self.annotatedData.write(to: URL(fileURLWithPath: annotatedPath), options: .atomic)
        return DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: self.captureData,
                savedPath: path,
                metadata: CaptureMetadata(
                    size: CGSize(width: 1, height: 1),
                    mode: .screen,
                    timestamp: Date())),
            elements: ElementDetectionResult(
                snapshotId: request.output.snapshotID ?? "snapshot",
                screenshotPath: path,
                elements: DetectedElements(),
                metadata: DetectionMetadata(detectionTime: 0, elementCount: 0, method: "mock")),
            files: DesktopObservationFiles(
                rawScreenshotPath: path,
                annotatedScreenshotPath: annotatedPath))
    }
}

@MainActor
private final class ROIFileObservationService: DesktopObservationServiceProtocol {
    private(set) var lastRequest: DesktopObservationRequest?

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.lastRequest = request
        let path = try #require(request.output.path)
        let pixels = Data("roi-capture".utf8)
        try pixels.write(to: URL(fileURLWithPath: path), options: .atomic)
        let sourceBounds = CGRect(x: 200, y: 300, width: 100, height: 80)
        let requested = try #require(request.capture.roi?.bounds)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 456,
            capturedBounds: sourceBounds)
        let viewport = CaptureViewport(
            sourceLogicalBounds: sourceBounds,
            requestedWindowRelativeBounds: requested,
            deliveredWindowRelativeBounds: requested,
            logicalBounds: CGRect(
                x: sourceBounds.minX + requested.minX,
                y: sourceBounds.minY + requested.minY,
                width: requested.width,
                height: requested.height),
            sourceImageSize: sourceBounds.size)
        let metadata = CaptureMetadata(
            size: requested.size,
            mode: .window,
            applicationInfo: ServiceApplicationInfo(
                processIdentifier: 123,
                processStartIdentity: 456,
                bundleIdentifier: "test.roi",
                name: "ROI Fixture"),
            windowInfo: ServiceWindowInfo(
                windowID: 42,
                title: "ROI Window",
                bounds: sourceBounds,
                mutationIdentity: identity),
            viewport: viewport)
        let snapshotID = request.output.snapshotID ?? "snapshot"
        return DesktopObservationResult(
            target: ResolvedObservationTarget(
                kind: .windowID(42),
                app: ApplicationIdentity(
                    processIdentifier: 123,
                    processStartIdentity: 456,
                    bundleIdentifier: "test.roi",
                    name: "ROI Fixture"),
                window: WindowIdentity(windowID: 42, title: "ROI Window", bounds: sourceBounds, index: 0),
                bounds: sourceBounds,
                detectionContext: WindowContext(
                    applicationName: "ROI Fixture",
                    applicationBundleId: "test.roi",
                    applicationProcessId: 123,
                    windowTitle: "ROI Window",
                    windowID: 42,
                    windowBounds: sourceBounds,
                    windowMutationIdentity: identity)),
            capture: CaptureResult(imageData: pixels, savedPath: path, metadata: metadata),
            elements: ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: path,
                elements: DetectedElements(buttons: [
                    DetectedElement(
                        id: "B1",
                        type: .button,
                        label: "Inside",
                        bounds: CGRect(x: 215, y: 325, width: 10, height: 5)),
                ]),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 1,
                    method: "test",
                    windowContext: WindowContext(
                        applicationProcessId: 123,
                        windowID: 42,
                        windowBounds: sourceBounds,
                        windowMutationIdentity: identity),
                    truncationInfo: nil,
                    captureCoordinateContext: CaptureCoordinateContext(
                        metadata: metadata,
                        referenceID: snapshotID))),
            files: DesktopObservationFiles(rawScreenshotPath: path))
    }
}

@MainActor
private final class OutcomeMissingArtifactObservationService: DesktopObservationActionResultProviding {
    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        try await self.observeActionResult(request).payload
    }

    func observeActionResult(
        _ request: DesktopObservationRequest) async throws -> UIAutomationActionResult<DesktopObservationResult>
    {
        let path = try #require(request.output.path)
        let result = DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: Data(),
                savedPath: path,
                metadata: CaptureMetadata(
                    size: CGSize(width: 1, height: 1),
                    mode: .screen,
                    timestamp: Date())),
            elements: nil,
            files: DesktopObservationFiles(rawScreenshotPath: path))
        return try UIAutomationActionResult(
            payload: result,
            outcome: .dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .capturePipeline, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one),
            targetIdentity: DesktopTargetIdentity(processIdentity: .init(
                processIdentifier: 5351,
                processStartIdentity: 6351)))
    }
}

@MainActor
private final class OutcomeFileObservationService: DesktopObservationActionResultProviding {
    private let outcome: DesktopActionOutcome
    private let targetIdentity: DesktopTargetIdentity

    init(outcome: DesktopActionOutcome, targetIdentity: DesktopTargetIdentity) {
        self.outcome = outcome
        self.targetIdentity = targetIdentity
    }

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        try await self.observeActionResult(request).payload
    }

    func observeActionResult(
        _ request: DesktopObservationRequest) async throws -> UIAutomationActionResult<DesktopObservationResult>
    {
        let path = try #require(request.output.path)
        let pixels = Data("provider-outcome".utf8)
        try pixels.write(to: URL(fileURLWithPath: path), options: .atomic)
        let result = DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: pixels,
                savedPath: path,
                metadata: CaptureMetadata(
                    size: CGSize(width: 1, height: 1),
                    mode: .screen,
                    timestamp: Date())),
            elements: ElementDetectionResult(
                snapshotId: request.output.snapshotID ?? "snapshot",
                screenshotPath: path,
                elements: DetectedElements(),
                metadata: DetectionMetadata(detectionTime: 0, elementCount: 0, method: "fixture")),
            files: DesktopObservationFiles(rawScreenshotPath: path))
        return UIAutomationActionResult(
            payload: result,
            outcome: self.outcome,
            targetIdentity: self.targetIdentity)
    }
}
