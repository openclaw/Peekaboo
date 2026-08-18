import Commander
import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation

@available(macOS 14.0, *)
@MainActor
struct ActionCommand: ConfirmedActionOutputFormattable, ErrorHandlingCommand, OutputFormattable, RuntimeBackedCommand {
    @Argument(help: "Accessibility action name, e.g. AXPress, AXShowMenu, AXIncrement")
    var actionName: String?

    @Option(help: "Accessibility action name (alternative to the positional argument)")
    var action: String?

    @Option(help: "Element ID or query to act on")
    var on: String?

    @Option(help: "Snapshot ID, or 'latest' (uses latest if not specified)")
    var snapshot: String?

    @OptionGroup var target: InteractionTargetOptions
    @OptionGroup var focusOptions: FocusCommandOptions

    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        try await ElementActionCommandExecutor.execute(
            context: ElementActionCommandContext(
                runtime: runtime,
                snapshot: self.snapshot,
                invalidationReason: "action",
                deliveryMechanism: .accessibilityAction,
                target: self.target,
                focusOptions: self.focusOptions
            ),
            prepare: {
                let actionName = try self.requireAction()
                try self.validateForegroundConsent(for: actionName)
                return try (self.requireTarget(), actionName)
            },
            operation: { automation, target, actionName, snapshotId in
                try await AutomationServiceBridge.performAction(
                    automation: automation,
                    target: target,
                    actionName: actionName,
                    snapshotId: snapshotId
                )
            },
            render: { result, outcome, targetIdentity, outputPayload, requestedAction in
                self.output(outputPayload, outcome: outcome, targetIdentity: targetIdentity) {
                    if let outcome {
                        print(ActionOutcomeHumanRenderer.statusLine(for: outcome, operation: "Action"))
                        print("🎯 Target: \(result.target)")
                        print("⚙️  Action: \(result.actionName ?? requestedAction)")
                    } else {
                        print("✅ Performed \(result.actionName ?? requestedAction) on \(result.target)")
                    }
                }
            },
            handleError: { self.handleError($0) }
        )
    }

    private func requireTarget() throws -> String {
        guard let on = self.on?.trimmingCharacters(in: .whitespacesAndNewlines), !on.isEmpty else {
            throw ValidationError("--on is required")
        }
        return on
    }

    func requireAction() throws -> String {
        if self.actionName != nil, self.action != nil {
            throw ValidationError("Provide the action name positionally or with --action, not both")
        }
        guard let value = self.actionName ?? self.action
        else {
            throw ValidationError("Action name is required")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ValidationError("Action name is required")
        }
        return trimmed
    }

    private func validateForegroundConsent(for actionName: String) throws {
        guard AccessibilityActionPolicy.requiresForegroundConsent(actionName),
              !self.focusOptions.foreground
        else { return }
        throw PreDispatchActionError(
            message: "Accessibility action \(actionName) can raise or expose foreground UI and requires --foreground.",
            code: .VALIDATION_ERROR,
            hint: "Re-run with --foreground only when interrupting the user's desktop is acceptable.",
            reason: .foregroundConsentRequired
        )
    }
}

@MainActor
extension ActionCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        CommandDescription(
            commandName: "action",
            abstract: "Invoke a named accessibility action on an element",
            discussion: """
                Invokes an accessibility action without synthesizing a mouse or keyboard event.
                Actions that can raise or expose foreground UI, including AXPress and AXShowMenu, require
                --foreground. State-only actions such as AXIncrement remain background-capable.

                EXAMPLES:
                  peekaboo action AXPress --on "$ELEMENT_ID" --foreground
                  peekaboo action --action AXIncrement --on Stepper --app Calculator
            """,
            showHelpOnEmptyInvocation: true
        )
    }
}

extension ActionCommand: AsyncRuntimeCommand {}

extension ActionCommand: PreRuntimeValidatingCommand {
    func validateBeforeRuntime() throws {
        _ = try ElementActionCommandExecutor.validateRequest(
            snapshot: self.snapshot,
            target: self.target,
            prepare: {
                let actionName = try self.requireAction()
                try self.validateForegroundConsent(for: actionName)
                return try (self.requireTarget(), actionName)
            }
        )
    }
}

@MainActor
extension ActionCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.actionName = try values.decodeOptionalPositional(0, label: "actionName")
        self.action = values.singleOption("action")
        self.on = values.singleOption("on")
        self.snapshot = values.singleOption("snapshot")
        self.target = try values.makeInteractionTargetOptions()
        self.focusOptions = try values.makeFocusOptions()
    }
}

extension ActionCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(label: "actionName", help: "Accessibility action name", isOptional: true),
            ],
            options: [
                .commandOption("action", help: "Action name (alternative to positional argument)", long: "action"),
                .commandOption("on", help: "Element ID or query to act on", long: "on"),
                .commandOption(
                    "snapshot",
                    help: "Snapshot ID, or 'latest' (uses latest if not specified)",
                    long: "snapshot"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(),
            ]
        )
    }
}
