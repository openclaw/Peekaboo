import Commander
import Foundation
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation

// MARK: - Error Handling Protocol

/// Protocol for commands that need standardized error handling
@MainActor
protocol ErrorHandlingCommand {
    var jsonOutput: Bool { get }
}

extension ErrorHandlingCommand {
    func preDispatchActionError(
        for error: any Error,
        reason explicitReason: DesktopActionOutcome.RefusalReason? = nil
    ) -> PreDispatchActionError {
        if let error = error as? PreDispatchActionError {
            return error
        }
        let code = self.mapErrorToCode(error)
        let presentation = splitErrorHint(from: errorMessage(for: error))
        return PreDispatchActionError(
            message: presentation.message,
            code: code,
            hint: (error as? any ResultEnvelopeError)?.envelopeHint ?? presentation.hint,
            reason: explicitReason ?? defaultActionRefusalReason(code) ?? .targetUnavailable
        )
    }

    /// Handle errors with appropriate output format
    func handleError(_ error: any Error, customCode: ErrorCode? = nil) {
        if jsonOutput {
            let envelopeError = error as? any ResultEnvelopeError
            let isActionCommand = (self as? any ActionOutputFormattable)?.defaultEffect != nil
            let actionMetadata = actionErrorEnvelopeMetadata(for: error, isActionCommand: isActionCommand)
            let actionFailure = actionMetadata.failure
            let lifecycleRefusal = applicationLifecycleRefusalProjection(for: error)
            let lifecycleFailure = applicationLifecycleFailureProjection(for: error)
            let errorCode = customCode ?? envelopeError?.envelopeCode ?? self.mapErrorToCode(error)
            let failureReceipt = lifecycleFailure.map { failure in
                CaptureFailureReceipt(
                    retrySafe: failure.metadata.retrySafe,
                    mutationDispatched: failure.metadata.mutationDispatched
                )
            } ?? self.captureFailureReceipt(for: error) ?? self.readOnlyObservationFailureReceipt(for: error)
            let logger: Logger = if let formattable = self as? any OutputFormattable {
                formattable.outputLogger
            } else {
                Logger.shared
            }
            let isPreDispatchFailure = ResultEnvelopeContext.isPreDispatchFailure ||
                isGenericPreDispatchError(error)
            ResultEnvelopeContext.$isPreDispatchFailure.withValue(isPreDispatchFailure) {
                outputError(
                    message: errorMessage(for: error),
                    code: errorCode,
                    hint: envelopeError?.envelopeHint ?? actionFailure?.hint ?? lifecycleFailure?.metadata.hint,
                    details: actionFailure?.causeDescription ?? errorDetails(for: error),
                    effect: actionMetadata.effect ?? lifecycleFailure?.effect
                        ?? (lifecycleRefusal != nil ? .refused
                            : failureReceipt?.mutationDispatched == true
                            ? .partial
                            : isActionCommand ? defaultActionErrorEffect(errorCode) : nil),
                    retrySafe: failureReceipt?.retrySafe ?? actionMetadata.retrySafe,
                    mutationDispatched: failureReceipt?.mutationDispatched ?? actionMetadata.mutationDispatched,
                    actionOutcome: actionMetadata.outcome,
                    actionFailure: actionFailure,
                    targetReceipt: actionMetadata.targetReceipt,
                    targetIdentity: actionMetadata.targetIdentity,
                    logger: logger
                )
            }
        } else {
            let actionFailure = (error as? DesktopActionFailure)
                ?? (error as? any ResultEnvelopeError)?.envelopeActionFailure
            if let actionFailure {
                renderDesktopActionFailure(
                    actionFailure,
                    jsonOutput: false,
                    logger: (self as? any OutputFormattable)?.outputLogger ?? Logger.shared
                )
                return
            }
            let errorMessage: String = if let peekabooError = error as? PeekabooError {
                peekabooError.errorDescription ?? String(describing: error)
            } else if let captureError = error as? CaptureError {
                captureError.errorDescription ?? String(describing: error)
            } else if error
                .localizedDescription == "The operation couldn't be completed. (PeekabooCore.PeekabooError error 0.)" ||
                error.localizedDescription == "Error" {
                String(describing: error)
            } else {
                error.localizedDescription
            }
            let hint = (error as? any ResultEnvelopeError)?.envelopeHint
                .map { " Hint: \($0)" } ?? ""
            fputs("Error: \(errorMessage)\(hint)\n", stderr)
        }
    }

