import Commander
import CoreGraphics
import Darwin
import Foundation
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
    #if DEBUG
    checkBuildStaleness()
    #endif

    // Initialize CoreGraphics silently to prevent CGS_REQUIRE_INIT error
    _ = CGMainDisplayID()

    // Load configuration at startup. The singleton initializer already performs
    // the initial load, so avoid a second credentials/config read on every CLI invocation.
    _ = ConfigurationManager.shared.getConfiguration()

    let shouldEmitJSONErrors = containsJSONOutputFlag(arguments)

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

private func containsJSONOutputFlag(_ arguments: [String]) -> Bool {
    arguments.contains("--json") || arguments.contains("-j") || arguments.contains("--json-output") ||
        arguments.contains("--jsonOutput")
}

private func commanderErrorMessage(_ error: CommanderProgramError) -> String {
    switch error {
    case let .parsingError(parsing):
        parsing.description
    case let .unknownCommand(name):
        "Unknown command '\(name)'"
    case let .unknownSubcommand(command, name):
        "Unknown subcommand '\(name)' for command '\(command)'"
    case .missingCommand:
        "No command specified"
    case let .missingSubcommand(command):
        "Command '\(command)' requires a subcommand"
    }
}

private func printCommanderError(_ error: CommanderProgramError, jsonOutput: Bool) {
    let message = commanderErrorMessage(error)
    guard jsonOutput else {
        fputs("Error: \(message)\n", stderr)
        return
    }

    let logger = Logger.shared
    logger.setJsonOutputMode(true)
    outputError(message: message, code: .INVALID_ARGUMENT, logger: logger)
}

private func printGenericError(_ error: any Error, jsonOutput: Bool) {
    let code: ErrorCode = if error is CommanderBindingError {
        .INVALID_ARGUMENT
    } else {
        .UNKNOWN_ERROR
    }

    guard jsonOutput else {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        return
    }

    let logger = Logger.shared
    logger.setJsonOutputMode(true)
    outputError(message: error.localizedDescription, code: code, logger: logger)
}
