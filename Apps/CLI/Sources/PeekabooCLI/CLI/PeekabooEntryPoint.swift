import Commander
import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooCore

/// Shared entry point used by the executable target.
@MainActor
public func runPeekabooCLI() async {
    let status = await executePeekabooCLI(arguments: CommandLine.arguments)
    Darwin.exit(status)
}

/// Internal helper that runs the CLI and returns an exit code (used by tests).
@MainActor
func executePeekabooCLI(arguments: [String]) async -> Int32 {
    // Publish owner-lease awareness before any long-lived CLI mode can reach ScreenCaptureKit.
    // Capture still fails closed later if registration itself was not possible.
    try? ScreenCaptureKitOwnerLease.registerCurrentProcessCapability()

    #if DEBUG
    checkBuildStaleness()
    #endif

    // Initialize CoreGraphics silently to prevent CGS_REQUIRE_INIT error
    _ = CGMainDisplayID()

    // Load configuration at startup. The singleton initializer already performs
    // the initial load, so avoid a second credentials/config read on every CLI invocation.
    _ = ConfigurationManager.shared.getConfiguration()

    let shouldEmitJSONErrors = containsJSONOutputFlag(arguments)
    let isActionCommand = shouldEmitJSONErrors && CommanderRuntimeRouter.isActionInvocation(argv: arguments)

    return await ResultEnvelopeContext.$isActionCommand.withValue(isActionCommand) {
        do {
            try await CommanderRuntimeExecutor.resolveAndRun(arguments: arguments)
            return EXIT_SUCCESS
        } catch let exit as ExitCode {
            return exit.rawValue
        } catch let programError as CommanderProgramError {
            printCommanderError(programError, jsonOutput: shouldEmitJSONErrors)
            return EXIT_FAILURE
        } catch {
            printGenericError(error, jsonOutput: shouldEmitJSONErrors)
            return EXIT_FAILURE
        }
    }
}

private func containsJSONOutputFlag(_ arguments: [String]) -> Bool {
    let rootArguments = arguments.prefix { $0 != "--" }
    return rootArguments.contains("--json") || rootArguments.contains("-j") ||
        rootArguments.contains("--json-output") || rootArguments.contains("--jsonOutput")
}

func commanderErrorMessage(_ error: CommanderProgramError) -> String {
    error.description
}

func commanderErrorHint(_ error: CommanderProgramError) -> String? {
    switch error {
    case .missingCommand, .unknownCommand:
        "Run 'peekaboo --help' to list current commands."
    case let .missingSubcommand(command), let .unknownSubcommand(command, _):
        "Run 'peekaboo help \(command)' to list current subcommands."
    default:
        nil
    }
}

private func printCommanderError(_ error: CommanderProgramError, jsonOutput: Bool) {
    let message = commanderErrorMessage(error)
    let hint = commanderErrorHint(error)
    guard jsonOutput else {
        fputs("Error: \(message)\n", stderr)
        if let hint {
            fputs("Hint: \(hint)\n", stderr)
        }
        return
    }

    let logger = Logger.shared
    logger.setJsonOutputMode(true)
    ResultEnvelopeContext.$isPreDispatchFailure.withValue(true) {
        outputError(message: message, code: .INVALID_ARGUMENT, hint: hint, logger: logger)
    }
}

func printGenericError(_ error: any Error, jsonOutput: Bool) {
    let envelopeError = error as? any ResultEnvelopeError
    let fallbackCode: ErrorCode = if error is CommanderBindingError || error is CommanderUsageError {
        .INVALID_ARGUMENT
    } else if error is Commander.ValidationError {
        .VALIDATION_ERROR
    } else {
        .UNKNOWN_ERROR
    }
    let code = captureOwnershipErrorCode(for: error) ?? envelopeError?.envelopeCode ?? fallbackCode
    let actionMetadata = actionErrorEnvelopeMetadata(
        for: error,
        isActionCommand: ResultEnvelopeContext.isActionCommand
    )
    let actionFailure = actionMetadata.failure

    guard jsonOutput else {
        let hint = envelopeError?.envelopeHint.map { " Hint: \($0)" } ?? ""
        fputs("Error: \(error.localizedDescription)\(hint)\n", stderr)
        return
    }

    let logger = Logger.shared
    logger.setJsonOutputMode(true)
    let isGenericPreDispatchFailure = isGenericPreDispatchError(error)
    ResultEnvelopeContext.$isPreDispatchFailure.withValue(isGenericPreDispatchFailure) {
        outputError(
            message: error.localizedDescription,
            code: code,
            hint: envelopeError?.envelopeHint,
            effect: actionMetadata.effect,
            retrySafe: actionMetadata.retrySafe,
            mutationDispatched: actionMetadata.mutationDispatched,
            actionOutcome: actionMetadata.outcome,
            actionFailure: actionFailure,
            targetReceipt: actionMetadata.targetReceipt,
            targetIdentity: actionMetadata.targetIdentity,
            screenCaptureKitOwnershipDiagnostic: screenCaptureKitOwnershipDiagnostic(for: error),
            logger: logger
        )
    }
}
