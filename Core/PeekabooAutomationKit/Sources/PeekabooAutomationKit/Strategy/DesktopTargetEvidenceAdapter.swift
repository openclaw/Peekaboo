import CoreGraphics
import Foundation
import PeekabooFoundation

/// Canonical conversion from automation models into transport-neutral desktop target evidence.
public enum DesktopTargetEvidenceAdapter {
    public static func evidence(application: ServiceApplicationInfo) -> DesktopTargetIdentity.Evidence {
        self.processEvidence(
            processIdentifier: application.processIdentifier,
            processStartIdentity: application.processStartIdentity)
    }

    public static func evidence(application: ApplicationIdentity) -> DesktopTargetIdentity.Evidence {
        self.processEvidence(
            processIdentifier: application.processIdentifier,
            processStartIdentity: application.processStartIdentity)
    }

    public static func evidence(window: ServiceWindowInfo) -> DesktopTargetIdentity.Evidence {
        .init(
            processIdentifier: window.mutationIdentity?.ownerProcessIdentifier,
            processIdentity: window.mutationIdentity?.processIdentity,
            windowID: window.windowID,
            windowIdentity: window.mutationIdentity,
            windowBounds: window.bounds)
    }

    public static func evidence(window: WindowIdentity) -> DesktopTargetIdentity.Evidence {
        .init(windowID: window.windowID, windowBounds: window.bounds)
    }

    public static func evidence(
        windowIdentity: WindowMutationIdentity,
        bounds: CGRect? = nil,
        focusedElement: FocusedElementIdentity? = nil) -> DesktopTargetIdentity.Evidence
    {
        .init(
            processIdentifier: windowIdentity.ownerProcessIdentifier,
            processIdentity: windowIdentity.processIdentity,
            windowID: windowIdentity.windowID,
            windowIdentity: windowIdentity,
            windowBounds: bounds ?? windowIdentity.capturedBounds,
            focusedElement: focusedElement)
    }

    public static func evidence(context: WindowContext) -> DesktopTargetIdentity.Evidence {
        .init(
            processIdentifier: context.applicationProcessId,
            processIdentity: context.windowMutationIdentity?.processIdentity,
            windowID: context.windowID,
            windowIdentity: context.windowMutationIdentity,
            windowBounds: context.windowBounds,
            focusedElement: context.focusedElement)
    }

    public static func evidence(snapshot: UIAutomationSnapshot) -> DesktopTargetIdentity.Evidence {
        .init(
            processIdentifier: snapshot.applicationProcessId,
            processIdentity: snapshot.windowMutationIdentity?.processIdentity,
            windowID: snapshot.windowID.map(Int.init),
            windowIdentity: snapshot.windowMutationIdentity,
            windowBounds: snapshot.windowBounds,
            focusedElement: snapshot.focusedElement)
    }

    public static func evidence(receipt: DesktopActionTargetReceipt) -> DesktopTargetIdentity.Evidence {
        .init(
            processIdentifier: receipt.processIdentifier,
            processIdentity: .init(
                processIdentifier: receipt.processIdentifier,
                processStartIdentity: receipt.processStartIdentity),
            windowID: receipt.windowID)
    }

    public static func evidence(
        processIdentifier: Int32?,
        processStartIdentity: UInt64?,
        windowID: Int?,
        windowIdentity: WindowMutationIdentity?,
        windowBounds: CGRect?,
        focusedElement: FocusedElementIdentity?) -> DesktopTargetIdentity.Evidence
    {
        .init(
            processIdentifier: processIdentifier,
            processIdentity: self.processIdentity(
                processIdentifier: processIdentifier,
                processStartIdentity: processStartIdentity),
            windowID: windowID,
            windowIdentity: windowIdentity,
            windowBounds: windowBounds,
            focusedElement: focusedElement)
    }

    public static func evidence(
        processIdentity: ApplicationProcessIdentity,
        windowIdentity: WindowMutationIdentity? = nil,
        windowBounds: CGRect? = nil,
        focusedElement: FocusedElementIdentity? = nil) -> DesktopTargetIdentity.Evidence
    {
        .init(
            processIdentifier: processIdentity.processIdentifier,
            processIdentity: processIdentity,
            windowID: windowIdentity?.windowID,
            windowIdentity: windowIdentity,
            windowBounds: windowBounds,
            focusedElement: focusedElement)
    }

    public static func fragments(captureMetadata: CaptureMetadata) -> [DesktopTargetIdentity.Evidence] {
        [
            captureMetadata.applicationInfo.map { self.evidence(application: $0) },
            captureMetadata.windowInfo.map { self.evidence(window: $0) },
        ].compactMap(\.self)
    }

    public static func fragments(dialogResult: DialogActionResult) -> [DesktopTargetIdentity.Evidence] {
        var evidence: [DesktopTargetIdentity.Evidence] = []
        if let resolvedTarget = dialogResult.resolvedTarget {
            evidence.append(.init(target: DesktopTargetIdentity(exactWindow: resolvedTarget.target)))
        }
        if dialogResult.targetWindowIdentity != nil ||
            dialogResult.targetWindowBounds != nil ||
            dialogResult.focusedElement != nil
        {
            evidence.append(.init(
                processIdentifier: dialogResult.targetWindowIdentity?.ownerProcessIdentifier,
                processIdentity: dialogResult.targetWindowIdentity?.processIdentity,
                windowID: dialogResult.targetWindowIdentity?.windowID,
                windowIdentity: dialogResult.targetWindowIdentity,
                windowBounds: dialogResult.targetWindowBounds,
                focusedElement: dialogResult.focusedElement))
        }
        if let receipt = dialogResult.targetReceipt {
            evidence.append(self.evidence(receipt: receipt))
        }
        return evidence
    }

    private static func processEvidence(
        processIdentifier: Int32,
        processStartIdentity: UInt64?) -> DesktopTargetIdentity.Evidence
    {
        .init(
            processIdentifier: processIdentifier,
            processIdentity: self.processIdentity(
                processIdentifier: processIdentifier,
                processStartIdentity: processStartIdentity))
    }

    private static func processIdentity(
        processIdentifier: Int32?,
        processStartIdentity: UInt64?) -> ApplicationProcessIdentity?
    {
        guard let processIdentifier, let processStartIdentity else { return nil }
        return ApplicationProcessIdentity(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity)
    }
}
