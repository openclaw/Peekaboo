import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

/// MCP tool for pressing keyboard chords and chord sequences.
public struct PressTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "PressTool")
    private let context: MCPToolContext

    public let name = "press"

    public var description: String {
        """
        Presses one or more keyboard chords. Use `keys` for an xdotool-style chord sequence such as
        ["cmd+c", "Return"], or use `key` plus `modifiers` for a single chord. The two input shapes are
        mutually exclusive. Background delivery requires app/pid targeting; set foreground=true for intentional
        OS-global shortcuts or to focus a specific window first. app and pid are alternatives; provide at most one of
        window_id, window_title, or window_index, and pair title/index with app or pid.
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
                    description: "Optional target process ID for background keyboard input.",
                    minimum: 1),
                "window_id": SchemaBuilder.integer(description: "Optional window ID; requires foreground=true."),
                "window_title": SchemaBuilder
                    .string(description: "Optional window title (substring match); requires foreground=true."),
                "window_index": SchemaBuilder
                    .integer(description: "Optional window index (0-based); requires app/pid and foreground=true."),
                "foreground": SchemaBuilder.boolean(
                    description: "Optional. Focus a target or intentionally send OS-global keyboard input.",
                    default: false),
            ],
            required: [])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        do {
            let chords = try Self.parseChords(arguments: arguments)
            let count = arguments.getInt("count") ?? 1
            let delay = arguments.getInt("delay") ?? 100
            let hold = arguments.getInt("hold") ?? 50
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
                pid: arguments.getInt("pid"),
                windowTitle: arguments.getString("window_title"),
                windowIndex: arguments.getInt("window_index"),
                windowId: arguments.getInt("window_id"))
            let resolvedWindowTitle = try await target.resolveWindowTitleIfNeeded(windows: self.context.windows)
            let targetIdentity = foreground ? nil : try await target.requireBackgroundProcessIdentity(
                applications: self.context.applications,
                windows: self.context.windows)
            let targetPID = targetIdentity?.processIdentifier

            if targetPID == nil {
                _ = try await target.focusIfRequested(windows: self.context.windows, onlyWhenTargeted: true)
            }

            let startTime = Date()
            var completed = 0
            do {
                for repetition in 0..<count {
                    for (index, chord) in chords.enumerated() {
                        if let targetIdentity {
                            guard let targeted = self.context.automation as? any TargetedHotkeyServiceProtocol,
                                  targeted.supportsTargetedHotkeys,
                                  targeted.supportsProcessGenerationPinnedHotkeys
                            else {
                                return ToolResponse
                                    .error("This automation host does not support background keyboard input.")
                            }
                            try await targeted.hotkey(
                                keys: chord.serviceKeys,
                                holdDuration: hold,
                                expectedProcessIdentity: targetIdentity)
                        } else {
                            try await self.context.automation.hotkey(keys: chord.serviceKeys, holdDuration: hold)
                        }
                        completed += 1
                        let isLast = repetition == count - 1 && index == chords.count - 1
                        if delay > 0, !isLast {
                            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                        }
                    }
                }
            } catch let error as InputDeliveryIndeterminateError {
                let cumulativeCount = error.emittedUnitCount.map { completed + $0 }
                throw InputDeliveryIndeterminateError(
                    operation: .hotkey,
                    emittedUnitCount: cumulativeCount,
                    causeDescription: error.causeDescription)
            } catch {
                guard completed > 0 else { throw error }
                throw InputDeliveryIndeterminateError(
                    operation: .hotkey,
                    emittedUnitCount: completed,
                    causeDescription: error.localizedDescription)
            }

            let display = chords.map(\.displayValue)
            let elapsed = Date().timeIntervalSince(startTime)
            let message = "\(AgentDisplayTokens.Status.success) Pressed \(display.joined(separator: " → ")) " +
                "(\(completed) chord press\(completed == 1 ? "" : "es")) in \(String(format: "%.2f", elapsed))s"
            let meta: Value = .object([
                "keys": .array(display.map(Value.string)),
                "count": .int(count),
                "delay": .int(delay),
                "hold": .int(hold),
                "total_presses": .int(completed),
                "delivery_mode": .string(targetPID == nil ? "foreground" : "background"),
                "target_pid": targetPID.map { .int(Int($0)) } ?? .null,
                "execution_time": .double(elapsed),
            ])
            let summary = ToolEventSummary(
                targetApp: target.appIdentifier,
                windowTitle: resolvedWindowTitle,
                actionDescription: "Press",
                waitDurationMs: Double(hold),
                notes: display.joined(separator: " → "))
            return ToolResponse.text(message, meta: ToolEventSummary.merge(summary: summary, into: meta))
        } catch let error as MCPInteractionTargetError {
            return ToolResponse.error(error.localizedDescription)
        } catch let error as InputDeliveryIndeterminateError {
            return ToolResponse.error(
                error.localizedDescription,
                meta: .object([
                    "mutation_dispatched": .bool(true),
                    "retry_safe": .bool(false),
                    "requires_fresh_observation": .bool(true),
                    "emitted_units": error.emittedUnitCount.map(Value.int) ?? .null,
                ]))
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
}
