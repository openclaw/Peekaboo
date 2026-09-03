import CoreGraphics
import Darwin
import Foundation
import PeekabooFoundation

@_spi(Testing) public enum ScreenRecordingPermissionProbePolicy: Sendable, Equatable {
    case allowScreenCaptureKit
    case coreGraphicsOnly
}

@MainActor
@_spi(Testing) public protocol ScreenRecordingPermissionEvaluating: Sendable {
    func hasPermission(
        logger: CategoryLogger,
        policy: ScreenRecordingPermissionProbePolicy) async -> Bool
    func evaluatePermission(
        logger: CategoryLogger,
        policy: ScreenRecordingPermissionProbePolicy) async throws -> Bool
}

extension ScreenRecordingPermissionEvaluating {
    public func evaluatePermission(
        logger: CategoryLogger,
        policy: ScreenRecordingPermissionProbePolicy) async throws -> Bool
    {
        await self.hasPermission(logger: logger, policy: policy)
    }

    func hasPermission(logger: CategoryLogger) async -> Bool {
        await self.hasPermission(logger: logger, policy: .allowScreenCaptureKit)
    }
}

@MainActor
struct ScreenRecordingPermissionChecker: ScreenRecordingPermissionEvaluating {
    private let preflight: @MainActor @Sendable () -> Bool
    private let coreGraphicsEvidence: @MainActor @Sendable () -> Bool
    private let shareableContentProbe: @MainActor @Sendable () async throws -> Void

    init() {
        self.preflight = { CGPreflightScreenCaptureAccess() }
        self.coreGraphicsEvidence = Self.hasProtectedWindowMetadataAccess
        self.shareableContentProbe = {
            _ = try await ScreenCaptureKitCaptureGate.currentShareableContent()
        }
    }

    init(
        preflight: @escaping @MainActor @Sendable () -> Bool,
        coreGraphicsEvidence: @escaping @MainActor @Sendable () -> Bool = { false },
        shareableContentProbe: @escaping @MainActor @Sendable () async throws -> Void)
    {
        self.preflight = preflight
        self.coreGraphicsEvidence = coreGraphicsEvidence
        self.shareableContentProbe = shareableContentProbe
    }

    func hasPermission(
        logger: CategoryLogger,
        policy: ScreenRecordingPermissionProbePolicy = .allowScreenCaptureKit) async -> Bool
    {
        await (try? self.evaluatePermission(logger: logger, policy: policy)) ?? false
    }

    func evaluatePermission(
        logger: CategoryLogger,
        policy: ScreenRecordingPermissionProbePolicy) async throws -> Bool
    {
        let preflightResult = self.preflight()
        if preflightResult {
            return true
        }

        guard policy == .allowScreenCaptureKit else {
            guard self.coreGraphicsEvidence() else {
                logger.warning(
                    "Classic capture has neither a successful preflight nor protected WindowServer metadata; " +
                        "skipping the ScreenCaptureKit probe and refusing before capture")
                return false
            }
            logger.info(
                "Classic capture confirmed Screen Recording through protected WindowServer metadata; " +
                    "skipping the ScreenCaptureKit probe")
            return true
        }

        // CGPreflightScreenCaptureAccess is unreliable for CLI tools. It often returns false even when permission is
        // granted because TCC tracks by code signature and the check can fail after rebuilds or for non-.app bundles.
        logger.debug("CGPreflightScreenCaptureAccess returned false, probing SCShareableContent")
        do {
            try await self.shareableContentProbe()
            logger.info("Screen recording permission granted (SCShareableContent probe)")
            return true
        } catch let diagnostic as ScreenCaptureKitOwnershipDiagnostic {
            throw diagnostic
        } catch {
            if let delay = ScreenCaptureKitTransientError.retryDelayNanoseconds(after: error) {
                logger.warning(
                    "Screen recording permission probe hit transient ScreenCaptureKit denial; retrying once")
                do {
                    try await Task.sleep(nanoseconds: delay)
                    try Task.checkCancellation()
                } catch {
                    return false
                }
                do {
                    try await self.shareableContentProbe()
                    logger.info("Screen recording permission granted (SCShareableContent retry)")
                    return true
                } catch let diagnostic as ScreenCaptureKitOwnershipDiagnostic {
                    throw diagnostic
                } catch {
                    logger.warning("Screen recording permission retry failed: \(error)")
                }
            }
            logger.warning("Screen recording permission not granted (SCShareableContent probe failed: \(error))")
            return false
        }
    }

    private static func hasProtectedWindowMetadataAccess() -> Bool {
        let excludedOwners: Set = [
            "Control Center", "Dock", "Notification Center", "Wallpaper", "Window Server",
        ]
        let rows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] ?? []
        return rows.contains { row in
            guard let ownerPID = row[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != getpid(),
                  let ownerName = row[kCGWindowOwnerName as String] as? String,
                  !excludedOwners.contains(ownerName),
                  let title = row[kCGWindowName as String] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (row[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDictionary = row[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width > 1,
                  bounds.height > 1
            else {
                return false
            }
            return true
        }
    }
}

@MainActor
struct ScreenCapturePermissionGate {
    private let evaluator: any ScreenRecordingPermissionEvaluating

    init(evaluator: any ScreenRecordingPermissionEvaluating) {
        self.evaluator = evaluator
    }

    func hasPermission(
        logger: CategoryLogger,
        policy: ScreenRecordingPermissionProbePolicy = .allowScreenCaptureKit) async -> Bool
    {
        await self.evaluator.hasPermission(logger: logger, policy: policy)
    }

    func requirePermission(
        logger: CategoryLogger,
        correlationId: String,
        policy: ScreenRecordingPermissionProbePolicy = .allowScreenCaptureKit) async throws
    {
        logger.debug("Checking screen recording permission", correlationId: correlationId)
        guard try await self.evaluator.evaluatePermission(logger: logger, policy: policy) else {
            logger.error("Screen recording permission denied", correlationId: correlationId)
            throw PermissionError.screenRecording()
        }
    }
}
