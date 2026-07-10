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
    /// Handle errors with appropriate output format
    func handleError(_ error: any Error, customCode: ErrorCode? = nil) {
        if jsonOutput {
            let errorCode = customCode ?? self.mapErrorToCode(error)
            let logger: Logger = if let formattable = self as? any OutputFormattable {
                formattable.outputLogger
            } else {
                Logger.shared
            }
            outputError(
                message: errorMessage(for: error),
                code: errorCode,
                details: errorDetails(for: error),
                logger: logger
            )
        } else {
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
            fputs("Error: \(errorMessage)\n", stderr)
        }
    }

    /// Map various error types to error codes
    private func mapErrorToCode(_ error: any Error) -> ErrorCode {
        switch error {
        case let focusError as FocusError:
            self.mapFocusErrorToCode(focusError)
        case let peekabooError as PeekabooError:
            self.mapPeekabooErrorToCode(peekabooError)
        case let captureError as CaptureError:
            self.mapCaptureErrorToCode(captureError)
        case let observationError as DesktopObservationError:
            self.mapObservationErrorToCode(observationError)
        case let bridgeError as PeekabooBridgeErrorEnvelope:
            errorCode(for: bridgeError)
        case let posixError as POSIXError:
            errorCode(for: posixError)
        case is Commander.ValidationError:
            .VALIDATION_ERROR
        default:
            .INTERNAL_SWIFT_ERROR
        }
    }

    private func mapObservationErrorToCode(_ error: DesktopObservationError) -> ErrorCode {
        switch error {
        case .targetNotFound:
            .WINDOW_NOT_FOUND
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
        switch error {
        case .captureFailed, .clickFailed, .typeFailed:
            .CAPTURE_FAILED
        case .serviceUnavailable, .networkError, .apiError, .commandFailed, .encodingError:
            .UNKNOWN_ERROR
        default:
            nil
        }
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
}

func errorMessage(for error: any Error) -> String {
    if let bridgeError = error as? PeekabooBridgeErrorEnvelope {
        return bridgeError.message
    }
    return error.localizedDescription
}

func applicationLaunchErrorCode(for error: any Error) -> ErrorCode? {
    guard let bridgeError = error as? PeekabooBridgeErrorEnvelope,
          bridgeError.code == .notFound
    else {
        return nil
    }
    return .APP_NOT_FOUND
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

func errorCode(for bridgeError: PeekabooBridgeErrorEnvelope) -> ErrorCode {
    switch bridgeError.code {
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

func errorCode(for posixError: POSIXError) -> ErrorCode {
    switch posixError.code {
    case .ETIMEDOUT:
        .TIMEOUT
    default:
        .INTERNAL_SWIFT_ERROR
    }
}