    /// Map various error types to error codes
    func mapErrorToCode(_ error: any Error) -> ErrorCode {
        switch error {
        case let cleanupError as CaptureArtifactCleanupError:
            self.mapErrorToCode(cleanupError.primaryError)
        case is CaptureNoValidFramesError:
            .CAPTURE_NO_VALID_FRAMES
        case let focusError as FocusError:
            self.mapFocusErrorToCode(focusError)
        case let peekabooError as PeekabooError:
            self.mapPeekabooErrorToCode(peekabooError)
        case let captureError as CaptureError:
            self.mapCaptureErrorToCode(captureError)
        case let observationError as DesktopObservationError:
            self.mapObservationErrorToCode(observationError)
        case let roiError as CaptureROIError:
            errorCode(for: roiError)
        case let bridgeError as PeekabooBridgeErrorEnvelope:
            errorCode(for: bridgeError)
        case is ApplicationLifecycleRefusalError:
            .INTERACTION_FAILED
        case is DesktopActionFailure:
            .INTERACTION_FAILED
        case let failure as ApplicationLifecycleReadOnlyFailureError:
            self.mapPeekabooErrorToCode(failure.underlyingError)
        case let posixError as POSIXError:
            errorCode(for: posixError)
        case is CaptureCadenceValidationError:
            .VALIDATION_ERROR
        case is Commander.ValidationError:
            .VALIDATION_ERROR
        default:
            .INTERNAL_SWIFT_ERROR
        }
    }

    private func mapObservationErrorToCode(_ error: DesktopObservationError) -> ErrorCode {
        switch error {
        case .targetNotFound, .targetChanged:
            .WINDOW_NOT_FOUND
        case .ambiguousWindowTitle:
            .INVALID_ARGUMENT
        case .unsupportedTarget:
            .VALIDATION_ERROR
        }
    }

    private func mapPeekabooErrorToCode(_ error: PeekabooError) -> ErrorCode {
        if let lookupCode = lookupErrorCode(for: error) {
            return lookupCode
        }
        if let permissionCode = permissionErrorCode(for: error) {
            return permissionCode
        }
        if let timeoutCode = timeoutErrorCode(for: error) {
            return timeoutCode
        }
        if let automationCode = automationErrorCode(for: error) {
            return automationCode
        }
        if let inputCode = inputErrorCode(for: error) {
            return inputCode
        }
        if let credentialCode = credentialErrorCode(for: error) {
            return credentialCode
        }
        return .UNKNOWN_ERROR
    }

    private func lookupErrorCode(for error: PeekabooError) -> ErrorCode? {
        switch error {
        case .appNotFound:
            .APP_NOT_FOUND
        case .ambiguousAppIdentifier:
            .AMBIGUOUS_APP_IDENTIFIER
        case .windowNotFound:
            .WINDOW_NOT_FOUND
        case .elementNotFound:
            .ELEMENT_NOT_FOUND
        case .sessionNotFound:
            .SESSION_NOT_FOUND
        case .snapshotNotFound, .snapshotNotAvailable:
            .SNAPSHOT_NOT_FOUND
        case .snapshotStale:
            .SNAPSHOT_STALE
        case .menuNotFound:
            .MENU_BAR_NOT_FOUND
        case .menuItemNotFound:
            .MENU_ITEM_NOT_FOUND
        default:
            nil
        }
    }

