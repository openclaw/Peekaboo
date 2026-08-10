import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Interact with system dialogs and alerts
@MainActor
struct DialogCommand: ParsableCommand {
    enum ExecutionFocus {
        case none
        case whenRequested(Bool, FocusCommandOptions)
        case required(FocusCommandOptions)
    }

    struct ExecutionContext {
        let services: any PeekabooServiceProviding
        let windowTitle: String?
        let appHint: String?
    }

    static let commandDescription = CommandDescription(
        commandName: "dialog",
        abstract: "Interact with system dialogs and alerts",
        discussion: """

        EXAMPLES:
          # Click a button in a dialog
          peekaboo dialog click --button "OK"
          peekaboo dialog click --button "Don't Save"

          # Type in a dialog text field
          peekaboo dialog input --text "password123" --field "Password" --foreground

          # Handle file dialogs
          peekaboo dialog file --path "/Users/me/Documents" --name "report.pdf" --select "Save" --foreground
          peekaboo dialog file --app TextEdit --path /tmp --name poem.rtf --select default --foreground

          # Dismiss dialogs
          peekaboo dialog dismiss
          peekaboo dialog dismiss --force --foreground  # Press Escape
        """,
        subcommands: [
            ClickSubcommand.self,
            InputSubcommand.self,
            FileSubcommand.self,
            DismissSubcommand.self,
            ListSubcommand.self,
        ],
        showHelpOnEmptyInvocation: true
    )

    @MainActor
    static func resolveDialogAppHint(
        target: InteractionTargetOptions,
        services: any PeekabooServiceProviding
    ) async throws -> String? {
        if let app = target.app, !app.isEmpty, !app.hasPrefix("PID:") {
            return app
        }

        guard let pid = target.pid else {
            return nil
        }

        let apps = try await services.applications.listApplications()
        guard let match = apps.data.applications.first(where: { $0.processIdentifier == pid }) else {
            return nil
        }

        return match.bundleIdentifier ?? match.name
    }

    static func execute(
        runtime: CommandRuntime,
        target: InteractionTargetOptions,
        focus: ExecutionFocus,
        resolveWindowTitle: Bool = true,
        beginsInteractionMutation: Bool = true,
        handlesValidationError: Bool = true,
        handlesPeekabooError: Bool = false,
        validate: () throws -> Void = {},
        operation: (ExecutionContext) async throws -> Void
    ) async throws {
        var target = target
        let logger = runtime.logger
        let jsonOutput = runtime.configuration.jsonOutput
        logger.setJsonOutputMode(jsonOutput)

        do {
            try target.validate()
            try validate()

            switch focus {
            case .none:
                break
            case let .whenRequested(foreground, options):
                if foreground {
                    if options.autoFocus {
                        runtime.beginInteractionMutation()
                    }
                    try await ensureFocused(
                        snapshotId: nil,
                        target: target,
                        options: options,
                        services: runtime.services
                    )
                }
            case let .required(options):
                if options.autoFocus {
                    runtime.beginInteractionMutation()
                }
                try await ensureFocused(
                    snapshotId: nil,
                    target: target,
                    options: options,
                    services: runtime.services
                )
            }

            let windowTitle: String? = if resolveWindowTitle {
                try await target.resolveWindowTitleOptional(services: runtime.services)
            } else {
                nil
            }
            let appHint = try await self.resolveDialogAppHint(target: target, services: runtime.services)

            if beginsInteractionMutation {
                runtime.beginInteractionMutation()
            }
            try await operation(
                ExecutionContext(
                    services: runtime.services,
                    windowTitle: windowTitle,
                    appHint: appHint
                )
            )
        } catch let error as Commander.ValidationError {
            if handlesValidationError {
                handleDialogValidationError(error, jsonOutput: jsonOutput, logger: logger)
            } else {
                handleGenericError(error, jsonOutput: jsonOutput, logger: logger)
            }
            throw ExitCode(1)
        } catch let error as DialogError {
            handleDialogServiceError(error, jsonOutput: jsonOutput, logger: logger)
            throw ExitCode(1)
        } catch let error as PeekabooError {
            guard handlesPeekabooError else {
                handleGenericError(error, jsonOutput: jsonOutput, logger: logger)
                throw ExitCode(1)
            }
            let code: ErrorCode = switch error {
            case .timeout:
                .TIMEOUT
            case .invalidInput:
                .INVALID_INPUT
            default:
                .UNKNOWN_ERROR
            }
            if jsonOutput {
                outputError(message: error.localizedDescription, code: code, logger: logger)
            } else {
                fputs("❌ \(error.localizedDescription)\n", stderr)
            }
            throw ExitCode(1)
        } catch {
            handleGenericError(error, jsonOutput: jsonOutput, logger: logger)
            throw ExitCode(1)
        }
    }
}

