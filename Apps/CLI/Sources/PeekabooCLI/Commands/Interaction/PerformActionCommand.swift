import Commander
import Foundation
import PeekabooAutomationKit
import PeekabooCore

@available(macOS 14.0, *)
@MainActor
struct PerformActionCommand: ErrorHandlingCommand, OutputFormattable, RuntimeBackedCommand {
    @Option(help: "Element ID or query to act on")
    var on: String?

    @Option(help: "Accessibility action name, e.g. AXPress, AXShowMenu, AXIncrement")
    var action: String?

    @Option(help: "Snapshot ID, or 'latest' (uses latest if not specified)")
    var snapshot: String?

    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        try await ElementActionCommandExecutor.execute(
            runtime: runtime,
            snapshot: self.snapshot,
            invalidationReason: "perform-action",
            prepare: {
                try (self.requireTarget(), self.requireAction())
            },
            operation: { automation, target, actionName, snapshotId in
                try await AutomationServiceBridge.performAction(
                    automation: automation,
                    target: target,
                    actionName: actionName,
                    snapshotId: snapshotId
                )
            },
            render: { result, outputPayload, actionName in
                self.output(outputPayload) {
                    print("✅ Performed \(result.actionName ?? actionName) on \(result.target)")
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

    private func requireAction() throws -> String {
        guard let action = self.action?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty else {
            throw ValidationError("--action is required")
        }
        return action
    }
}

@MainActor
extension PerformActionCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        CommandDescription(
            commandName: "perform-action",
            abstract: "Invoke a named accessibility action on an element",
            discussion: """
                Invokes an accessibility action without synthesizing a mouse or keyboard event.

                EXAMPLES:
                  peekaboo perform-action --on "$ELEMENT_ID" --action AXPress
                  peekaboo perform-action --on Stepper --action AXIncrement
            """,
            showHelpOnEmptyInvocation: true
        )
    }
}

extension PerformActionCommand: AsyncRuntimeCommand {}

@MainActor
extension PerformActionCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.on = values.singleOption("on")
        self.action = values.singleOption("action")
        self.snapshot = values.singleOption("snapshot")
    }
}

extension PerformActionCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption("on", help: "Element ID or query to act on", long: "on"),
                .commandOption(
                    "action",
                    help: "Accessibility action name, e.g. AXPress, AXShowMenu, AXIncrement",
                    long: "action"
                ),
                .commandOption(
                    "snapshot",
                    help: "Snapshot ID, or 'latest' (uses latest if not specified)",
                    long: "snapshot"
                ),
            ]
        )
    }
}