    private func permissionErrorCode(for error: PeekabooError) -> ErrorCode? {
        switch error {
        case .permissionDeniedScreenRecording:
            .PERMISSION_ERROR_SCREEN_RECORDING
        case .permissionDeniedAccessibility:
            .PERMISSION_ERROR_ACCESSIBILITY
        case .permissionDeniedEventSynthesizing:
            .PERMISSION_ERROR_EVENT_SYNTHESIZING
        default:
            nil
        }
    }

    private func timeoutErrorCode(for error: PeekabooError) -> ErrorCode? {
        switch error {
        case .captureTimeout, .timeout:
            .TIMEOUT
        default:
            nil
        }
    }

    private func automationErrorCode(for error: PeekabooError) -> ErrorCode? {
        peekabooAutomationErrorCode(for: error)
    }

    private func inputErrorCode(for error: PeekabooError) -> ErrorCode? {
        switch error {
        case .invalidCoordinates:
            .INVALID_COORDINATES
        case .fileIOError:
            .FILE_IO_ERROR
        case .invalidInput:
            .INVALID_INPUT
        default:
            nil
        }
    }

    private func credentialErrorCode(for error: PeekabooError) -> ErrorCode? {
        switch error {
        case .noAIProviderAvailable, .authenticationFailed:
            .MISSING_API_KEY
        case .aiProviderError:
            .AGENT_ERROR
        default:
            nil
        }
    }

    private func mapCaptureErrorToCode(_ error: CaptureError) -> ErrorCode {
        switch error {
        case .screenRecordingPermissionDenied, .permissionDeniedScreenRecording:
            .PERMISSION_ERROR_SCREEN_RECORDING
        case .accessibilityPermissionDenied:
            .PERMISSION_ERROR_ACCESSIBILITY
        case .appleScriptPermissionDenied:
            .PERMISSION_ERROR_APPLESCRIPT
        case .noDisplaysAvailable, .noDisplaysFound:
            .CAPTURE_FAILED
        case .invalidDisplayID, .invalidDisplayIndex:
            .INVALID_ARGUMENT
        case .captureCreationFailed, .windowCaptureFailed, .captureFailed, .captureFailure:
            .CAPTURE_FAILED
        case .windowNotFound, .noWindowsFound:
            .WINDOW_NOT_FOUND
        case .windowTitleNotFound:
            .WINDOW_NOT_FOUND
        case .fileWriteError, .fileIOError:
            .FILE_IO_ERROR
        case .appNotFound:
            .APP_NOT_FOUND
        case .invalidWindowIndexOld, .invalidWindowIndex:
            .INVALID_ARGUMENT
        case .invalidArgument:
            .INVALID_ARGUMENT
        case .unknownError:
            .UNKNOWN_ERROR
        case .noFrontmostApplication:
            .WINDOW_NOT_FOUND
        case .invalidCaptureArea:
            .INVALID_ARGUMENT
        case .ambiguousAppIdentifier:
            .AMBIGUOUS_APP_IDENTIFIER
        case .imageConversionFailed:
            .CAPTURE_FAILED
        case .detectionTimedOut:
            .TIMEOUT
        }
    }

    private func mapFocusErrorToCode(_ error: FocusError) -> ErrorCode {
        errorCode(for: error)
    }

    var captureMutationDispatched: Bool {
        if let command = self as? CaptureLiveCommand {
            return command.captureMutationDispatched
        }
        if let command = self as? CaptureActionCommand {
            return command.captureMutationDispatched
        }
        return false
    }

    func captureFailureReceipt(for error: any Error) -> CaptureFailureReceipt? {
        guard self is CaptureLiveCommand || self is CaptureVideoCommand || self is CaptureActionCommand else {
            return nil
        }
        let mutationDispatched = self.captureMutationDispatched
        let errorAllowsRetry = (error as? CaptureNoValidFramesError)?.retrySafe ?? true
        return CaptureFailureReceipt(
            retrySafe: errorAllowsRetry && !mutationDispatched,
            mutationDispatched: mutationDispatched
        )
    }

