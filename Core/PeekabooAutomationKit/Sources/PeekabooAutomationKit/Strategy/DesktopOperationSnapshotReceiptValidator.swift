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
        let captureReceipt: DesktopOperationPlan.CaptureReceipt
        do {
            let receiptPlan = if requireExactWindow ||
                detectionResult.metadata.windowContext?.windowMutationIdentity != nil
            {
                try SnapshotTargetReceiptPlanner.assemble(
                    snapshotID: snapshotID,
                    detectionResult: detectionResult)
            } else {
                try SnapshotTargetReceiptPlanner.assembleProcessIdentity(
                    snapshotID: snapshotID,
                    detectionResult: detectionResult)
            }
            captureReceipt = try DesktopOperationPlan.CaptureReceipt(snapshotReceipt: receiptPlan.receipt)
        } catch let error as DesktopTargetIdentityError {
            throw SnapshotTargetReceiptPreDispatchError(error)
        }
        if requireExactWindow, captureReceipt.exactWindow == nil {
            throw SnapshotTargetReceiptPreDispatchError(.incompleteExactWindow)
        }
        guard let processIdentity = captureReceipt.processIdentity,
              processStartIdentityProvider(processIdentity.processIdentifier) ==
              processIdentity.processStartIdentity
        else {
            throw PeekabooError.snapshotStale(
                "target process generation changed before desktop mutation")
        }
        if let exactWindow = captureReceipt.exactWindow,
           !exactWindowIdentityValidator(exactWindow.identity, exactWindow.bounds)
        {
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
        guard let expectedProcessIdentity = receipt.processIdentity else {
            return
        }
        guard let context,
              DesktopTargetEvidenceAdapter.evidence(context: context).processIdentity == expectedProcessIdentity
        else {
            throw PeekabooError.snapshotStale("target process generation changed before desktop mutation dispatch")
        }
        if let exactWindow = receipt.exactWindow {
            let expectedWindowIdentity = exactWindow.identity
            guard context.windowID == expectedWindowIdentity.windowID,
                  context.windowBounds == exactWindow.bounds,
                  let resolvedWindowIdentity = context.windowMutationIdentity,
                  resolvedWindowIdentity.hasSameStableReceipt(as: expectedWindowIdentity)
            else {
                throw PeekabooError.snapshotStale(
                    "target window owner, process generation, or bounds changed before desktop mutation dispatch")
            }
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
