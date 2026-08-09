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

    init(rawData: Data, annotatedData: Data) {
        self.rawData = rawData
        self.annotatedData = annotatedData
    }

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        let path = try #require(request.output.path)
        let annotatedPath = ObservationOutputWriter.annotatedScreenshotPath(forRawScreenshotPath: path)
        try self.rawData.write(to: URL(fileURLWithPath: path), options: .atomic)
        try self.annotatedData.write(to: URL(fileURLWithPath: annotatedPath), options: .atomic)
        return DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: Data(),
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