// MARK: - Subcommand Conformances

@MainActor
extension DialogCommand.InputSubcommand: ParsableCommand {}
extension DialogCommand.InputSubcommand: AsyncRuntimeCommand {}

@MainActor
extension DialogCommand.InputSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.text = try values.requireOption("text", as: String.self)
        self.field = values.singleOption("field")
        self.index = try values.decodeOption("index", as: Int.self)
        self.clear = values.flag("clear")
        self.foreground = values.flag("foreground")
        try values.fillInteractionTargetOptions(into: &self.target)
        self.focusOptions = try values.makeFocusOptions()
    }
}

@MainActor
extension DialogCommand.FileSubcommand: ParsableCommand {}
extension DialogCommand.FileSubcommand: AsyncRuntimeCommand {}

@MainActor
extension DialogCommand.FileSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.path = values.singleOption("path")
        self.name = values.singleOption("name")
        self.select = values.singleOption("select")
        if let timeout: CLIDuration = try values.decodeOption("timeout", as: CLIDuration.self) {
            self.timeout = timeout
        }
        self.ensureExpanded = values.flag("ensureExpanded")
        self.foreground = values.flag("foreground")
        try values.fillInteractionTargetOptions(into: &self.target)
        self.focusOptions = try values.makeFocusOptions()
    }
}

@MainActor
extension DialogCommand.DismissSubcommand: ParsableCommand {}
extension DialogCommand.DismissSubcommand: AsyncRuntimeCommand {}

@MainActor
extension DialogCommand.DismissSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.force = values.flag("force")
        self.foreground = values.flag("foreground")
        try values.fillInteractionTargetOptions(into: &self.target)
        self.focusOptions = try values.makeFocusOptions()
    }
}

@MainActor
extension DialogCommand.ListSubcommand: ParsableCommand {}
extension DialogCommand.ListSubcommand: AsyncRuntimeCommand {}

@MainActor
extension DialogCommand.ListSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        if let timeout: CLIDuration = try values.decodeOption("timeout", as: CLIDuration.self) {
            self.timeout = timeout
        }
        try values.fillInteractionTargetOptions(into: &self.target)
    }
}

@MainActor
extension DialogCommand.ClickSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "click",
                abstract: "Click a button in a dialog using DialogService"
            )
        }
    }
}

extension DialogCommand.ClickSubcommand: AsyncRuntimeCommand {}

@MainActor
extension DialogCommand.ClickSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.button = try values.requireOption("button", as: String.self)
        self.foreground = values.flag("foreground")
        try values.fillInteractionTargetOptions(into: &self.target)
        self.focusOptions = try values.makeFocusOptions()
    }
}

// MARK: - Error Handling

func handleDialogServiceError(_ error: DialogError, jsonOutput: Bool, logger: Logger) {
    let errorCode: ErrorCode = switch error {
    case .noActiveDialog:
        .NO_ACTIVE_DIALOG
    case .dialogNotFound:
        .ELEMENT_NOT_FOUND
    case .noFileDialog:
        .ELEMENT_NOT_FOUND
    case .buttonNotFound:
        .ELEMENT_NOT_FOUND
    case .fieldNotFound:
        .ELEMENT_NOT_FOUND
    case .invalidFieldIndex:
        .INVALID_INPUT
    case .noTextFields:
        .ELEMENT_NOT_FOUND
    case .noDismissButton:
        .ELEMENT_NOT_FOUND
    case .fileVerificationFailed:
        .FILE_IO_ERROR
    case .fileSavedToUnexpectedDirectory:
        .FILE_IO_ERROR
    case .inputSuppressedUnderTests:
        .INVALID_INPUT
    }

    if jsonOutput {
        let details: String? = switch error {
        case let .fileVerificationFailed(expectedPath):
            "expected_path=\(expectedPath)"
        case let .fileSavedToUnexpectedDirectory(expectedDirectory, actualDirectory, actualPath):
            "expected_directory=\(expectedDirectory) actual_directory=\(actualDirectory) actual_path=\(actualPath)"
        default:
            nil
        }
        let response = ResultEnvelope<Empty?>(
            success: false,
            effect: ResultEnvelopeContext.isActionCommand ? defaultActionErrorEffect(errorCode) : nil,
            data: nil,
            error: ErrorInfo(
                message: error.localizedDescription,
                code: errorCode,
                details: details
            )
        )
        outputJSONCodable(response, logger: logger)
    } else {
        fputs("❌ \(error.localizedDescription)\n", stderr)
    }
}

func handleDialogValidationError(_ error: Commander.ValidationError, jsonOutput: Bool, logger: Logger) {
    if jsonOutput {
        outputError(message: error.localizedDescription, code: .INVALID_INPUT, logger: logger)
    } else {
        fputs("Error: \(error.localizedDescription)\n", stderr)
    }
}
