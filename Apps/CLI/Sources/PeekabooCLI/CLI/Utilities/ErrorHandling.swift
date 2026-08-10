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
    prefix: String = "❌"
) {
    if jsonOutput {
        outputError(message: message, code: code, logger: logger)
    } else {
        print("\(prefix) \(message)")
    }
}

// ApplicationError has been replaced by PeekabooError
// Callers should use handleGenericError instead

func handleGenericError(_ error: any Error, jsonOutput: Bool, logger: Logger) {
    emitError(
        message: error.localizedDescription,
        code: genericErrorCode(for: error),
        jsonOutput: jsonOutput,
        logger: logger
    )
}

func genericErrorCode(for error: any Error) -> ErrorCode {
    guard let bridgeError = error as? PeekabooBridgeErrorEnvelope else {
        return .UNKNOWN_ERROR
    }
    return errorCode(for: bridgeError)
}
