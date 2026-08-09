import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
extension ProcessService {
    func executeSeeCommand(_ step: ScriptStep, snapshotId: String?) async throws -> StepExecutionResult {
        let params = self.screenshotParameters(from: step)
        let captureResult = try await self.captureScreenshot(using: params)
        let screenshotPath = try self.saveScreenshot(
            captureResult,
            to: params.path)
        let resolvedSnapshotId = try await self.storeScreenshot(
            captureResult: captureResult,
            path: screenshotPath,
            existingSnapshotId: snapshotId)

        let mutationCertificate = try await self.annotateIfNeeded(
            shouldAnnotate: params.annotate ?? true,
            captureResult: captureResult,
            snapshotId: resolvedSnapshotId,
            params: params)

        return StepExecutionResult(
            output: .data([
                "snapshot_id": .success(resolvedSnapshotId),
                "screenshot_path": .success(screenshotPath),
            ]),
            snapshotId: resolvedSnapshotId,
            desktopMutationCompletedAt: mutationCertificate.completedAt,
            desktopMutationPreservationAllowed: mutationCertificate.preservationAllowed)
    }

    private func screenshotParameters(from step: ScriptStep) -> ProcessCommandParameters.ScreenshotParameters {
        if case let .screenshot(params) = step.params {
            return params
        }
        return ProcessCommandParameters.ScreenshotParameters(path: "screenshot.png")
    }

    private func captureScreenshot(using params: ProcessCommandParameters
        .ScreenshotParameters) async throws -> CaptureResult
    {
        let mode = params.mode ?? "window"
        switch mode {
        case "fullscreen":
            return try await self.screenCaptureService.captureScreen(
                displayIndex: params.display,
                visualizerMode: .none,
                scale: .logical1x)
        case "frontmost":
            return try await self.screenCaptureService.captureFrontmost(
                visualizerMode: .none,
                scale: .logical1x)
        case "window":
            let requestedPID = try await self.requestedProcessIdentifier(params)
            if let rawWindowID = params.windowId {
                guard let windowID = CGWindowID(exactly: rawWindowID), windowID != kCGNullWindowID else {
                    throw PeekabooError.invalidInput(
                        field: "windowId",
                        reason: "windowId must be between 1 and \(UInt32.max)")
                }
                guard let identity = SystemIdentityResolver.windowIdentity(windowID) else {
                    throw PeekabooError.windowNotFound(criteria: "window id \(rawWindowID)")
                }
                if let requestedPID, identity.ownerProcessIdentifier != requestedPID {
                    throw PeekabooError.invalidInput(
                        field: "target",
                        reason: "see target fields resolve to different processes")
                }
                return try await self.screenCaptureService.captureWindow(
                    windowID: windowID,
                    visualizerMode: .none,
                    scale: .logical1x)
            }
            if let requestedPID {
                return try await self.screenCaptureService.captureWindow(
                    appIdentifier: "PID:\(requestedPID)",
                    windowIndex: params.window.flatMap(Int.init),
                    visualizerMode: .none,
                    scale: .logical1x)
            }
            return try await self.screenCaptureService.captureFrontmost(
                visualizerMode: .none,
                scale: .logical1x)
        default:
            throw PeekabooError.invalidInput(
                field: "mode",
                reason: "Unsupported see mode '\(mode)'; use window, frontmost, or fullscreen")
        }
    }

    private func requestedProcessIdentifier(
        _ params: ProcessCommandParameters.ScreenshotParameters) async throws -> pid_t?
    {
        if let pid = params.pid, pid <= 0 {
            throw PeekabooError.invalidInput(field: "pid", reason: "pid must be greater than 0")
        }
        let explicitPID = params.pid.map { pid_t($0) }
        let appPID: pid_t? = if let app = params.app {
            try await pid_t(self.applicationService.findApplication(identifier: app).processIdentifier)
        } else {
            nil
        }
        if let explicitPID, let appPID, explicitPID != appPID {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: "see target fields resolve to different processes")
        }
        return explicitPID ?? appPID
    }

    private func saveScreenshot(
        _ captureResult: CaptureResult,
        to outputPath: String) throws -> String
    {
        guard !outputPath.isEmpty else {
            return captureResult.savedPath ?? ""
        }
        let resolvedPath = PathResolver.expandPath(outputPath)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: resolvedPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try captureResult.imageData.write(to: URL(fileURLWithPath: resolvedPath))
        return resolvedPath
    }

    private func storeScreenshot(
        captureResult: CaptureResult,
        path: String,
        existingSnapshotId: String?) async throws -> String
    {
        let snapshotIdentifier: String = if let existingSnapshotId {
            existingSnapshotId
        } else {
            try await self.snapshotManager.createSnapshot()
        }
        try await self.persistScreenshot(
            captureResult: captureResult,
            path: path,
            snapshotId: snapshotIdentifier)
        return snapshotIdentifier
    }

    private func persistScreenshot(
        captureResult: CaptureResult,
        path: String,
        snapshotId: String) async throws
    {
        let appInfo = captureResult.metadata.applicationInfo
        let windowInfo = captureResult.metadata.windowInfo
        try await self.snapshotManager.storeScreenshot(
            SnapshotScreenshotRequest(
                snapshotId: snapshotId,
                screenshotPath: path,
                applicationBundleId: appInfo?.bundleIdentifier,
                applicationProcessId: appInfo.map { Int32($0.processIdentifier) },
                applicationName: appInfo?.name,
                windowTitle: windowInfo?.title,
                windowBounds: windowInfo?.bounds,
                windowID: windowInfo?.windowID,
                windowMutationIdentity: DesktopObservationService.windowContext(from: captureResult)?
                    .windowMutationIdentity))
    }

    private func annotateIfNeeded(
        shouldAnnotate: Bool,
        captureResult: CaptureResult,
        snapshotId: String,
        params: ProcessCommandParameters.ScreenshotParameters) async throws
        -> (completedAt: Date?, preservationAllowed: Bool?)
    {
        guard shouldAnnotate else { return (nil, nil) }
        let captureContext = DesktopObservationService.windowContext(from: captureResult)
        let windowContext = WindowContext(
            applicationName: captureContext?.applicationName,
            applicationBundleId: captureContext?.applicationBundleId,
            applicationProcessId: captureContext?.applicationProcessId ?? params.pid,
            windowTitle: captureContext?.windowTitle,
            windowID: captureContext?.windowID ?? params.windowId,
            windowBounds: captureContext?.windowBounds,
            windowMutationIdentity: captureContext?.windowMutationIdentity)
        let detectionResult = try await uiAutomationService.detectElements(
            in: captureResult.imageData,
            snapshotId: snapshotId,
            windowContext: windowContext)
        try await self.snapshotManager.storeDetectionResult(
            snapshotId: snapshotId,
            result: detectionResult)
        return (
            detectionResult.metadata.desktopMutationCompletedAt,
            detectionResult.metadata.desktopMutationPreservationAllowed)
    }
}
