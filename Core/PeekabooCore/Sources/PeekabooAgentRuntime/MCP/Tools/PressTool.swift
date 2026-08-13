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
        """
        Presses one or more raw keyboard chords. Use `keys` for an xdotool-style chord sequence such as
        ["cmd+c", "Return"], or use `key` plus `modifiers` for a single chord. The two input shapes are
        mutually exclusive. Raw chords cannot prove semantic intent or effect on a shared desktop and require
        foreground=true. For certifiable background automation, use action, menu, window, app, or dialog with an
        exact target. app and pid are alternatives; provide at most one of window_id, window_title, or window_index,
        and pair title/index with app or pid.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.6, anthropic/claude-opus-5
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
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
                    description: "Required true. Focus a target or intentionally send OS-global raw keyboard input.",
                    default: false),
            ],
            required: [])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        var targetFocusCompleted = false
        var progress = PressSequenceProgress()
        var failureCompatibility = PressFailureCompatibility.none
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
            guard foreground else {
                return try Self.foregroundConsentRefusal()
            }
            let resolvedWindowTitle = try await target.resolveWindowTitleIfNeeded(windows: self.context.windows)
            targetFocusCompleted = try await target.focusIfRequested(
                windows: self.context.windows,
                onlyWhenTargeted: true) != nil

            let startTime = Date()
            var singleOutcome: DesktopActionOutcome?
            do {
                for repetition in 0..<count {
                    for (index, chord) in chords.enumerated() {
                        if let outcomeAutomation = self.context.automation as? any UIAutomationActionOutcomeProviding {
                            let result = try await outcomeAutomation.hotkeyWithOutcome(
                                keys: chord.serviceKeys,
                                holdDuration: hold)
                            if let outcome = result.outcome,
                               let failure = DesktopActionFailure(
                                   outcome: outcome,
                                   message: "Raw chord \(chord.displayValue) did not return a confirmed outcome.",
                                   hint: "Follow the canonical escalation metadata before deciding whether to retry.")
                            {
                                throw failure
                            }
                            singleOutcome = progress.completedCalls == 0 ? result.outcome : nil
                            progress.record(outcome: result.outcome)
                        } else {
                            try await self.context.automation.hotkey(keys: chord.serviceKeys, holdDuration: hold)
                            singleOutcome = nil
                            progress.record(outcome: nil)
                        }
                        let isLast = repetition == count - 1 && index == chords.count - 1
                        if delay > 0, !isLast {
                            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                        }
                    }
                }
            } catch let failure as DesktopActionFailure {
                failureCompatibility = PressFailureCompatibility(
                    progress: progress,
                    leafFailure: failure)
                throw Self.aggregateSequenceFailure(
                    failure,
                    progress: progress,
                    setupFocusCompleted: targetFocusCompleted)
            } catch let error as InputDeliveryIndeterminateError {
                let failure = error.desktopActionFailure(
                    delivery: .init(mechanism: .globalEvents, mode: .foreground))
                failureCompatibility = PressFailureCompatibility(
                    progress: progress,
                    leafFailure: failure)
                throw Self.aggregateSequenceFailure(
                    failure,
                    progress: progress,
                    setupFocusCompleted: targetFocusCompleted)
            } catch {
                guard progress.dispatchedUnitCount > 0 || targetFocusCompleted else { throw error }
                let failure = DesktopActionFailure.refused(
                    reason: .operationUnsupported,
                    message: error.localizedDescription)
                failureCompatibility = PressFailureCompatibility(
                    progress: progress,
                    leafFailure: failure)
                throw Self.aggregateSequenceFailure(
                    failure,
                    progress: progress,
                    setupFocusCompleted: targetFocusCompleted)
            }

            let display = chords.map(\.displayValue)
            let elapsed = Date().timeIntervalSince(startTime)
            // A sequence has no canonical aggregate contract. Publishing its last leaf receipt would erase
            // earlier states, so preserve the shipped safety fields until Foundation owns batch composition.
            let outcome = if progress.completedCalls == 1 && !targetFocusCompleted {
                singleOutcome
            } else {
                progress.aggregateSuccess(setupFocusCompleted: targetFocusCompleted)
            }
            let message = Self.responseMessage(
                display: display,
                completed: progress.completedCalls,
                elapsed: elapsed,
                outcome: outcome,
                confirmedNoChangeWithoutAggregate: outcome == nil &&
                    progress.allConfirmedNoChange,
                targetFocusCompleted: targetFocusCompleted)
            var baseMeta: [String: Value] = [
                "keys": .array(display.map(Value.string)),
                "count": .int(count),
                "delay": .int(delay),
                "hold": .int(hold),
                "total_presses": .int(progress.completedCalls),
                "target_pid": .null,
                "execution_time": .double(elapsed),
            ]
            if !targetFocusCompleted, progress.dispatchedUnitCount > 0 {
                baseMeta["delivery_mode"] = .string("foreground")
            }
            if outcome == nil, progress.dispatchedUnitCount > 0 || targetFocusCompleted {
                baseMeta["effect"] = .string("unverifiable")
                baseMeta["mutation_dispatched"] = .bool(true)
                baseMeta["retry_safe"] = .bool(false)
                baseMeta["requires_fresh_observation"] = .bool(true)
            }
            if let invalidatedSnapshotID = await self.invalidateSnapshotAfterSuccess(
                outcome: outcome,
                progress: progress,
                targetFocusCompleted: targetFocusCompleted)
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
            return try Self.invalidRequest(error.message)
        } catch let error as MCPToolArgumentValueError {
            return try Self.invalidRequest(error.localizedDescription)
        } catch let failure as DesktopActionFailure {
            return try await self.failureResponse(failure, compatibility: failureCompatibility)
        } catch let error as InputDeliveryIndeterminateError {
            let failure = error.desktopActionFailure(delivery: nil)
            return try await self.failureResponse(failure, compatibility: failureCompatibility)
        } catch {
            self.logger.error("Press execution failed: \(error.localizedDescription)")
            return ToolResponse.error(error.localizedDescription)
        }
    }

    static func parseChords(arguments: ToolArguments) throws -> [KeyboardChord] {
        let sequence = arguments.getStringArray("keys")
        let key = arguments.getString("key")
        let modifiers = arguments.getStringArray("modifiers") ?? []

        if sequence != nil, key != nil || !modifiers.isEmpty {
            throw KeyboardChordError.invalid("Use either keys or key+modifiers, not both")
        }
        if let sequence {
            guard !sequence.isEmpty else {
                throw KeyboardChordError.invalid("keys")
            }
            return try sequence.map(KeyboardChord.init(parsing:))
        }
        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeyboardChordError.invalid("Provide keys or key+modifiers")
        }
        return try [KeyboardChord(parsing: (modifiers + [key]).joined(separator: "+"))]
    }

    @MainActor
    private func invalidateSnapshotAfterSuccess(
        outcome: DesktopActionOutcome?,
        progress: PressSequenceProgress,
        targetFocusCompleted: Bool) async -> String?
    {
        let mutationDispatched = outcome?.dispatchState.mutationDispatched ??
            (progress.dispatchedUnitCount > 0 || targetFocusCompleted)
        return await MCPDesktopActionSnapshotInvalidator.invalidate(
            uiSnapshots: self.context.uiSnapshots,
            snapshotID: nil,
            mutationDispatched: mutationDispatched)
    }

    @MainActor
    private func failureResponse(
        _ failure: DesktopActionFailure,
        compatibility: PressFailureCompatibility) async throws -> ToolResponse
    {
        try await MCPDesktopActionFailureHandler.response(
            for: failure,
            uiSnapshots: self.context.uiSnapshots,
            snapshotID: nil,
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

    private static func responseMessage(
        display: [String],
        completed: Int,
        elapsed: TimeInterval,
        outcome: DesktopActionOutcome?,
        confirmedNoChangeWithoutAggregate: Bool,
        targetFocusCompleted: Bool) -> String
    {
        let sequence = display.joined(separator: " → ")
        let duration = String(format: "%.2f", elapsed)
        guard let outcome else {
            if confirmedNoChangeWithoutAggregate {
                if targetFocusCompleted {
                    return "\(AgentDisplayTokens.Status.warning) Completed \(sequence); " +
                        "all chords confirmed no change. The setup-focus effect is unverifiable; " +
                        "observe before continuing. Completed in \(duration)s"
                }
                return "\(AgentDisplayTokens.Status.success) Completed \(sequence); " +
                    "all chords confirmed no change in \(duration)s"
            }
            return "\(AgentDisplayTokens.Status.success) Dispatched \(sequence) " +
                "(\(completed) raw chord\(completed == 1 ? "" : "s")); effect is unverifiable. " +
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

    static func aggregateSequenceFailure(
        _ failure: DesktopActionFailure,
        progress: PressSequenceProgress,
        setupFocusCompleted: Bool) -> DesktopActionFailure
    {
        let completedUnits = progress.dispatchedUnitCount + (setupFocusCompleted ? 1 : 0)
        guard completedUnits > 0 else { return failure }
        let failedUnits: Int? = if let count = failure.outcome.dispatchState.unitCount?.rawValue {
            count
        } else if failure.outcome.dispatchState.mutationDispatched {
            nil
        } else {
            0
        }
        let unitCount = failedUnits.flatMap { DesktopActionOutcome.DispatchUnitCount(completedUnits + $0) }
        var deliveryIsKnown = !setupFocusCompleted && progress.deliveryIsHomogeneous
        var delivery = progress.homogeneousDelivery
        let failureDispatched = failure.outcome.dispatchState.mutationDispatched
        var routeIsHomogeneous = !setupFocusCompleted && progress.routeIsHomogeneous
        var aggregateRoute = failure.outcome.route
        if failureDispatched {
            if let priorRoute = progress.homogeneousRoute, priorRoute != failure.outcome.route {
                routeIsHomogeneous = false
            }
            if let failureDelivery = failure.outcome.delivery {
                if progress.dispatchedUnitCount == 0 {
                    delivery = failureDelivery
                } else if delivery != failureDelivery {
                    deliveryIsKnown = false
                }
            } else {
                deliveryIsKnown = false
            }
        } else if progress.dispatchedUnitCount > 0,
                  routeIsHomogeneous,
                  let priorRoute = progress.homogeneousRoute
        {
            aggregateRoute = priorRoute
        }
        if !deliveryIsKnown || !routeIsHomogeneous {
            delivery = nil
        }
        if failure.outcome.state == .partial, let delivery, routeIsHomogeneous {
            return .partial(
                route: aggregateRoute,
                delivery: delivery,
                unitCount: unitCount,
                message: failure.message,
                hint: failure.hint,
                causeDescription: failure.causeDescription)
        }
        return .indeterminate(
            route: aggregateRoute,
            delivery: delivery,
            evidence: .completionUnknown,
            unitCount: unitCount,
            message: "Press sequence stopped after \(completedUnits) dispatched setup/action unit(s).",
            hint: "Observe the target before deciding whether to continue the sequence.",
            causeDescription: failure.localizedDescription)
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

struct PressSequenceProgress {
    private(set) var completedCalls = 0
    private(set) var dispatchedUnitCount = 0
    private(set) var homogeneousRoute: DesktopActionOutcome.Route?
    private(set) var homogeneousDelivery: DesktopActionOutcome.Delivery?
    private(set) var routeIsHomogeneous = true
    private(set) var deliveryIsHomogeneous = true
    private(set) var allOutcomesProvided = true
    private(set) var allConfirmedNoChange = true
    private(set) var outcomeRoute: DesktopActionOutcome.Route?
    private(set) var outcomeRouteIsHomogeneous = true

    mutating func record(outcome: DesktopActionOutcome?) {
        self.completedCalls += 1
        guard let outcome else {
            self.allOutcomesProvided = false
            self.allConfirmedNoChange = false
            return self.recordLegacyDispatch()
        }
        if outcome.state != .confirmedNoChange {
            self.allConfirmedNoChange = false
        }
        if let outcomeRoute, outcomeRoute != outcome.route {
            self.outcomeRouteIsHomogeneous = false
        } else if self.outcomeRoute == nil {
            self.outcomeRoute = outcome.route
        }
        guard outcome.dispatchState.mutationDispatched else { return }

        let unitCount = outcome.dispatchState.unitCount?.rawValue ?? 1
        self.dispatchedUnitCount += unitCount
        let route = outcome.route
        guard let delivery = outcome.delivery else {
            self.deliveryIsHomogeneous = false
            return
        }
        if let homogeneousRoute, homogeneousRoute != route {
            self.routeIsHomogeneous = false
        } else if self.homogeneousRoute == nil {
            self.homogeneousRoute = route
        }
        if let homogeneousDelivery, homogeneousDelivery != delivery {
            self.deliveryIsHomogeneous = false
        } else if self.homogeneousDelivery == nil {
            self.homogeneousDelivery = delivery
        }
    }

    func aggregateSuccess(setupFocusCompleted: Bool) -> DesktopActionOutcome? {
        guard !setupFocusCompleted,
              self.completedCalls > 0,
              self.allOutcomesProvided
        else { return nil }
        guard self.dispatchedUnitCount > 0 else {
            guard self.outcomeRouteIsHomogeneous, let outcomeRoute else { return nil }
            return .confirmedNoChange(route: outcomeRoute)
        }
        guard self.routeIsHomogeneous,
              let homogeneousRoute,
              self.deliveryIsHomogeneous,
              let delivery = self.homogeneousDelivery
        else { return nil }
        return .confirmedChange(
            route: homogeneousRoute,
            delivery: delivery,
            unitCount: DesktopActionOutcome.DispatchUnitCount(self.dispatchedUnitCount))
    }

    private mutating func recordLegacyDispatch() {
        self.dispatchedUnitCount += 1
        let route = DesktopActionOutcome.Route.local
        let delivery = DesktopActionOutcome.Delivery(mechanism: .globalEvents, mode: .foreground)
        if let homogeneousRoute, homogeneousRoute != route {
            self.routeIsHomogeneous = false
        } else if self.homogeneousRoute == nil {
            self.homogeneousRoute = route
        }
        if let homogeneousDelivery, homogeneousDelivery != delivery {
            self.deliveryIsHomogeneous = false
        } else if self.homogeneousDelivery == nil {
            self.homogeneousDelivery = delivery
        }
    }
}

struct PressFailureCompatibility {
    static let none = PressFailureCompatibility(reportsEmittedUnits: false, emittedUnits: nil)

    let reportsEmittedUnits: Bool
    let emittedUnits: Int?

    init(progress: PressSequenceProgress, leafFailure: DesktopActionFailure) {
        let leafDispatched = leafFailure.outcome.dispatchState.mutationDispatched
        self.reportsEmittedUnits = progress.dispatchedUnitCount > 0 || leafDispatched
        let knownUnits = progress.dispatchedUnitCount +
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

private struct PressExecutionParameters {
    let count: Int
    let delay: Int
    let hold: Int
}

private struct PressToolValidationError: Error {
    let message: String
}
