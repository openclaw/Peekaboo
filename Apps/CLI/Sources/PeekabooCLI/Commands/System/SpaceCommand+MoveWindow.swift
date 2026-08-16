import Commander
import CoreGraphics
import PeekabooCore
import PeekabooFoundation

// MARK: - Move Window to Space

@MainActor
struct MoveWindowSubcommand: ActionOutputFormattable, ErrorHandlingCommand,
    OutputFormattable,
    InjectedRuntimeBackedCommand {
    @Option(name: .long, help: "Target application name, bundle ID, or 'PID:12345'")
    var app: String?

    @Option(name: .long, help: "Target application by process ID")
    var pid: Int32?

    @Option(name: .long, help: "Target window by title (partial match supported)")
    var windowTitle: String?

    @Option(name: .long, help: "Target window by index (0-based, frontmost is 0)")
    var windowIndex: Int?

    @Option(
        name: .long,
        help: "Target window by CoreGraphics window id (window_id from `peekaboo window list --json`)"
    )
    var windowId: Int?

    @Option(name: .long, help: "Space number to move window to (1-based)")
    var to: Int?

    @Flag(name: .long, help: "Move window to current Space")
    var toCurrent = false

    @Flag(name: .long, help: "Switch to the target Space after moving")
    var follow = false

    @Flag(name: .long, help: "Required explicit consent when --follow switches the visible Space")
    var foreground = false
    @RuntimeStorage var runtime: CommandRuntime?

    mutating func validate() throws {
        try self.makeWindowOptions().validateMutation()

        guard self.to != nil || self.toCurrent else {
            throw ValidationError("Must specify either --to or --to-current")
        }
        guard !(self.to != nil && self.toCurrent) else {
            throw ValidationError("Cannot specify both --to and --to-current")
        }
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)

        do {
            if self.follow, !self.foreground {
                throw PreDispatchActionError(
                    message: "Space move-window --follow changes the visible desktop and requires explicit " +
                        "--foreground consent.",
                    code: .VALIDATION_ERROR,
                    hint: "Omit --follow for background window placement, or add --foreground when following is " +
                        "intentional.",
                    reason: .foregroundConsentRequired
                )
            }
            try SpaceCommandHostOwnership.requireLocalMutation(
                services: self.services,
                operation: "move a window between Spaces"
            )
            try self.validate()
            let windowOptions = self.makeWindowOptions()
            let appInfo = try await windowOptions.resolveApplicationInfoIfNeeded(services: self.services)

            let windows = try await WindowServiceBridge.listWindows(
                windows: self.services.windows,
                target: windowOptions.toWindowSelectionTarget()
            )
            let windowInfo = try windowOptions.requireMutationWindow(
                from: windows,
                expectedApplication: appInfo,
                action: "move between Spaces"
            )

            let expectedWindow = try Self.exactWindowTarget(from: windowInfo)
            guard let windowID = CGWindowID(exactly: windowInfo.windowID) else {
                throw self.preDispatchActionError(
                    for: PeekabooError.invalidInput("The selected window has an invalid WindowServer ID"),
                    reason: .targetUnavailable
                )
            }
            let spaceService = SpaceCommandEnvironment.service

            if self.toCurrent {
                self.resolvedRuntime.beginInteractionMutation()
                let actionResult = try await spaceService.moveWindowToCurrentSpaceResult(
                    windowID: windowID,
                    expectedIdentity: expectedWindow.identity
                )
                let (outcome, targetIdentity) = try Self.validateMoveResult(
                    actionResult,
                    expectedWindow: expectedWindow
                )
                AutomationEventLogger.log(
                    .space,
                    "move_window window_id=\(windowID) mode=current title=\"\(windowInfo.title)\""
                )
                if self.jsonOutput {
                    let data = WindowSpaceActionResult(
                        action: "move-window",
                        success: true,
                        window_id: windowID,
                        window_title: windowInfo.title,
                        space_id: nil,
                        space_number: nil,
                        moved_to_current: true,
                        followed: nil
                    )
                    outputSuccessCodable(
                        data: data,
                        outcome: outcome,
                        targetIdentity: targetIdentity,
                        logger: self.logger
                    )
                } else {
                    print(ActionOutcomeHumanRenderer.statusLine(
                        for: outcome,
                        operation: "Space move-window"
                    ))
                    print("Moved window '\(windowInfo.title)' to current Space")
                }
                return
            }

            guard let spaceNum = self.to else {
                preconditionFailure("Expected either --to or --to-current validation")
            }

            let spaces = await spaceService.getAllSpaces()
            guard spaceNum > 0, spaceNum <= spaces.count else {
                throw ValidationError("Invalid Space number. Available: 1-\(spaces.count)")
            }

            let targetSpace = spaces[spaceNum - 1]
            self.resolvedRuntime.beginInteractionMutation()
            let actionResult = try await spaceService.moveWindowToSpaceResult(
                windowID: windowID,
                expectedIdentity: expectedWindow.identity,
                spaceID: targetSpace.id
            )
            let (moveOutcome, targetIdentity) = try Self.validateMoveResult(
                actionResult,
                expectedWindow: expectedWindow
            )
            let outcome: DesktopActionOutcome
            if self.follow {
                let actionSequence = CommandActionSequenceAccumulator()
                try actionSequence.record(actionResult, operation: "Space move-window")
                do {
                    let switchOutcome = try await Self.validateSwitchResult(
                        spaceService.switchToSpaceResult(targetSpace.id)
                    )
                    try actionSequence.record(
                        outcome: switchOutcome,
                        operation: "Space move-window follow"
                    )
                } catch {
                    throw actionSequence.preservingFailure(
                        error,
                        fallbackRoute: moveOutcome.route,
                        message: "Space move-window follow failed after moving the window.",
                        hint: "Observe both the exact window and active Space before retrying."
                    )
                }
                guard let combinedOutcome = actionSequence.resolution.outcome else {
                    throw DesktopActionFailure.indeterminate(
                        route: moveOutcome.route,
                        delivery: nil,
                        evidence: .completionUnknown,
                        unitCount: actionSequence.mutationDisposition.unitCount,
                        message: "Space move-window follow could not compose its two canonical outcomes.",
                        hint: "Observe both the exact window and active Space before retrying."
                    )
                    .attributed(to: DesktopActionTargetReceipt(
                        processIdentifier: expectedWindow.identity.ownerProcessIdentifier,
                        processStartIdentity: expectedWindow.identity.ownerProcessStartIdentity,
                        windowID: expectedWindow.identity.windowID
                    ))
                }
                outcome = combinedOutcome
            } else {
                outcome = moveOutcome
            }
            AutomationEventLogger.log(
                .space,
                "move_window window_id=\(windowID) space=\(spaceNum) follow=\(self.follow ? 1 : 0) "
                    + "title=\"\(windowInfo.title)\""
            )

            if self.jsonOutput {
                let data = WindowSpaceActionResult(
                    action: "move-window",
                    success: true,
                    window_id: windowID,
                    window_title: windowInfo.title,
                    space_id: targetSpace.id,
                    space_number: spaceNum,
                    moved_to_current: false,
                    followed: self.follow
                )
                outputSuccessCodable(
                    data: data,
                    outcome: outcome,
                    targetIdentity: targetIdentity,
                    logger: self.logger
                )
            } else {
                print(ActionOutcomeHumanRenderer.statusLine(
                    for: outcome,
                    operation: "Space move-window"
                ))
                var message = "Moved window '\(windowInfo.title)' to Space \(spaceNum)"
                if self.follow {
                    message += " (and switched to it)"
                }
                print(message)
            }
        } catch {
            handleError(error)
            throw ExitCode(1)
        }
    }

    private static func exactWindowTarget(
        from window: ServiceWindowInfo
    ) throws -> UIAutomationTarget.ExactWindow {
        do {
            return try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.exactWindow(from: window)
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Space move-window requires one exact generation-pinned window with immutable bounds.",
                hint: "Refresh the window inventory before retrying.",
                causeDescription: error.localizedDescription
            )
        }
    }

    private func makeWindowOptions() -> WindowIdentificationOptions {
        var options = WindowIdentificationOptions()
        options.app = self.app
        options.pid = self.pid
        options.windowId = self.windowId
        options.windowTitle = self.windowTitle
        options.windowIndex = self.windowIndex
        return options
    }

    private static func validateMoveResult(
        _ result: UIAutomationActionResult<Void>,
        expectedWindow: UIAutomationTarget.ExactWindow
    ) throws -> (DesktopActionOutcome, DesktopTargetIdentity) {
        let expectedTarget = DesktopTargetIdentity(exactWindow: expectedWindow)
        let outcome = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
            result,
            policy: .confirmedOrDispatched(requiring: .background),
            targetRequirement: .exact(expectedTarget),
            operation: "Space move-window",
            missingOutcomeMessage: "Space move-window returned without a canonical outcome.",
            missingTargetMessage: "Space move-window returned a missing or mismatched exact-window target.",
            rejectedOutcomeMessage: "Space move-window did not return a successful background outcome."
        )
        guard let targetIdentity = result.targetIdentity else {
            preconditionFailure("Accepted exact-window Space move result lost its target identity")
        }
        return (outcome, targetIdentity)
    }

    private static func validateSwitchResult(
        _ result: DesktopActionResult<Void>
    ) throws -> DesktopActionOutcome {
        guard let outcome = result.outcome else {
            throw DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
                message: "Space move-window follow returned without a canonical switch outcome.",
                hint: "Observe the active Space before retrying and update the runtime host."
            )
        }
        guard !outcome.isAccepted(by: .confirmedOrDispatched) else { return outcome }
        guard let failure = DesktopActionFailure(
            outcome: outcome,
            message: "Space move-window follow did not return a successful switch outcome.",
            hint: "Follow the canonical escalation metadata before deciding whether to retry."
        )
        else { preconditionFailure("A non-success Space switch outcome must construct a failure") }
        throw failure
    }
}

@MainActor
extension MoveWindowSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "move-window",
                abstract: "Move a window to a different Space"
            )
        }
    }
}

extension MoveWindowSubcommand: AsyncRuntimeCommand {}

@MainActor
extension MoveWindowSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.app = values.singleOption("app")
        self.pid = try values.decodeOption("pid", as: Int32.self)
        self.windowId = try values.decodeOption("windowId", as: Int.self)
        self.windowTitle = values.singleOption("windowTitle")
        self.windowIndex = try values.decodeOption("windowIndex", as: Int.self)
        self.to = try values.decodeOption("to", as: Int.self)
        self.toCurrent = values.flag("toCurrent")
        self.follow = values.flag("follow")
        self.foreground = values.flag("foreground")
    }
}
