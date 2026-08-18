import CoreGraphics
import Foundation
import PeekabooFoundation

/// Builds and revalidates exact snapshot receipts for desktop mutations.
enum DesktopOperationSnapshotReceiptValidator {
    enum CurrentIdentityMismatch {
        case processGeneration
        case exactWindow
    }

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
            throw PeekabooError.snapshotStale(
                "background mutation requires a fresh process-targeted snapshot")
        }
        guard detectionResult.snapshotId == snapshotID else {
            throw PeekabooError.snapshotStale("snapshot identity changed before desktop mutation planning")
        }
        guard detectionResult.metadata.windowContext?.windowMutationIdentity != nil
        else {
            guard !requireExactWindow else {
                throw PeekabooError.snapshotStale(
                    "background mutation snapshot has no exact process-generation and window receipt")
            }
            guard let context = detectionResult.metadata.windowContext,
                  let processIdentifier = context.applicationProcessId
            else {
                throw PeekabooError.snapshotStale(
                    "background mutation snapshot has no process target")
            }
            return try DesktopOperationPlan.CaptureReceipt(
                snapshotID: snapshotID,
                bundleIdentifier: context.applicationBundleId,
                target: .process(UIAutomationTarget.Process(processIdentifier: processIdentifier)),
                coordinateContext: detectionResult.metadata.captureCoordinateContext)
        }
        let captureReceipt: DesktopOperationPlan.CaptureReceipt
        do {
            captureReceipt = try DesktopOperationPlan.CaptureReceipt(snapshotReceipt: SnapshotTargetReceiptPlanner
                .assemble(
                    snapshotID: snapshotID,
                    detectionResult: detectionResult).receipt)
        } catch let error as DesktopTargetIdentityError {
            throw SnapshotTargetReceiptPreDispatchError(error)
        }
        guard let exactWindow = captureReceipt.exactWindow,
              processStartIdentityProvider(exactWindow.identity.ownerProcessIdentifier) ==
              exactWindow.identity.ownerProcessStartIdentity,
              exactWindowIdentityValidator(exactWindow.identity, exactWindow.bounds)
        else {
            throw PeekabooError.snapshotStale(
                "target window owner, process generation, or bounds changed before desktop mutation")
        }
        return captureReceipt
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
        validateCurrentIdentity: Bool = true,
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
              resolvedWindowIdentity.hasSameStableReceipt(as: expectedWindowIdentity)
        else {
            throw PeekabooError.snapshotStale(
                "target window owner, process generation, or bounds changed before desktop mutation dispatch")
        }
        if validateCurrentIdentity,
           self.currentIdentityMismatch(
               receipt: receipt,
               processStartIdentityProvider: processStartIdentityProvider,
               exactWindowIdentityValidator: exactWindowIdentityValidator) != nil
        {
            throw PeekabooError.snapshotStale(
                "target window owner, process generation, or bounds changed before desktop mutation dispatch")
        }
    }

    static func currentIdentityMismatch(
        receipt: DesktopOperationPlan.CaptureReceipt,
        validateProcessIdentity: Bool = true,
        validateExactWindow: Bool = true,
        processStartIdentityProvider: @Sendable (pid_t) -> UInt64?,
        exactWindowIdentityValidator: @Sendable (WindowMutationIdentity, CGRect) -> Bool)
        -> CurrentIdentityMismatch?
    {
        if validateProcessIdentity,
           let processIdentity = receipt.processIdentity,
           processStartIdentityProvider(processIdentity.processIdentifier) != processIdentity.processStartIdentity
        {
            return .processGeneration
        }
        if validateExactWindow,
           let exactWindow = receipt.exactWindow,
           !exactWindowIdentityValidator(exactWindow.identity, exactWindow.bounds)
        {
            return .exactWindow
        }
        return nil
    }
}