    func readOnlyObservationFailureReceipt(for error: any Error) -> CaptureFailureReceipt? {
        let isIncomplete = if let peekabooError = error as? PeekabooError,
                              case .accessibilityIncomplete = peekabooError {
            true
        } else if let bridgeError = error as? PeekabooBridgeErrorEnvelope {
            bridgeError.standardizedErrorCode == .accessibilityIncomplete
        } else {
            false
        }
        guard isIncomplete else { return nil }
        return CaptureFailureReceipt(retrySafe: true, mutationDispatched: false)
    }
}

func isGenericPreDispatchError(_ error: any Error) -> Bool {
    error is CommanderBindingError || error is CommanderUsageError || error is Commander.ValidationError
}

struct CaptureFailureReceipt: Equatable {
    let retrySafe: Bool
    let mutationDispatched: Bool
}

func peekabooAutomationErrorCode(for error: PeekabooError) -> ErrorCode? {
    switch error {
    case .captureFailed:
        .CAPTURE_FAILED
    case .clickFailed, .typeFailed:
        .INTERACTION_FAILED
    case .accessibilityIncomplete:
        .ACCESSIBILITY_INCOMPLETE
    case .serviceUnavailable, .networkError, .apiError, .commandFailed, .encodingError:
        .UNKNOWN_ERROR
    default:
        nil
    }
}

func errorMessage(for error: any Error) -> String {
    if let bridgeError = error as? PeekabooBridgeErrorEnvelope {
        if bridgeError.permission == .appleScript {
            return CaptureError.appleScriptPermissionDenied.errorDescription ?? bridgeError.message
        }
        return bridgeError.message
    }
    return error.localizedDescription
}

func applicationLaunchErrorCode(for error: any Error) -> ErrorCode? {
    if applicationLifecycleRefusalProjection(for: error) != nil {
        return .INTERACTION_FAILED
    }
    guard let bridgeError = error as? PeekabooBridgeErrorEnvelope,
          bridgeError.code == .notFound
    else {
        return nil
    }
    return .APP_NOT_FOUND
}

struct ApplicationLifecycleRefusalProjection {
    let hint: String
}

struct ApplicationLifecycleFailureProjection {
    let metadata: ApplicationLifecycleFailureMetadata
    let effect: ActionEffect
}

func applicationLifecycleFailureProjection(
    for error: any Error
) -> ApplicationLifecycleFailureProjection? {
    guard let provider = error as? any ApplicationLifecycleFailureMetadataProviding,
          let metadata = provider.applicationLifecycleFailureMetadata
    else {
        return nil
    }
    return ApplicationLifecycleFailureProjection(
        metadata: metadata,
        effect: ActionEffect(rawValue: metadata.effect) ?? .unverifiable
    )
}

func applicationLifecycleRefusalProjection(
    for error: any Error
) -> ApplicationLifecycleRefusalProjection? {
    if let refusal = error as? ApplicationLifecycleRefusalError {
        return ApplicationLifecycleRefusalProjection(hint: refusal.hint)
    }
    guard let bridgeError = error as? PeekabooBridgeErrorEnvelope else { return nil }
    return switch bridgeError.context {
    case ApplicationLifecycleRefusalError.backgroundLaunchContext:
        ApplicationLifecycleRefusalProjection(
            hint: "Retry with --foreground in the CLI or foreground=true in MCP."
        )
    case ApplicationLifecycleRefusalError.unhideContext:
        ApplicationLifecycleRefusalProjection(
            hint: "Retry with --activate in the CLI or foreground=true in MCP."
        )
    default:
        nil
    }
}

func applicationLifecyclePreDispatchError(
    _ error: ApplicationLifecycleRefusalError
) -> PreDispatchActionError {
    PreDispatchActionError(
        message: error.userMessage,
        code: .INTERACTION_FAILED,
        hint: error.hint,
        reason: .foregroundConsentRequired
    )
}

