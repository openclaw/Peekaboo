import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

/// MCP tool for pressing keyboard chords and chord sequences.
public struct PressTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "PressTool")
    private let context: MCPToolContext

    public let name = "press"

    public var description: String {
        let targeting = if self.context.executionPolicy == .backgroundOnly {
            """
            Background-only MCP/Agent delivery requires an explicit fresh exact non-dialog snapshot receipt.
            App, PID, window-selector-only, targetless, competing-selector, and foreground forms are refused.
            """
        } else {
            """
            Foreground-capable callers may use foreground=true or an exact window/snapshot receipt whose focused
            element can be pinned through native background dispatch.
            """
        }
        return """
        Presses one or more raw keyboard chords. Use `keys` for an xdotool-style chord sequence such as
        ["cmd+c", "Return"], or use `key` plus `modifiers` for a single chord. The two input shapes are
        mutually exclusive. \(targeting)
        Raw chords cannot prove semantic intent or effect; observe the exact target after unverified delivery.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.6, anthropic/claude-opus-5
        """
    }

    public var inputSchema: Value {
        let backgroundOnly = self.context.executionPolicy == .backgroundOnly
        var properties: [String: Value] = [
            "keys": SchemaBuilder.array(
                items: SchemaBuilder.string(),
                description: "Optional chord sequence using xdotool key syntax, e.g. ['cmd+c', 'Return'].",
                minItems: 1),
            "key": SchemaBuilder.string(
                description: "Optional single primary key, used with modifiers instead of keys."),
            "modifiers": SchemaBuilder.array(
                items: SchemaBuilder.string(enum: [
                    "cmd",
                    "command",
                    "shift",
                    "option",
                    "alt",
                    "ctrl",
                    "control",
                    "fn",
                ]),
                description: "Optional modifiers for the single key form."),
            "count": SchemaBuilder.integer(
                description: "Optional repeat count for the complete chord sequence. Default: 1.",
                minimum: 1,
                maximum: 100,
                default: 1),
            "delay": SchemaBuilder.integer(
                description: "Optional delay between chord presses in milliseconds. Default: 100.",
                minimum: 0,
                maximum: 10000,
                default: 100),
            "hold": SchemaBuilder.integer(
                description: "Optional duration to hold each chord in milliseconds. Default: 50.",
                minimum: 0,
                maximum: 10000,
                default: 50),
            "snapshot": SchemaBuilder.string(
                description: backgroundOnly
                    ? "Required fresh exact non-dialog snapshot for receipt-pinned background press."
                    : "Optional exact-window snapshot for receipt-pinned background press."),
        ]
        if !backgroundOnly {
            properties.merge([
                "app": SchemaBuilder.string(description: "Optional target app name/bundle ID, or 'PID:<n>'."),
                "pid": SchemaBuilder.integer(
                    description: "Optional process to focus before foreground raw input.",
                    minimum: 1),
                "window_id": SchemaBuilder.integer(description: "Optional window ID to focus before raw input."),
                "window_title": SchemaBuilder
                    .string(description: "Optional window title (substring match) to focus before raw input."),
                "window_index": SchemaBuilder
                    .integer(description: "Optional window index (0-based); requires app/pid."),
                "foreground": SchemaBuilder.boolean(
                    description: "Required true for targetless, app-only, or PID-only raw input; false is allowed " +
                        "only with an exact window or fresh snapshot receipt.",
                    default: false),
            ]) { _, new in new }
        }
        return SchemaBuilder.object(
            properties: properties,
            required: backgroundOnly ? ["snapshot"] : [])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    func validateArgumentSemantics(_ arguments: ToolArguments) throws {
        _ = try Self.parseChords(arguments: arguments)
        _ = try Self.executionParameters(arguments: arguments)
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        do {
            let chords = try Self.parseChords(arguments: arguments)
            let parameters = try Self.executionParameters(arguments: arguments)
            let count = parameters.count
            let delay = parameters.delay
            let hold = parameters.hold

            let foreground = arguments.getBool("foreground") == true
            let target = try MCPInteractionTarget(
                app: arguments.getString("app"),
                pid: arguments.validatedInt("pid"),
                windowTitle: arguments.getString("window_title"),
                windowIndex: arguments.validatedInt("window_index"),
                windowId: arguments.validatedInt("window_id"))
            let snapshotID = arguments.getString("snapshot")
            if foreground, snapshotID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                throw PressToolValidationError(
                    message: "snapshot is only supported for receipt-pinned background press")
            }
            guard foreground || target.hasWindowSelector ||
                snapshotID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else {
                return try Self.foregroundConsentRefusal()
            }
            let resolvedWindowTitle = try await target.resolveWindowTitleIfNeeded(windows: self.context.windows)
            let deliveryPlan = try await self.resolveDeliveryTarget(
                foreground: foreground,
                target: target,
                snapshotID: snapshotID)
            let targetFocusCompleted = deliveryPlan.focusResult != nil

            let startTime = Date()
            let run = try await self.dispatchSequence(
                chords: chords,
                parameters: parameters,
                target: deliveryPlan.target,
                focusResult: deliveryPlan.focusResult)
            let display = chords.map(\.displayValue)
            let elapsed = Date().timeIntervalSince(startTime)
            let sequenceResolution = run.resolution
            let outcome = sequenceResolution.outcome
            let message = Self.responseMessage(PressResponseMessageInput(
                display: display,
                completed: run.completedPresses,
                elapsed: elapsed,
                outcome: outcome,
                confirmedNoChangeWithoutAggregate: outcome == nil &&
                    run.allChordsConfirmedNoChange,
                targetFocusCompleted: targetFocusCompleted))
            var baseMeta: [String: Value] = [
                "keys": .array(display.map(Value.string)),
                "count": .int(count),
                "delay": .int(delay),
                "hold": .int(hold),
                "total_presses": .int(run.completedPresses),
                "target_pid": deliveryPlan.target.processIdentifier.map { .int(Int($0)) } ?? .null,
                "target_window_id": deliveryPlan.target.exactWindow.map { .int($0.identity.windowID) } ?? .null,
                "execution_time": .double(elapsed),
            ]
            if !targetFocusCompleted, sequenceResolution.mutationDispatched {
                baseMeta["delivery_mode"] = .string(
                    deliveryPlan.target.processIdentifier == nil ? "foreground" : "background")
            }
            if outcome == nil {
                if sequenceResolution.mutationDispatched {
                    baseMeta["effect"] = .string(DesktopActionOutcome.Effect.unverifiable.rawValue)
                }
                baseMeta["mutation_dispatched"] = .bool(sequenceResolution.mutationDispatched)
                baseMeta["retry_safe"] = .bool(sequenceResolution.retrySafe)
                baseMeta["requires_fresh_observation"] = .bool(sequenceResolution.requiresFreshObservation)
            }
            if let invalidatedSnapshotID = await self.invalidateSnapshotAfterSuccess(
                resolution: sequenceResolution,
                snapshotID: snapshotID)
            {
                baseMeta["invalidated_snapshot"] = .string(invalidatedSnapshotID)
            }
            let summary = ToolEventSummary(
                targetApp: target.appIdentifier,
                windowTitle: resolvedWindowTitle,
                actionDescription: "Press",
                waitDurationMs: Double(hold),
                notes: display.joined(separator: " → "))
            let meta = try MCPToolResponseMetadataProjector.metadata(merging: baseMeta, outcome: outcome)
            return ToolResponse.text(message, meta: ToolEventSummary.merge(summary: summary, into: meta))
        } catch let error as MCPInteractionTargetError {
            return MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
                message: error.localizedDescription,
                reason: error.refusalReason)
        } catch let error as KeyboardChordError {
            return try Self.invalidRequest(error.localizedDescription)
        } catch let error as PressToolValidationError {
            return MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
                message: error.message,
                reason: error.refusalReason)
        } catch let error as MCPToolArgumentValueError {
            return try Self.invalidRequest(error.localizedDescription)
        } catch let failure as PressSequenceFailure {
            return try await self.failureResponse(
                failure.failure,
                compatibility: failure.compatibility,
                snapshotID: arguments.getString("snapshot"))
        } catch let failure as DesktopActionFailure {
            return try await self.failureResponse(
                failure,
                compatibility: .none,
                snapshotID: arguments.getString("snapshot"))
        } catch let error as InputDeliveryIndeterminateError {
            let failure = error.desktopActionFailure(delivery: nil)
            return try await self.failureResponse(
                failure,
                compatibility: .none,
                snapshotID: arguments.getString("snapshot"))
        } catch {
            self.logger.error("Press execution failed: \(error.localizedDescription)")
            return ToolResponse.error(error.localizedDescription)
        }
    }

    @MainActor
    private func dispatchSequence(
        chords: [KeyboardChord],
        parameters: PressExecutionParameters,
        target: UIAutomationTarget,
        focusResult: MCPInteractionFocusResult?) async throws -> PressSequenceRun
    {
        var sequence = DesktopActionSequenceAccumulator()
        if let focusResult {
            focusResult.record(into: &sequence)
        }
        var chordSequence = DesktopActionSequenceAccumulator()
        var completedPresses = 0
        var allChordsConfirmedNoChange = true
        do {
            for repetition in 0..<parameters.count {
                for (index, chord) in chords.enumerated() {
                    let result = try await self.dispatch(
                        chord: chord,
                        hold: parameters.hold,
                        target: target)
                    try DesktopActionFailure.requireConfirmedIfReported(
                        result.outcome,
                        operation: "Raw chord \(chord.displayValue)")
                    if let outcome = result.outcome {
                        allChordsConfirmedNoChange = allChordsConfirmedNoChange &&
                            outcome.state == .confirmedNoChange
                        let step = DesktopActionSequenceAccumulator.Step.reportedOutcome(
                            outcome,
                            defaultDispatchedUnitCount: .one)
                        sequence.record(step)
                        chordSequence.record(step)
                    } else {
                        allChordsConfirmedNoChange = false
                        let step = DesktopActionSequenceAccumulator.Step.dispatched(
                            route: .local,
                            delivery: Self.delivery(for: target),
                            unitCount: Self.singleDispatchUnit)
                        sequence.record(step)
                        chordSequence.record(step)
                    }
                    completedPresses += 1
                    let isLast = repetition == parameters.count - 1 && index == chords.count - 1
                    if parameters.delay > 0, !isLast {
                        try await Task.sleep(nanoseconds: UInt64(parameters.delay) * 1_000_000)
                    }
                }
            }
        } catch let failure as DesktopActionFailure {
            throw Self.sequenceFailure(
                failure,
                sequence: sequence,
                focusResult: focusResult,
                completedPresses: completedPresses,
                chordDisposition: chordSequence.mutationDisposition)
        } catch let error as InputDeliveryIndeterminateError {
            throw Self.sequenceFailure(
                error.desktopActionFailure(delivery: Self.delivery(for: target)),
                sequence: sequence,
                focusResult: focusResult,
                completedPresses: completedPresses,
                chordDisposition: chordSequence.mutationDisposition,
                causeDescription: error.causeDescription ?? error.localizedDescription)
        } catch {
            guard sequence.mutationDisposition.mutationDispatched else { throw error }
            throw Self.sequenceFailure(
                .preDispatchRefusal(reason: .operationUnsupported, message: error.localizedDescription),
                sequence: sequence,
                focusResult: focusResult,
                completedPresses: completedPresses,
                chordDisposition: chordSequence.mutationDisposition,
                causeDescription: error.localizedDescription)
        }
        return PressSequenceRun(
            resolution: sequence.successResolution(),
            completedPresses: completedPresses,
            allChordsConfirmedNoChange: allChordsConfirmedNoChange)
    }

    @MainActor
    private func dispatch(
        chord: KeyboardChord,
        hold: Int,
        target: UIAutomationTarget) async throws -> UIAutomationActionResult<Void>
    {
        if let exactWindow = target.exactWindow {
            let outcomeAutomation = try ExactWindowKeyboardRuntime.requireOutcomeProvider(
                automation: self.context.automation,
                operation: "Background hotkeys")
            guard let focusedElement = exactWindow.focusedElement else {
                throw PressToolValidationError(
                    message: "Exact-window background hotkeys require a focused-element receipt.")
            }
            return try await ExactWindowKeyboardRuntime.validateRouteReceipt(
                outcomeAutomation.hotkeyWithOutcome(
                    keys: chord.serviceKeys,
                    holdDuration: hold,
                    target: ExactWindowKeyboardTarget(
                        windowIdentity: exactWindow.identity,
                        windowBounds: exactWindow.bounds,
                        focusedElement: focusedElement)),
                operation: "Background hotkeys")
        }
        if let automation = self.context.automation as? any UIAutomationActionOutcomeProviding {
            return try await automation.hotkeyWithOutcome(keys: chord.serviceKeys, holdDuration: hold)
        }
        try await self.context.automation.hotkey(keys: chord.serviceKeys, holdDuration: hold)
        return UIAutomationActionResult(payload: (), outcome: nil)
    }

    private static func sequenceFailure(
        _ leafFailure: DesktopActionFailure,
        sequence: DesktopActionSequenceAccumulator,
        focusResult: MCPInteractionFocusResult?,
        completedPresses: Int,
        chordDisposition: DesktopActionMutationDisposition,
        causeDescription: String? = nil) -> PressSequenceFailure
    {
        let failure = sequence.failure(
            combining: leafFailure,
            message: "Press sequence stopped after \(completedPresses) completed press(es).",
            hint: "Observe the target before deciding whether to continue the sequence.",
            causeDescription: causeDescription)
        return PressSequenceFailure(
            failure: focusResult?.attributing(failure) ?? failure,
            compatibility: PressFailureCompatibility(
                prefixDisposition: chordDisposition,
                leafFailure: leafFailure))
    }

    static func parseChords(arguments: ToolArguments) throws -> [KeyboardChord] {
        let hasSequence = arguments.getValue(for: "keys") != nil
        let hasKey = arguments.getValue(for: "key") != nil
        let hasModifiers = arguments.getValue(for: "modifiers") != nil
        if hasSequence, hasKey || hasModifiers {
            throw PressToolValidationError(message: "Use either keys or key+modifiers, not both")
        }

        let sequence = try self.validatedChordSequence(arguments: arguments)
        if let sequence {
            return try sequence.map(KeyboardChord.init(parsing:))
        }

        let key = try self.validatedPrimaryKey(arguments: arguments)
        let modifiers = try self.validatedModifiers(arguments: arguments) ?? []
        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PressToolValidationError(
                message: "Provide either a non-empty keys array or a non-empty key with optional modifiers")
        }
        return try [KeyboardChord(parsing: (modifiers + [key]).joined(separator: "+"))]
    }

    private static func validatedChordSequence(arguments: ToolArguments) throws -> [String]? {
        guard let value = arguments.getValue(for: "keys") else { return nil }
        guard case let .array(items) = value else {
            throw PressToolValidationError(message: "keys must be an array of chord strings")
        }
        guard !items.isEmpty else {
            throw PressToolValidationError(message: "keys must contain at least one chord")
        }
        return try items.enumerated().map { index, item in
            guard case let .string(chord) = item,
                  !chord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw PressToolValidationError(message: "keys[\(index)] must be a non-empty chord string")
            }
            return chord
        }
    }

    private static func validatedModifiers(arguments: ToolArguments) throws -> [String]? {
        guard let value = arguments.getValue(for: "modifiers") else { return nil }
        guard case let .array(items) = value else {
            throw PressToolValidationError(message: "modifiers must be an array of modifier strings")
        }
        return try items.enumerated().map { index, item in
            guard case let .string(modifier) = item,
                  !modifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw PressToolValidationError(
                    message: "modifiers[\(index)] must be a non-empty modifier string")
            }
            return modifier
        }
    }

    private static func validatedPrimaryKey(arguments: ToolArguments) throws -> String? {
        guard let value = arguments.getValue(for: "key") else { return nil }
        guard case let .string(key) = value else {
            throw PressToolValidationError(message: "key must be a primary key string")
        }
        return key
    }

    @MainActor
    private func resolveDeliveryTarget(
        foreground: Bool,
        target: MCPInteractionTarget,
        snapshotID: String?) async throws -> PressDeliveryPlan
    {
        if foreground {
            let focusResult = try await target.focusResultIfRequested(
                windows: self.context.windows,
                onlyWhenTargeted: true)
            return PressDeliveryPlan(target: .foreground, focusResult: focusResult)
        }

        let snapshotExactWindow = try await self.snapshotExactWindow(id: snapshotID)
        let plannedTarget: UIAutomationTarget
        do {
            plannedTarget = try await target.requireBackgroundKeyboardTarget(
                applications: self.context.applications,
                windows: self.context.windows,
                snapshotExactWindow: snapshotExactWindow,
                requiresExplicitExactWindow: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MCPInteractionTargetError {
            throw error
        } catch {
            throw PressToolValidationError(
                message: error.localizedDescription,
                refusalReason: .targetUnavailable)
        }
        guard plannedTarget.exactWindow != nil else {
            throw PressToolValidationError(
                message: "Background raw key presses require one exact-window receipt.",
                refusalReason: .invalidRequest)
        }
        do {
            _ = try ExactWindowKeyboardRuntime.requireOutcomeProvider(
                automation: self.context.automation,
                operation: "Background hotkeys")
        } catch {
            throw PressToolValidationError(
                message: error.localizedDescription,
                refusalReason: .runtimeIncompatible)
        }
        guard self.context.automation is any TargetedFocusedElementServiceProtocol else {
            throw PressToolValidationError(
                message: "This automation host does not support focused exact-window background hotkeys.",
                refusalReason: .runtimeIncompatible)
        }
        do {
            let deliveryTarget = try await plannedTarget.pinningCurrentFocusedElement(
                using: self.context.automation)
            return PressDeliveryPlan(target: deliveryTarget, focusResult: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PressToolValidationError(
                message: error.localizedDescription,
                refusalReason: .targetUnavailable)
        }
    }

    private func snapshotExactWindow(id: String?) async throws -> UIAutomationTarget.ExactWindow? {
        guard let id, !id.isEmpty else { return nil }
        guard let snapshot = await self.context.uiSnapshots.getSnapshot(id: id) else {
            throw PressToolValidationError(
                message: "The selected snapshot has no exact process-generation, window, and bounds receipt.",
                refusalReason: .targetUnavailable)
        }
        do {
            guard let exactWindow = try snapshot.targetReceipt().requireIdentity().exactWindow else {
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
            return exactWindow
        } catch {
            throw PressToolValidationError(
                message: "The selected snapshot has no exact process-generation, window, and bounds receipt.",
                refusalReason: .targetUnavailable)
        }
    }

    private static func delivery(for target: UIAutomationTarget) -> DesktopActionOutcome.Delivery {
        target.exactWindow == nil
            ? .init(mechanism: .globalEvents, mode: .foreground)
            : .init(mechanism: .windowTargetedEvents, mode: .background)
    }

    @MainActor
    private func invalidateSnapshotAfterSuccess(
        resolution: DesktopActionSequenceAccumulator.Resolution,
        snapshotID: String?) async -> String?
    {
        await MCPDesktopActionSnapshotInvalidator.invalidate(
            uiSnapshots: self.context.uiSnapshots,
            snapshotID: snapshotID,
            mutationDispatched: resolution.mutationDispatched)
    }

    @MainActor
    private func failureResponse(
        _ failure: DesktopActionFailure,
        compatibility: PressFailureCompatibility,
        snapshotID: String?) async throws -> ToolResponse
    {
        try await MCPDesktopActionFailureHandler.response(
            for: failure,
            uiSnapshots: self.context.uiSnapshots,
            snapshotID: snapshotID,
            additionalFields: compatibility.fields)
    }

    private static func invalidRequest(_ message: String) throws -> ToolResponse {
        MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
            message: message,
            reason: .invalidRequest)
    }

    private static func executionParameters(arguments: ToolArguments) throws -> PressExecutionParameters {
        let parameters = try PressExecutionParameters(
            count: arguments.validatedInt("count") ?? 1,
            delay: arguments.validatedInt("delay") ?? 100,
            hold: arguments.validatedInt("hold") ?? 50)
        guard (1...100).contains(parameters.count) else {
            throw PressToolValidationError(message: "count must be between 1 and 100")
        }
        guard (0...10000).contains(parameters.delay) else {
            throw PressToolValidationError(message: "delay must be between 0 and 10000ms")
        }
        guard (0...10000).contains(parameters.hold) else {
            throw PressToolValidationError(message: "hold must be between 0 and 10000ms")
        }
        return parameters
    }

    private static func responseMessage(_ input: PressResponseMessageInput) -> String {
        let sequence = input.display.joined(separator: " → ")
        let duration = String(format: "%.2f", input.elapsed)
        guard let outcome = input.outcome else {
            if input.confirmedNoChangeWithoutAggregate {
                if input.targetFocusCompleted {
                    return "\(AgentDisplayTokens.Status.warning) Completed \(sequence); " +
                        "all chords confirmed no change. The setup-focus effect is unverifiable; " +
                        "observe before continuing. Completed in \(duration)s"
                }
                return "\(AgentDisplayTokens.Status.success) Completed \(sequence); " +
                    "all chords confirmed no change in \(duration)s"
            }
            return "\(AgentDisplayTokens.Status.success) Dispatched \(sequence) " +
                "(\(input.completed) raw chord\(input.completed == 1 ? "" : "s")); effect is unverifiable. " +
                "Observe before continuing. Completed in \(duration)s"
        }
        return switch outcome.state {
        case .confirmedChange:
            "\(AgentDisplayTokens.Status.success) Completed \(sequence); effect confirmed in \(duration)s"
        case .confirmedNoChange:
            "\(AgentDisplayTokens.Status.success) Completed \(sequence); confirmed no change in \(duration)s"
        case .partial:
            "\(AgentDisplayTokens.Status.warning) Completed \(sequence) with a partial effect in \(duration)s"
        case .dispatchedUnverified:
            "\(AgentDisplayTokens.Status.warning) Dispatched \(sequence); effect is unverifiable. " +
                "Observe before continuing. Completed in \(duration)s"
        case .suspectedNoop:
            "\(AgentDisplayTokens.Status.warning) Dispatched \(sequence), but no change was observed. " +
                "Refresh the target before retrying. Completed in \(duration)s"
        case .refused:
            "\(AgentDisplayTokens.Status.failure) \(sequence) was refused before dispatch in \(duration)s"
        case .indeterminate:
            "\(AgentDisplayTokens.Status.warning) \(sequence) has an indeterminate outcome. " +
                "Observe before continuing. Completed in \(duration)s"
        }
    }

    private static func foregroundConsentRefusal() throws -> ToolResponse {
        MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
            message: RawPressPolicy.foregroundConsentRequiredMessage,
            reason: .foregroundConsentRequired,
            additionalFields: [
                "code": .string(RawPressPolicy.errorCode.rawValue),
                "hint": .string(RawPressPolicy.foregroundConsentRequiredHint),
            ])
    }
}

struct PressFailureCompatibility {
    static let none = PressFailureCompatibility(reportsEmittedUnits: false, emittedUnits: nil)

    let reportsEmittedUnits: Bool
    let emittedUnits: Int?

    init(prefixDisposition: DesktopActionMutationDisposition, leafFailure: DesktopActionFailure) {
        let leafDispatched = leafFailure.outcome.dispatchState.mutationDispatched
        self.reportsEmittedUnits = prefixDisposition.mutationDispatched || leafDispatched
        let knownUnits = (prefixDisposition.unitCount?.rawValue ?? 0) +
            (leafFailure.outcome.dispatchState.unitCount?.rawValue ?? 0)
        self.emittedUnits = knownUnits > 0 ? knownUnits : nil
    }

    private init(reportsEmittedUnits: Bool, emittedUnits: Int?) {
        self.reportsEmittedUnits = reportsEmittedUnits
        self.emittedUnits = emittedUnits
    }

    var fields: [String: Value] {
        guard self.reportsEmittedUnits else { return [:] }
        return ["emitted_units": self.emittedUnits.map(Value.int) ?? .null]
    }
}

extension PressTool {
    fileprivate static let singleDispatchUnit: DesktopActionOutcome.DispatchUnitCount = .one
}

private struct PressExecutionParameters {
    let count: Int
    let delay: Int
    let hold: Int
}

private struct PressSequenceRun {
    let resolution: DesktopActionSequenceAccumulator.Resolution
    let completedPresses: Int
    let allChordsConfirmedNoChange: Bool
}

private struct PressSequenceFailure: Error {
    let failure: DesktopActionFailure
    let compatibility: PressFailureCompatibility
}

private struct PressDeliveryPlan {
    let target: UIAutomationTarget
    let focusResult: MCPInteractionFocusResult?
}

private struct PressResponseMessageInput {
    let display: [String]
    let completed: Int
    let elapsed: TimeInterval
    let outcome: DesktopActionOutcome?
    let confirmedNoChangeWithoutAggregate: Bool
    let targetFocusCompleted: Bool
}

struct PressToolValidationError: LocalizedError {
    let message: String
    let refusalReason: DesktopActionOutcome.RefusalReason

    init(
        message: String,
        refusalReason: DesktopActionOutcome.RefusalReason = .invalidRequest)
    {
        self.message = message
        self.refusalReason = refusalReason
    }

    var errorDescription: String? {
        self.message
    }
}

extension PressTool: MCPToolArgumentSemanticValidating {}
