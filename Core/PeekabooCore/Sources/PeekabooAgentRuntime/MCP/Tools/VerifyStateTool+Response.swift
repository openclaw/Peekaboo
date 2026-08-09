import CoreGraphics
import Foundation
import MCP
import PeekabooAutomationKit
import TachikomaMCP

extension VerifyStateTool {
    func response(
        sample: VerifyStateSample,
        request: VerifyStateRequest,
        context: VerifyStateResponseContext,
        screenshotDeadlineExpired: Bool = false) async -> ToolResponse
    {
        let screenshot: ScreenshotResult? = if request.finalScreenshot, screenshotDeadlineExpired {
            .failure("Hard verification deadline expired before capture completed")
        } else if request.finalScreenshot {
            await self.finalScreenshot(
                for: sample.window,
                application: sample.application,
                identityTracker: context.identityTracker)
        } else {
            nil
        }
        let effectiveSample: VerifyStateSample
        let effectiveStableCount: Int
        if case let .identityFailure(reason) = screenshot {
            effectiveSample = VerifyStateSample(
                status: .unknown,
                application: sample.application,
                window: sample.window,
                predicates: sample.predicates,
                reason: reason)
            effectiveStableCount = 0
        } else {
            effectiveSample = sample
            effectiveStableCount = context.stableCount
        }
        var lines = [
            "Verification \(effectiveSample.status.rawValue) after \(context.sampleCount) sample(s) in " +
                "\(String(format: "%.3f", context.elapsedSeconds))s.",
        ]
        if let application = effectiveSample.application {
            lines.append("Application: \(application.name) (PID \(application.processIdentifier))")
        }
        if let window = effectiveSample.window {
            lines.append("Window: \(window.windowID) \"\(window.title)\"")
        }
        if let reason = effectiveSample.reason {
            lines.append("Reason: \(reason)")
        }
        lines.append("Predicates:")
        for (index, result) in effectiveSample.predicates.enumerated() {
            let observed = result.observed.map { "; observed \($0)" } ?? ""
            lines.append("\(index + 1). \(result.kind): \(result.status.rawValue) — \(result.detail)\(observed)")
        }

        var metadata: [String: Value] = [
            "status": .string(effectiveSample.status.rawValue),
            "sample_count": .int(context.sampleCount),
            "stable_samples": .int(effectiveStableCount),
            "required_stable_samples": .int(request.stableSamples),
            "elapsed_seconds": .double(context.elapsedSeconds),
            "target": request.receiptTargetMetadata,
            "predicates": .array(zip(request.predicates, effectiveSample.predicates).map {
                Self.predicateMetadata(request: $0.0, result: $0.1)
            }),
        ]
        if let application = effectiveSample.application {
            metadata["pid"] = .int(Int(application.processIdentifier))
            metadata["application"] = .string(application.name)
        }
        if let window = effectiveSample.window {
            metadata["window_id"] = .int(window.windowID)
            metadata["window_bounds"] = .object([
                "x": .double(Double(window.bounds.origin.x)),
                "y": .double(Double(window.bounds.origin.y)),
                "width": .double(Double(window.bounds.width)),
                "height": .double(Double(window.bounds.height)),
            ])
        }
        if let reason = effectiveSample.reason {
            metadata["reason"] = .string(reason)
        }

        var content: [MCP.Tool.Content] = [
            .text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil),
        ]
        if let screenshot {
            switch screenshot {
            case let .success(data):
                content.append(.image(
                    data: data.base64EncodedString(),
                    mimeType: "image/png",
                    annotations: nil,
                    _meta: nil))
                metadata["screenshot_attached"] = .bool(true)
            case let .failure(reason), let .identityFailure(reason):
                metadata["screenshot_attached"] = .bool(false)
                metadata["screenshot_error"] = .string(reason)
            }
        }

        return ToolResponse(content: content, meta: .object(metadata))
    }

    private func finalScreenshot(
        for window: ServiceWindowInfo?,
        application: ServiceApplicationInfo?,
        identityTracker: VerifyStateTargetIdentityTracker) async -> ScreenshotResult
    {
        guard let application, let window else { return .failure("No target window was resolved") }
        guard let resolvedApplication = await identityTracker.resolvedApplication(for: application) else {
            return .failure("The target process identity was not established")
        }
        if let reason = await identityTracker.validate(resolvedApplication) {
            return .identityFailure(reason)
        }
        guard await self.context.screenCapture.hasScreenRecordingPermission() else {
            return .failure("Screen Recording permission is not granted")
        }
        do {
            try Task.checkCancellation()
            let applications = try await self.context.applications.listApplications()
            guard case .success = applications.summary.status,
                  applications.metadata.warnings.isEmpty,
                  applications.data.applications.contains(where: {
                      $0.processIdentifier == application.processIdentifier
                  })
            else {
                return .failure("Could not re-resolve the exact target process before screenshot capture")
            }
            if let reason = await identityTracker.validate(resolvedApplication) {
                return .identityFailure(reason)
            }

            guard let liveWindow = self.windowIdentityProvider(CGWindowID(window.windowID)) else {
                return .failure(
                    "CoreGraphics no longer confirms window \(window.windowID) ownership by PID " +
                        "\(application.processIdentifier)")
            }
            if let reason = await identityTracker.validateWindow(
                liveWindow,
                application: resolvedApplication)
            {
                return .identityFailure(reason)
            }
            if let reason = await identityTracker.validate(resolvedApplication) {
                return .identityFailure(reason)
            }

            let capture = try await self.context.screenCapture.captureWindow(
                windowID: CGWindowID(window.windowID),
                visualizerMode: .none,
                scale: .logical1x)
            try Task.checkCancellation()
            guard capture.metadata.applicationInfo?.processIdentifier == application.processIdentifier,
                  capture.metadata.windowInfo?.windowID == window.windowID
            else {
                return .identityFailure("Captured window metadata did not confirm the exact target owner and window")
            }
            if let capturedMetadataWindow = capture.metadata.windowInfo,
               let reason = await identityTracker.validateWindow(
                   capturedMetadataWindow,
                   application: resolvedApplication)
            {
                return .identityFailure(reason)
            }
            guard let capturedWindow = self.windowIdentityProvider(CGWindowID(window.windowID)) else {
                return .identityFailure("Window identity changed while the exact screenshot was being captured")
            }
            if let reason = await identityTracker.validateWindow(
                capturedWindow,
                application: resolvedApplication)
            {
                return .identityFailure(reason)
            }
            if let reason = await identityTracker.validate(resolvedApplication) {
                return .identityFailure(reason)
            }
            guard !capture.imageData.isEmpty else {
                return .failure("Window capture returned no image data")
            }
            return .success(capture.imageData)
        } catch is CancellationError {
            return .failure("Screenshot capture was cancelled")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func predicateMetadata(
        request: VerifyStatePredicate,
        result: VerifyStatePredicateResult) -> Value
    {
        var metadata = request.receiptMetadata
        metadata.merge([
            "status": .string(result.status.rawValue),
            "detail": .string(result.detail),
        ], uniquingKeysWith: { _, new in new })
        if let observed = result.observed {
            metadata["observed"] = .string(observed)
        }
        return .object(metadata)
    }

    private enum ScreenshotResult {
        case success(Data)
        case failure(String)
        case identityFailure(String)
    }
}
