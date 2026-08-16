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
        let target: DialogTargetSelector
        let actionSequence: CommandActionSequenceAccumulator
    }

    static func targetReceipt(_ target: UIAutomationTarget.ExactWindow) -> DesktopActionTargetReceipt {
        DesktopActionTargetReceipt(
            processIdentifier: target.identity.ownerProcessIdentifier,
            processStartIdentity: target.identity.ownerProcessStartIdentity,
            windowID: target.identity.windowID
        )
    }

    static func exactResultTargetIdentity(
        from result: DialogActionResult,
        matching selector: DialogTargetSelector? = nil,
        expectedTarget: UIAutomationTarget.ExactWindow? = nil
    ) throws -> DesktopTargetIdentity? {
        let receipt = result.targetReceipt
        let hasEvidence = receipt != nil || result.targetWindowIdentity != nil ||
            result.targetWindowBounds != nil || result.resolvedTarget != nil
        guard hasEvidence else { return nil }

        let processIdentity = receipt.map {
            ApplicationProcessIdentity(
                processIdentifier: $0.processIdentifier,
                processStartIdentity: $0.processStartIdentity
            )
        }
        var evidence = [DesktopTargetIdentity.Evidence(
            processIdentifier: receipt?.processIdentifier,
            processIdentity: processIdentity,
            windowID: receipt?.windowID,
            windowIdentity: result.targetWindowIdentity,
            windowBounds: result.targetWindowBounds,
            focusedElement: result.focusedElement
        )]
        if let resolvedTarget = result.resolvedTarget {
            evidence.append(.init(target: DesktopTargetIdentity(exactWindow: resolvedTarget.target)))
        }
        if let expectedTarget {
            evidence.append(.init(target: DesktopTargetIdentity(exactWindow: expectedTarget)))
        }
        guard let target = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve(evidence),
              target.exactWindow != nil
        else {
            throw DesktopTargetIdentityError.incompleteExactWindow
        }
        if let selector, selector.hasTarget {
            try self.validateResultTarget(
                target,
                result: result,
                matches: selector
            )
        }
        return target
    }

    private static func validateResultTarget(
        _ target: DesktopTargetIdentity,
        result: DialogActionResult,
        matches selector: DialogTargetSelector
    ) throws {
        if let resolvedTarget = result.resolvedTarget {
            guard resolvedTarget.matches(selector) else {
                throw PeekabooError.serviceUnavailable(
                    "Dialog action returned exact target evidence that does not match the requested selector"
                )
            }
            return
        }

        guard let exactWindow = target.exactWindow,
              result.targetReceipt != nil || result.targetWindowIdentity != nil,
              selector.windowTitle == nil,
              selector.windowIndex == nil,
              selector.processIdentifier.map({ $0 == exactWindow.identity.ownerProcessIdentifier }) ?? true,
              selector.windowID.map({ $0 == exactWindow.identity.windowID }) ?? true,
              selector.applicationIdentifier.map({ identifier in
                  ApplicationIdentifierMatcher.matches(
                      .init(
                          processIdentifier: exactWindow.identity.ownerProcessIdentifier,
                          bundleIdentifier: nil,
                          name: "",
                          allowsFuzzyMatching: false
                      ),
                      identifier: identifier
                  )
              }) ?? true
        else {
            throw PeekabooError.serviceUnavailable(
                "Dialog action returned exact target evidence that does not match the requested selector"
            )
        }
    }

    static func exactListTargetIdentity(
        from elements: DialogElements,
        matching selector: DialogTargetSelector
    ) throws -> DesktopTargetIdentity? {
        guard selector.hasTarget else {
            guard elements.resolvedTarget == nil else {
                throw DesktopTargetIdentityError.contradictoryWindowIdentifier
            }
            return nil
        }
        guard let resolved = elements.resolvedTarget,
              resolved.matches(selector)
        else {
            throw DesktopTargetIdentityError.incompleteExactWindow
        }
        return DesktopTargetIdentity(exactWindow: resolved.target)
    }

    static let commandDescription = CommandDescription(
        commandName: "dialog",
        abstract: "Interact with system dialogs and alerts",
        discussion: """

        EXAMPLES:
          # Click a button in a dialog
          peekaboo dialog click --button "OK" --app TextEdit
          peekaboo dialog click --button "Don't Save" --window-id 12345

          # Type in a dialog text field
          peekaboo dialog input --text "hello" --field "Name" --app TextEdit

          # Handle file dialogs
          peekaboo dialog file --app TextEdit --path "/Users/me/Documents" \
            --name "report.pdf" --select "Save" --foreground
          peekaboo dialog file --app TextEdit --path /tmp --name poem.rtf --select default --foreground

          # Dismiss dialogs
          peekaboo dialog dismiss --app TextEdit
          peekaboo dialog dismiss --force --foreground  # Explicit global Escape
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
        services: any PeekabooServiceProviding,
        refusalRoute: DesktopActionOutcome.Route = .local
    ) async throws -> String? {
        let explicitProcessIdentifier = try target.resolveExplicitPIDObservationTarget()
        if explicitProcessIdentifier == nil, let app = target.app, !app.isEmpty {
            return app
        }

        guard let pid = explicitProcessIdentifier else {
            return nil
        }
        if services.dialogs.supportsExactProcessIdentifierAppHint {
            return "PID:\(pid)"
        }

        let apps = try await services.applications.listApplications()
        guard let match = apps.data.applications.first(where: { $0.processIdentifier == pid }) else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: refusalRoute,
                reason: .targetUnavailable,
                message: "Dialog target PID \(pid) is no longer present in the selected provider inventory.",
                hint: "List applications again and retry with a fresh PID or app identifier."
            )
        }
        let bundleIdentifier = match.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }
        let name = match.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: refusalRoute,
                reason: .targetUnavailable,
                message: "Dialog target PID \(pid) has no usable application identity in the selected provider.",
                hint: "List applications again and retry with a fresh PID or nonempty app identifier."
            )
        }
        return name
    }

    @MainActor
    static func resolveDialogAppHintIfRequested(
        _ requested: Bool,
        target: InteractionTargetOptions,
        services: any PeekabooServiceProviding,
        refusalRoute: DesktopActionOutcome.Route
    ) async throws -> String? {
        guard requested else { return nil }
        return try await self.resolveDialogAppHint(
            target: target,
            services: services,
            refusalRoute: refusalRoute
        )
    }

    static func execute(
        runtime: CommandRuntime,
        target: InteractionTargetOptions,
        focus: ExecutionFocus,
        resolveWindowTitle: Bool = true,
        resolveAppHint: Bool = true,
        beginsInteractionMutation: Bool = true,
        handlesValidationError: Bool = true,
        handlesPeekabooError: Bool = false,
        validate: () throws -> Void = {},
        prepareBeforeFocus: ((ExecutionContext) async throws -> Void)? = nil,
        operation: (ExecutionContext) async throws -> Void
    ) async throws {
        let target = target
        let logger = runtime.logger
        let jsonOutput = runtime.configuration.jsonOutput
        logger.setJsonOutputMode(jsonOutput)
        let actionSequence = CommandActionSequenceAccumulator()
        let actionRoute = commandActionRoute(for: runtime.services)

        do {
            do {
                try target.validate()
                try validate()
                let dialogTarget = try target.dialogTargetSelector()
                try await prepareBeforeFocus?(ExecutionContext(
                    services: runtime.services,
                    windowTitle: nil,
                    appHint: nil,
                    target: dialogTarget,
                    actionSequence: actionSequence
                ))

                switch focus {
                case .none:
                    break
                case let .whenRequested(foreground, options):
                    if foreground {
                        if options.autoFocus {
                            runtime.beginInteractionMutation()
                        }
                        let focusResult = try await ensureFocused(
                            snapshotId: nil,
                            target: target,
                            options: options,
                            services: runtime.services
                        )
                        try actionSequence.record(
                            focusResult,
                            operation: "Dialog setup focus",
                            receiptlessStep: options.autoFocus && target.hasAnyTarget
                                ? .dispatched(
                                    route: actionRoute,
                                    delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                                    unitCount: .one
                                )
                                : nil
                        )
                    }
                case let .required(options):
                    if options.autoFocus, target.hasAnyTarget {
                        runtime.beginInteractionMutation()
                    }
                    if let focusResult = try await ensureConfirmedForegroundFocus(
                        snapshotId: nil,
                        target: target,
                        options: options,
                        services: runtime.services,
                        operation: "Dialog setup focus"
                    ) {
                        try actionSequence.record(
                            focusResult,
                            operation: "Dialog setup focus"
                        )
                    }
                }

                let windowTitle: String? = if resolveWindowTitle {
                    try await target.resolveWindowTitleOptional(services: runtime.services)
                } else {
                    nil
                }
                let appHint = try await self.resolveDialogAppHintIfRequested(
                    resolveAppHint,
                    target: target,
                    services: runtime.services,
                    refusalRoute: actionRoute
                )

                if beginsInteractionMutation {
                    runtime.beginInteractionMutation()
                }
                try await operation(
                    ExecutionContext(
                        services: runtime.services,
                        windowTitle: windowTitle,
                        appHint: appHint,
                        target: dialogTarget,
                        actionSequence: actionSequence
                    )
                )
            } catch {
                throw actionSequence.preservingFailure(
                    error,
                    fallbackRoute: actionRoute,
                    message: "Dialog action failed after foreground focus may have changed desktop state.",
                    hint: "Observe the exact dialog before deciding whether to retry the action."
                )
            }
        } catch let failure as DesktopActionFailure {
            renderDesktopActionFailure(
                failure,
                jsonOutput: jsonOutput,
                logger: logger,
                operation: "Dialog action"
            )
            throw ExitCode(1)
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
