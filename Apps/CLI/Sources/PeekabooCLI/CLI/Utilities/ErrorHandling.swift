import Foundation
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation

// MARK: - Common Error Handling

private func emitError(
    message: String,
    code: ErrorCode,
    jsonOutput: Bool,
    logger: Logger,
    screenCaptureKitOwnershipDiagnostic: ScreenCaptureKitOwnershipDiagnostic? = nil,
    prefix: String = "❌"
) {
    if jsonOutput {
        outputError(
            message: message,
            code: code,
            screenCaptureKitOwnershipDiagnostic: screenCaptureKitOwnershipDiagnostic,
            logger: logger
        )
    } else {
        print("\(prefix) \(message)")
    }
}

// ApplicationError has been replaced by PeekabooError
// Callers should use handleGenericError instead

func handleGenericError(_ error: any Error, jsonOutput: Bool, logger: Logger) {
    let envelopeError = error as? any ResultEnvelopeError
    if let failure = (error as? DesktopActionFailure)
        ?? envelopeError?.envelopeActionFailure {
        renderDesktopActionFailure(
            failure,
            jsonOutput: jsonOutput,
            logger: logger,
            targetIdentity: envelopeError?.envelopeTargetIdentity
        )
        return
    }
    if let envelopeError {
        let metadata = actionErrorEnvelopeMetadata(for: error, isActionCommand: true)
        if jsonOutput {
            outputError(
                message: error.localizedDescription,
                code: envelopeError.envelopeCode ?? .INTERACTION_FAILED,
                hint: envelopeError.envelopeHint,
                effect: metadata.effect,
                retrySafe: metadata.retrySafe,
                mutationDispatched: metadata.mutationDispatched,
                actionOutcome: metadata.outcome,
                targetReceipt: metadata.targetReceipt,
                targetIdentity: metadata.targetIdentity,
                screenCaptureKitOwnershipDiagnostic: screenCaptureKitOwnershipDiagnostic(for: error),
                logger: logger
            )
        } else {
            if let outcome = metadata.outcome {
                let statusLine = ActionOutcomeHumanRenderer.statusLine(for: outcome, operation: "Action")
                fputs("\(statusLine)\n", stderr)
            }
            fputs("Error: \(error.localizedDescription)\n", stderr)
        }
        return
    }
    emitError(
        message: error.localizedDescription,
        code: genericErrorCode(for: error),
        jsonOutput: jsonOutput,
        logger: logger,
        screenCaptureKitOwnershipDiagnostic: screenCaptureKitOwnershipDiagnostic(for: error)
    )
}

func renderDesktopActionFailure(
    _ failure: DesktopActionFailure,
    jsonOutput: Bool,
    logger: Logger,
    operation: String = "Action",
    targetIdentity: DesktopTargetIdentity? = nil
) {
    if jsonOutput {
        outputError(
            message: failure.message,
            code: captureOwnershipErrorCode(for: failure) ?? .INTERACTION_FAILED,
            hint: failure.hint,
            details: failure.causeDescription,
            actionFailure: failure,
            targetIdentity: targetIdentity,
            logger: logger
        )
    } else {
        fputs("\(ActionOutcomeHumanRenderer.statusLine(for: failure.outcome, operation: operation))\n", stderr)
        let hint = failure.hint.map { " Hint: \($0)" } ?? ""
        fputs("Error: \(failure.message)\(hint)\n", stderr)
        if let cause = failure.causeDescription {
            fputs("Cause: \(cause)\n", stderr)
        }
    }
}

func genericErrorCode(for error: any Error) -> ErrorCode {
    if let captureCode = captureOwnershipErrorCode(for: error) {
        return captureCode
    }
    if error is DesktopActionFailure {
        return .INTERACTION_FAILED
    }
    if let envelopeError = error as? any ResultEnvelopeError {
        return envelopeError.envelopeCode ?? .INTERACTION_FAILED
    }
    guard let bridgeError = error as? PeekabooBridgeErrorEnvelope else {
        return .UNKNOWN_ERROR
    }
    return errorCode(for: bridgeError)
}

nonisolated func screenCaptureKitOwnershipDiagnostic(
    for error: any Error
) -> ScreenCaptureKitOwnershipDiagnostic? {
    switch error {
    case let diagnostic as ScreenCaptureKitOwnershipDiagnostic:
        diagnostic
    case let failure as DesktopActionFailure:
        failure.screenCaptureKitOwnershipDiagnostic
    case let envelope as any ResultEnvelopeError:
        envelope.envelopeActionFailure?.screenCaptureKitOwnershipDiagnostic
    case let envelope as PeekabooBridgeErrorEnvelope:
        envelope.screenCaptureKitOwnershipDiagnostic
    default:
        nil
    }
}

nonisolated func captureOwnershipErrorCode(for error: any Error) -> ErrorCode? {
    let failure = (error as? DesktopActionFailure) ??
        (error as? any ResultEnvelopeError)?.envelopeActionFailure
    return screenCaptureKitOwnershipDiagnostic(for: error) != nil || failure?.standardErrorCode == .captureFailed
        ? .CAPTURE_FAILED : nil
}
