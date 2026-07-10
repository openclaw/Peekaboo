import Foundation
import PeekabooCore
import PeekabooFoundation

// MARK: - Common Error Handling

private func emitError(
    message: String,
    code: ErrorCode,
    jsonOutput: Bool,
    logger: Logger,
    prefix: String = "❌"
) {
    if jsonOutput {
        let response = JSONResponse(
            success: false,
            error: ErrorInfo(
                message: message,
                code: code
            )
        )
        outputJSON(response, logger: logger)
    } else {
        print("\(prefix) \(message)")
    }
}

// ApplicationError has been replaced by PeekabooError
// Callers should use handleGenericError instead

func handleGenericError(_ error: any Error, jsonOutput: Bool, logger: Logger) {
    // Surface the original error so the runtime executor can classify the failure's dispatch phase
    // before the command rethrows an opaque ExitCode.
    CommandFailureErrorRecorder.record(error)
    emitError(
        message: error.localizedDescription,
        code: .UNKNOWN_ERROR,
        jsonOutput: jsonOutput,
        logger: logger
    )
}

func handleValidationError(_ error: any Error, jsonOutput: Bool, logger: Logger) {
    CommandFailureErrorRecorder.record(error)
    emitError(
        message: error.localizedDescription,
        code: .VALIDATION_ERROR,
        jsonOutput: jsonOutput,
        logger: logger
    )
}
