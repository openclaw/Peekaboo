import Foundation
import PeekabooAutomationKit
import PeekabooBridge

@MainActor
public final class RemoteDesktopObservationService: DesktopObservationServiceProtocol {
    private let client: PeekabooBridgeClient

    public init(client: PeekabooBridgeClient) {
        self.client = client
    }

    public func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        guard request.capture.roi != nil else {
            return try await self.client.desktopObservation(request)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-remote-roi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let quarantinePath = directory
            .appendingPathComponent("capture.\(request.output.format.rawValue)")
            .path
        var remoteRequest = request
        remoteRequest.output.path = quarantinePath

        let result: DesktopObservationResult
        do {
            result = try await self.client.desktopObservation(remoteRequest)
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            if let context = envelope.context,
               context.hasPrefix("capture_roi:"),
               let error = CaptureROIError(code: String(context.dropFirst("capture_roi:".count)))
            {
                throw error
            }
            throw envelope
        }
        try DesktopObservationROIProcessor.validateApplied(
            request.capture.roi,
            requestTarget: request.target,
            resolvedTarget: result.target,
            capture: result.capture)
        return try self.publishROIResult(
            result,
            request: request,
            quarantinePath: quarantinePath)
    }

    private func publishROIResult(
        _ result: DesktopObservationResult,
        request: DesktopObservationRequest,
        quarantinePath: String) throws -> DesktopObservationResult
    {
        let expectsRawArtifact = request.output.saveRawScreenshot ||
            request.output.saveAnnotatedScreenshot ||
            request.output.saveSnapshot
        var rawPath: String?
        if expectsRawArtifact {
            guard Self.sameFile(result.files.rawScreenshotPath, quarantinePath) else {
                throw CaptureROIError.hostDidNotApplyROI
            }
            let destination = request.output.path ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("peekaboo-roi-\(UUID().uuidString).\(request.output.format.rawValue)")
                .path
            try Self.publishArtifact(from: quarantinePath, to: destination)
            rawPath = destination
        }

        var annotatedPath: String?
        if let reportedAnnotatedPath = result.files.annotatedScreenshotPath {
            let quarantineAnnotatedPath = ObservationOutputWriter.annotatedScreenshotPath(
                forRawScreenshotPath: quarantinePath)
            guard Self.sameFile(reportedAnnotatedPath, quarantineAnnotatedPath),
                  let rawPath
            else {
                throw CaptureROIError.hostDidNotApplyROI
            }
            let destination = ObservationOutputWriter.annotatedScreenshotPath(forRawScreenshotPath: rawPath)
            try Self.publishArtifact(from: quarantineAnnotatedPath, to: destination)
            annotatedPath = destination
        }

        let capture = CaptureResult(
            imageData: result.capture.imageData,
            savedPath: rawPath,
            metadata: result.capture.metadata,
            warning: result.capture.warning)
        let elements = result.elements.map {
            ElementDetectionResult(
                snapshotId: $0.snapshotId,
                screenshotPath: rawPath ?? "",
                elements: $0.elements,
                metadata: $0.metadata)
        }
        return DesktopObservationResult(
            target: result.target,
            capture: capture,
            elements: elements,
            ocr: result.ocr,
            files: DesktopObservationFiles(
                rawScreenshotPath: rawPath,
                annotatedScreenshotPath: annotatedPath),
            timings: result.timings,
            diagnostics: result.diagnostics)
    }

    private static func sameFile(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        return URL(fileURLWithPath: lhs).standardizedFileURL == URL(fileURLWithPath: rhs).standardizedFileURL
    }

    private static func publishArtifact(from sourcePath: String, to destinationPath: String) throws {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
        } catch {
            throw CaptureROIError.invalidSourceImage
        }
        let destinationURL = URL(fileURLWithPath: destinationPath)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        do {
            try data.write(to: destinationURL, options: .atomic)
        } catch {
            throw CaptureROIError.invalidSourceImage
        }
    }
}
