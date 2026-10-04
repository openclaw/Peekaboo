import Commander
import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation

@MainActor
struct SelectTextCommand: ConfirmedActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
RuntimeBackedCommand {
    var text: String?
    var on: String?
    var prefix: String?
    var suffix: String?
    var selectionType = "text"
    var snapshot: String?
    var target = InteractionTargetOptions()
    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        try await ElementActionCommandExecutor.execute(
            context: ElementActionCommandContext(
                runtime: runtime,
                snapshot: self.snapshot,
                invalidationReason: "select-text",
                deliveryMechanism: .accessibilityValue,
                target: self.target,
                focusOptions: FocusCommandOptions(),
                requireExactWindow: true
            ),
            prepare: { try self.preparedRequest() },
            operation: { automation, target, request, snapshotId in
                guard let service = automation as? any ElementActionAutomationServiceProtocol,
                      service.supportsTextSelection
                else {
                    throw DesktopActionFailure.preDispatchRefusal(
                        reason: .runtimeIncompatible, message: "This host does not support receipted text selection."
                    )
                }
                let result = try await service.selectText(target: target, request: request, snapshotId: snapshotId)
                _ = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
                    result, policy: .confirmed(requiring: .background), operation: "Select text"
                )
                guard result.targetIdentity?.exactWindow != nil,
                      result.payload.matchesTextSelection(target: target, request: request)
                else {
                    throw DesktopActionFailure.indeterminate(
                        delivery: result.outcome?.delivery,
                        evidence: .completionUnknown,
                        unitCount: result.outcome?.dispatchState.unitCount ?? .one,
                        message: "The text selection result did not match the exact target request.",
                        hint: "Observe the target before retrying."
                    )
                    .attributed(to: result.targetIdentity?.actionTargetReceipt)
                }
                return result
            },
            render: { result, outcome, identity, output, _ in
                self.output(output, outcome: outcome, targetIdentity: identity) {
                    if let outcome {
                        print(ActionOutcomeHumanRenderer.statusLine(for: outcome, operation: "Select text"))
                    }
                    if let selection = result.textSelection {
                        print("Text selection \(result.target): UTF-16 location \(selection.selectedRange.location), " +
                            "length \(selection.selectedRange.length)")
                    }
                }
            },
            handleError: { self.handleError($0) }
        )
    }

    func preparedRequest() throws -> (target: String, value: TextSelectionRequest) {
        guard let on = self.on?.trimmingCharacters(in: .whitespacesAndNewlines), !on.isEmpty else {
            throw ValidationError("--on is required")
        }
        guard let text, !text.isEmpty else { throw ValidationError("Nonempty selection text is required") }
        guard let mode = TextSelectionType(rawValue: self.selectionType) else {
            throw ValidationError("--selection-type must be text, cursor_before, or cursor_after")
        }
        return (on, TextSelectionRequest(text: text, prefix: self.prefix, suffix: self.suffix, selectionType: mode))
    }
}

extension SelectTextCommand: AsyncRuntimeCommand, CommanderRejectsEmptyInvocation {}

extension SelectTextCommand: PreRuntimeValidatingCommand {
    func validateBeforeRuntime() throws {
        _ = try ElementActionCommandExecutor.validateRequest(
            snapshot: self.snapshot, target: self.target, prepare: { try self.preparedRequest() }
        )
    }
}

extension SelectTextCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        CommandDescription(
            commandName: "select-text",
            abstract: "Select literal text or place a caret without keyboard input",
            discussion: """
            Requires a fresh exact-window snapshot and a settable native text selection.
            Prefix and suffix match immediately adjacent literal context. Ambiguous matches refuse.
            Does not activate, focus, type, or use the clipboard.

            EXAMPLES:
              peekaboo select-text "hello" --on "$ELEMENT_ID" --snapshot "$SNAPSHOT_ID"
              peekaboo select-text "hello" --on "$ELEMENT_ID" --prefix "Say " --selection-type cursor_after
            """,
            showHelpOnEmptyInvocation: true
        )
    }
}

extension SelectTextCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.text = try values.decodeOptionalPositional(0, label: "text")
        self.on = values.singleOption("on")
        self.prefix = values.singleOption("prefix")
        self.suffix = values.singleOption("suffix")
        self.selectionType = values.singleOption("selectionType") ?? "text"
        self.snapshot = values.singleOption("snapshot")
        self.target = try values.makeInteractionTargetOptions()
    }
}

extension SelectTextCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [.make(label: "text", help: "Literal text to select", isOptional: true)],
            options: [
                .commandOption("on", help: "Observed element ID or unique query", long: "on"),
                .commandOption("prefix", help: "Literal context immediately before the match", long: "prefix"),
                .commandOption("suffix", help: "Literal context immediately after the match", long: "suffix"),
                .commandOption(
                    "selectionType",
                    help: "text (default), cursor_before, or cursor_after",
                    long: "selection-type"
                ),
                .commandOption(
                    "snapshot",
                    help: "Fresh exact-window snapshot ID; latest when omitted",
                    long: "snapshot"
                ),
            ],
            optionGroups: [InteractionTargetOptions.commanderSignature()]
        )
    }
}