func errorDetails(for error: any Error) -> String? {
    guard let bridgeError = error as? PeekabooBridgeErrorEnvelope else {
        return nil
    }
    var details: [String] = []
    if let bridgeDetails = bridgeError.details, !bridgeDetails.isEmpty {
        details.append(bridgeDetails)
    }
    if let permission = bridgeError.permission {
        details.append("permission: \(permission.rawValue)")
    }
    return details.isEmpty ? nil : details.joined(separator: "\n")
}

func errorCode(for focusError: FocusError) -> ErrorCode {
    switch focusError {
    case .applicationNotRunning:
        .APP_NOT_FOUND
    case .focusVerificationTimeout, .timeoutWaitingForCondition:
        .TIMEOUT
    default:
        .WINDOW_NOT_FOUND
    }
}

func errorCode(for roiError: CaptureROIError) -> ErrorCode {
    switch roiError {
    case .invalidFormat, .invalidBounds, .exactWindowRequired, .outOfBounds, .outputTooLarge:
        .INVALID_ARGUMENT
    case .missingExactWindowReceipt:
        .SNAPSHOT_STALE
    case .invalidSourceImage, .unsupportedScale, .hostDidNotApplyROI:
        .CAPTURE_FAILED
    }
}

func errorCode(for bridgeError: PeekabooBridgeErrorEnvelope) -> ErrorCode {
    if applicationLifecycleRefusalProjection(for: bridgeError) != nil {
        return .INTERACTION_FAILED
    }
    if bridgeError.standardizedErrorCode == .accessibilityIncomplete {
        return .ACCESSIBILITY_INCOMPLETE
    }
    if bridgeError.standardizedErrorCode == .captureFailed {
        return .CAPTURE_FAILED
    }
    if let context = bridgeError.context,
       context.hasPrefix("capture_roi:"),
       let roiError = CaptureROIError(code: String(context.dropFirst("capture_roi:".count))) {
        return errorCode(for: roiError)
    }
    if let kind = bridgeError.kind {
        return errorCode(for: kind)
    }

    return switch bridgeError.code {
    case .permissionDenied:
        switch bridgeError.permission {
        case .screenRecording:
            .PERMISSION_ERROR_SCREEN_RECORDING
        case .accessibility:
            .PERMISSION_ERROR_ACCESSIBILITY
        case .postEvent:
            .PERMISSION_ERROR_EVENT_SYNTHESIZING
        case .appleScript:
            .PERMISSION_ERROR_APPLESCRIPT
        case .none:
            .PERMISSION_DENIED
        }
    case .timeout:
        .TIMEOUT
    case .invalidRequest:
        .INVALID_ARGUMENT
    case .operationNotSupported:
        .VALIDATION_ERROR
    case .notFound:
        .UNKNOWN_ERROR
    case .versionMismatch, .unauthorizedClient, .decodingFailed, .internalError, .serverBusy:
        .UNKNOWN_ERROR
    }
}

private func errorCode(for bridgeErrorKind: PeekabooBridgeErrorKind) -> ErrorCode {
    switch bridgeErrorKind {
    case .appNotFound:
        .APP_NOT_FOUND
    case .windowNotFound:
        .WINDOW_NOT_FOUND
    case .elementNotFound:
        .ELEMENT_NOT_FOUND
    case .menuNotFound:
        .MENU_BAR_NOT_FOUND
    case .menuItemNotFound:
        .MENU_ITEM_NOT_FOUND
    case .dockNotFound:
        .DOCK_NOT_FOUND
    case .dockListNotFound:
        .DOCK_LIST_NOT_FOUND
    case .dockItemNotFound:
        .DOCK_ITEM_NOT_FOUND
    case .positionNotFound:
        .POSITION_NOT_FOUND
    case .snapshotNotFound:
        .SNAPSHOT_NOT_FOUND
    case .snapshotStale:
        .SNAPSHOT_STALE
    }
}

func errorCode(for posixError: POSIXError) -> ErrorCode {
    switch posixError.code {
    case .ETIMEDOUT:
        .TIMEOUT
    default:
        .INTERNAL_SWIFT_ERROR
    }
}
