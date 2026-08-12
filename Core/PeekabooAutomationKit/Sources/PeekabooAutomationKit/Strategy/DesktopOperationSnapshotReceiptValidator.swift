import CoreGraphics
import Foundation
import PeekabooFoundation

/// Builds and revalidates exact snapshot receipts for desktop mutations.
enum DesktopOperationSnapshotReceiptValidator {
    static func captureReceipt(
        snapshotID: String,
        detectionResult: ElementDetectionResult?,
        requireExactWindow: Bool,
        processStartIdentityProvider: @Sendable (pid_t) -> UInt64?,
        exactWindowIdentityValidator: @Sendable (WindowMutationIdentity, CGRect) -> Bool) throws
        -> DesktopOperationPlan.CaptureReceipt
    {
        guard let detectionResult else {
            guard !requireExactWindow else {
                throw PeekabooError.snapshotStale("background mutation requires a fresh exact-window snapshot")
            }
            return try DesktopOperationPlan.CaptureReceipt(snapshotID: snapshotID)
        }
        guard detectionResult.snapshotId == snapshotID else {
            throw PeekabooError.snapshotStale("snapshot identity changed before desktop mutation planning")
        }
        guard let context = detectionResult.metadata.windowContext,
              let identity = context.windowMutationIdentity
        else {
            guard !requireExactWindow else {
                throw PeekabooError.snapshotStale(
                    "background mutation snapshot has no exact process-generation and window receipt")
            }
            return try DesktopOperationPlan.CaptureReceipt(
                snapshotID: snapshotID,
                bundleIdentifier: detectionResult.metadata.windowContext?.applicationBundleId,
                coordinateContext: detectionResult.metadata.captureCoordinateContext)
        }
        guard let bounds = context.windowBounds,
              context.applicationProcessId == identity.ownerProcessIdentifier,
              context.windowID == identity.windowID,
              identity.capturedBounds == bounds,
              processStartIdentityProvider(identity.ownerProcessIdentifier) == identity.ownerProcessStartIdentity,
              exactWindowIdentityValidator(identity, bounds)
        else {
            throw PeekabooError.snapshotStale(
                "target window owner, process generation, or bounds changed before desktop mutation")
        }
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: identity.ownerProcessIdentifier,
            processStartIdentity: identity.ownerProcessStartIdentity)
        return try DesktopOperationPlan.CaptureReceipt(
            snapshotID: snapshotID,
            bundleIdentifier: context.applicationBundleId,
            processIdentifier: processIdentity.processIdentifier,
            processIdentity: processIdentity,
            exactWindow: DesktopOperationPlan.ExactWindowReceipt(identity: identity, bounds: bounds),
            coordinateContext: detectionResult.metadata.captureCoordinateContext)
    }

    static func validate(
        detectionResult: ElementDetectionResult?,
        receipt: DesktopOperationPlan.CaptureReceipt,
        processStartIdentityProvider: @Sendable (pid_t) -> UInt64?,
        exactWindowIdentityValidator: @Sendable (WindowMutationIdentity, CGRect) -> Bool) throws
    {
        guard detectionResult?.snapshotId == receipt.snapshotID else {
            throw PeekabooError.snapshotStale("target snapshot changed before desktop mutation dispatch")
        }
        try self.validate(
            context: detectionResult?.metadata.windowContext,
            receipt: receipt,
            processStartIdentityProvider: processStartIdentityProvider,
            exactWindowIdentityValidator: exactWindowIdentityValidator)
    }

    static func validate(
        context: WindowContext?,
        receipt: DesktopOperationPlan.CaptureReceipt,
        processStartIdentityProvider: @Sendable (pid_t) -> UInt64?,
        exactWindowIdentityValidator: @Sendable (WindowMutationIdentity, CGRect) -> Bool) throws
    {
        guard let expectedProcessIdentity = receipt.processIdentity,
              let exactWindow = receipt.exactWindow
        else {
            return
        }
        let expectedWindowIdentity = exactWindow.identity
        guard let context,
              context.applicationProcessId == expectedProcessIdentity.processIdentifier,
              context.windowID == expectedWindowIdentity.windowID,
              context.windowBounds == exactWindow.bounds,
              let resolvedWindowIdentity = context.windowMutationIdentity,
              self.sameIdentity(resolvedWindowIdentity, expectedWindowIdentity),
              processStartIdentityProvider(expectedProcessIdentity.processIdentifier) ==
              expectedProcessIdentity.processStartIdentity,
              exactWindowIdentityValidator(expectedWindowIdentity, exactWindow.bounds)
        else {
            throw PeekabooError.snapshotStale(
                "target window owner, process generation, or bounds changed before desktop mutation dispatch")
        }
    }

    private static func sameIdentity(_ lhs: WindowMutationIdentity, _ rhs: WindowMutationIdentity) -> Bool {
        lhs.windowID == rhs.windowID &&
            lhs.ownerProcessIdentifier == rhs.ownerProcessIdentifier &&
            lhs.ownerProcessStartIdentity == rhs.ownerProcessStartIdentity &&
            lhs.capturedBounds == rhs.capturedBounds
    }
}
