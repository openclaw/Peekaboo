import Foundation
import PeekabooFoundation

@MainActor
extension ScreenCaptureService {
    typealias Metadata = [String: Any]

    enum CaptureOperation {
        case screen
        case window
        case frontmost
        case area

        var metricName: String {
            switch self {
            case .screen: "captureScreen"
            case .window: "captureWindow"
            case .frontmost: "captureFrontmost"
            case .area: "captureArea"
            }
        }

        var logLabel: String {
            switch self {
            case .screen: "screen capture"
            case .window: "window capture"
            case .frontmost: "frontmost window capture"
            case .area: "area capture"
            }
        }
    }

    struct WindowCaptureOptions {
        let visualizerMode: CaptureVisualizerMode
        let scale: CaptureScalePreference
    }

    struct CaptureInvocationContext {
        let operation: CaptureOperation
        let correlationId: String
    }

    func performOperation<T: Sendable>(
        _ operation: CaptureOperation,
        metadata: Metadata = [:],
        requiresPermission: Bool = true,
        body: @escaping @MainActor @Sendable (_ correlationId: String) async throws -> T) async throws -> T
    {
        let correlationId = UUID().uuidString
        self.logger.info(
            "Starting \(operation.logLabel)",
            metadata: metadata,
            correlationId: correlationId)

        // The logger returns an opaque token; keep it exact so duration metrics are always closed.
        let measurementId = self.logger.startPerformanceMeasurement(
            operation: operation.metricName,
            correlationId: correlationId)
        defer {
            logger.endPerformanceMeasurement(
                measurementId: measurementId,
                metadata: metadata)
        }

        return try await ScreenCaptureKitCaptureGate.withExclusiveCaptureOperation(
            operationName: operation.metricName)
        {
            // Permission probing may call ScreenCaptureKit on CLI builds where
            // CGPreflightScreenCaptureAccess is unreliable; keep that probe in
            // the same cross-process transaction as the capture itself.
            //
            // Do this even for the legacy CGWindowList/CGDisplay path. When
            // Screen Recording is missing, CoreGraphics can still return a
            // redacted desktop/wallpaper image, which looks like a successful
            // capture unless we fail before attempting it.
            if requiresPermission {
                try await self.permissionGate.requirePermission(logger: self.logger, correlationId: correlationId)
            }
            return try await body(correlationId)
        }
    }

    func hasScreenRecordingPermissionImpl() async -> Bool {
        await self.permissionGate.hasPermission(logger: self.logger)
    }

    func findApplication(matching identifier: String) async throws -> ServiceApplicationInfo {
        try await self.applicationResolver.findApplication(identifier: identifier)
    }

    func frontmostApplication() async throws -> ServiceApplicationInfo {
        do {
            return try await self.applicationResolver.frontmostApplication()
        } catch {
            self.logger.error("No frontmost application found")
            throw error
        }
    }
}
