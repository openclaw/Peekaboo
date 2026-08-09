import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Interact with system dialogs and alerts
@MainActor
struct DialogCommand: ParsableCommand {
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
          peekaboo dialog file --app TextEdit --window-title "Untitled" --path "/tmp" --name "poem.rtf" --select default --foreground

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
        if let timeoutSeconds: TimeInterval = try values.decodeOption("timeoutSeconds", as: TimeInterval.self) {
            self.timeoutSeconds = timeoutSeconds
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
        if let timeoutSeconds: TimeInterval = try values.decodeOption("timeoutSeconds", as: TimeInterval.self) {
            self.timeoutSeconds = timeoutSeconds
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
        let response = JSONResponse(
            success: false,
            error: ErrorInfo(
                message: error.localizedDescription,
                code: errorCode,
                details: details
            )
        )
        outputJSON(response, logger: logger)
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
