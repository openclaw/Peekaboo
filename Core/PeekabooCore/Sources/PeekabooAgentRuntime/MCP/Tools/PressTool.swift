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
        var emittedHotkeyUnits: Int?
        var hotkeyDeliveryKnown = false
        do {
            let chords = try Self.parseChords(arguments: arguments)
            let count = try arguments.validatedInt("count") ?? 1
            let delay = try arguments.validatedInt("delay") ?? 100
            let hold = try arguments.validatedInt("hold") ?? 50
            guard (1...100).contains(count) else {
                return ToolResponse.error("count must be between 1 and 100")
            }
            guard (0...10000).contains(delay) else {
                return ToolResponse.error("delay must be between 0 and 10000ms")
            }
            guard (0...10000).contains(hold) else {
                return ToolResponse.error("hold must be between 0 and 10000ms")
            }

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
            var completed = 0
            var singleOutcome: DesktopActionOutcome?
            do {
                for repetition in 0..<count {
                    for (index, chord) in chords.enumerated() {
                        if let outcomeAutomation = self.context.automation as? any UIAutomationActionOutcomeProviding {
                            let result = try await outcomeAutomation.hotkeyWithOutcome(
                                keys: chord.serviceKeys,
                                holdDuration: hold)
                            singleOutcome = completed == 0 ? result.outcome : nil
                        } else {
                            try await self.context.automation.hotkey(keys: chord.serviceKeys, holdDuration: hold)
                            singleOutcome = nil
                        }
                        completed += 1
                        let isLast = repetition == count - 1 && index == chords.count - 1
                        if delay > 0, !isLast {
                            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                        }
                    }
                }
            } catch let failure as DesktopActionFailure {
                throw Self.aggregateSequenceFailure(
                    failure,
                    completedPresses: completed,
                    setupFocusCompleted: targetFocusCompleted)
            } catch let error as InputDeliveryIndeterminateError {
                hotkeyDeliveryKnown = true
                let completedAndLeafUnits = completed + (error.emittedUnitCount ?? 0)
                emittedHotkeyUnits = completedAndLeafUnits > 0 ? completedAndLeafUnits : nil
                let cumulativeCount = emittedHotkeyUnits.map { $0 + (targetFocusCompleted ? 1 : 0) }
                    ?? (targetFocusCompleted ? 1 : nil)
                throw InputDeliveryIndeterminateError(
                    operation: .hotkey,
                    emittedUnitCount: cumulativeCount,
                    causeDescription: error.causeDescription)
            } catch {
                guard completed > 0 || targetFocusCompleted else { throw error }
                hotkeyDeliveryKnown = completed > 0
                emittedHotkeyUnits = completed > 0 ? completed : nil
                throw InputDeliveryIndeterminateError(
                    operation: .hotkey,
                    emittedUnitCount: completed + (targetFocusCompleted ? 1 : 0),
                    causeDescription: error.localizedDescription)
            }

            let display = chords.map(\.displayValue)
            let elapsed = Date().timeIntervalSince(startTime)
            // A sequence has no canonical aggregate contract. Publishing its last leaf receipt would erase
            // earlier states, so preserve the shipped safety fields until Foundation owns batch composition.
            let outcome = completed == 1 && !targetFocusCompleted ? singleOutcome : nil
            let message = Self.responseMessage(
                display: display,
                completed: completed,
                elapsed: elapsed,
                outcome: outcome)
            var baseMeta: [String: Value] = [
                "keys": .array(display.map(Value.string)),
                "count": .int(count),
                "delay": .int(delay),
                "hold": .int(hold),
                "total_presses": .int(completed),
                "delivery_mode": .string("foreground"),
                "target_pid": .null,
                "execution_time": .double(elapsed),
            ]
            if completed > 1 || targetFocusCompleted {
                baseMeta["effect"] = .string("unverifiable")
                baseMeta["mutation_dispatched"] = .bool(true)
                baseMeta["retry_safe"] = .bool(false)
                baseMeta["requires_fresh_observation"] = .bool(true)
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
            return ToolResponse.error(error.localizedDescription)
        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: nil)
        } catch let error as InputDeliveryIndeterminateError {
            let delivery: DesktopActionOutcome.Delivery? = hotkeyDeliveryKnown
                ? .init(mechanism: .globalEvents, mode: .foreground)
                : nil
            return try await MCPDesktopActionFailureHandler.response(
                for: error.desktopActionFailure(delivery: delivery),
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: nil,
                additionalFields: [
                    "emitted_units": emittedHotkeyUnits.map(Value.int) ?? .null,
                ])
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

    private static func responseMessage(
        display: [String],
        completed: Int,
        elapsed: TimeInterval,
        outcome: DesktopActionOutcome?) -> String
    {
        let sequence = display.joined(separator: " → ")
        let duration = String(format: "%.2f", elapsed)
        guard completed == 1, let outcome else {
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
        completedPresses: Int,
        setupFocusCompleted: Bool) -> DesktopActionFailure
    {
        let completedUnits = completedPresses + (setupFocusCompleted ? 1 : 0)
        guard completedUnits > 0 else { return failure }
        let failedUnits = failure.outcome.dispatchState.unitCount?.rawValue
            ?? (failure.outcome.dispatchState.mutationDispatched ? 1 : 0)
        let unitCount = DesktopActionOutcome.DispatchUnitCount(completedUnits + failedUnits)
        let delivery: DesktopActionOutcome.Delivery? = if completedPresses > 0 ||
            failure.outcome.dispatchState.mutationDispatched
        {
            .init(mechanism: .globalEvents, mode: .foreground)
        } else {
            nil
        }
        if failure.outcome.state == .partial {
            guard let delivery else { return failure }
            return .partial(
                route: failure.outcome.route,
                delivery: delivery,
                unitCount: unitCount,
                message: failure.message,
                hint: failure.hint,
                causeDescription: failure.causeDescription)
        }
        return .indeterminate(
            route: failure.outcome.route,
            delivery: delivery,
            evidence: .completionUnknown,
            unitCount: unitCount,
            message: "Press sequence stopped after \(completedUnits) completed setup/action unit(s).",
            hint: "Observe the target before deciding whether to continue the sequence.",
            causeDescription: failure.localizedDescription)
    }

    private static func foregroundConsentRefusal() throws -> ToolResponse {
        let outcome = RawPressPolicy.foregroundConsentRefusal
        var meta = try MCPToolResponseMetadataProjector.fields(for: outcome.projection)
        meta["code"] = .string(RawPressPolicy.errorCode.rawValue)
        meta["hint"] = .string(RawPressPolicy.foregroundConsentRequiredHint)
        return ToolResponse.error(
            RawPressPolicy.foregroundConsentRequiredMessage,
            meta: .object(meta))
    }
}
