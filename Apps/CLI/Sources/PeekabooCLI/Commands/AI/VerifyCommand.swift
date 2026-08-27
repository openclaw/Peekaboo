import Commander
import Foundation
import MCP
import PeekabooCore
import TachikomaMCP

@MainActor
struct VerifyCommand: ErrorHandlingCommand, OutputFormattable, RuntimeBackedCommand {
    @OptionGroup var target: InteractionTargetOptions
    @Flag(help: "Require the target window to exist") var windowExists = false
    @Option(help: "Expected window bounds x,y,width,height[,tolerance]") var windowBounds: String?
    @Option(help: "Element ID or role:label query") var on: String?
    @Flag(help: "Require the selected element to exist") var exists = false
    @Option(help: "Expected selected-element value") var valueEquals: String?
    @Flag(help: "Require the selected element to be enabled") var enabled = false
    @Flag(help: "Require the selected element to be selected") var selected = false
    @Option(help: "Polling timeout (bare values are milliseconds; maximum 10s)")
    var timeout: CLIDuration = .seconds(5)
    @Option(help: "Consecutive identical satisfied samples required") var stableSamples = 2
    @Option(help: "Save the final exact-window screenshot") var screenshot: String?
    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    static let commandDescription = CommandDescription(
        commandName: "verify",
        abstract: "Verify window and element state without UI interaction",
        discussion: """
        Poll fresh native state until every predicate is stable. This replaces sleep-based polling.
        Results are satisfied, unsatisfied, or unknown; unknown never implies success.

        Examples:
          peekaboo verify --app Safari --window-exists
          peekaboo verify --app Safari --on button:Reload --exists --enabled --json
        """
    )

    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)

        do {
            let arguments = try await self.makeArguments()
            let context = Self.makeToolContext(using: runtime)
            let tool = VerifyStateTool(context: context)
            let response = try await context.execute(tool: tool, arguments: ToolArguments(raw: arguments))
            guard !response.isError else {
                try MCPToolCommandOutput.output(
                    tool: tool.name,
                    response: response,
                    jsonOutput: self.jsonOutput,
                    logger: self.outputLogger,
                    errorExitCode: ExitCode(2)
                )
                throw ExitCode(2)
            }

            let screenshotPath = try self.saveScreenshot(from: response)
            let result = try Self.resultMetadata(response: response, screenshotPath: screenshotPath)
            if self.jsonOutput {
                outputSuccessCodable(data: result.payload, logger: self.outputLogger)
            } else {
                for content in response.content {
                    if case let .text(text, _, _) = content {
                        print(text)
                    }
                }
                if let screenshotPath {
                    print("Screenshot: \(screenshotPath)")
                }
                if let screenshotError = result.screenshotError {
                    print("Screenshot error: \(screenshotError)")
                }
            }

            switch result.status {
            case "satisfied": return
            case "unsatisfied": throw ExitCode(1)
            default: throw ExitCode(2)
            }
        } catch let exit as ExitCode {
            throw exit
        } catch {
            self.handleError(error)
            throw ExitCode(2)
        }
    }

    static func makeToolContext(using runtime: CommandRuntime) -> MCPToolContext {
        MCPToolContext(
            services: runtime.services,
            snapshotMutationCoordinator: runtime.toolSnapshotMutationCoordinator,
            capturePreflightRefusal: runtime.toolCapturePreflightRefusal
        )
    }

    private func makeArguments() async throws -> [String: Any] {
        let target = self.target
        try target.validate()

        var arguments: [String: Any] = try [
            "predicates": self.predicates(),
            "timeout_ms": self.timeout.roundedMilliseconds,
            "stable_samples": self.stableSamples,
            "final_screenshot": self.screenshot != nil,
        ]

        if let explicitPID = try target.resolveExplicitPIDObservationTarget() ?? target.pid {
            arguments["pid"] = Int(explicitPID)
        } else if let app = target.app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
            arguments["app"] = app
        } else if let windowID = target.windowId {
            let windows = try await self.services.windows.listWindows(target: .windowId(windowID))
            guard let pid = windows.first?.mutationIdentity?.ownerProcessIdentifier else {
                throw ValidationError("--window-id alone must resolve a live owner; add --app or --pid")
            }
            arguments["pid"] = Int(pid)
        } else {
            throw ValidationError("Provide --app, --pid, or a live --window-id")
        }

        if let windowID = target.windowId {
            arguments["window_id"] = windowID
        }
        if let windowTitle = target.windowTitle {
            arguments["window_title"] = windowTitle
        }
        if let windowIndex = target.windowIndex {
            arguments["window_index"] = windowIndex
        }
        return arguments
    }

    private func predicates() throws -> [[String: Any]] {
        var predicates: [[String: Any]] = []
        if self.windowExists {
            predicates.append(["kind": "window_exists", "expected": true])
        }
        if let windowBounds {
            try predicates.append(Self.boundsPredicate(windowBounds))
        }

        let hasElementPredicate = self.exists || self.valueEquals != nil || self.enabled || self.selected
        if hasElementPredicate {
            guard let on else { throw ValidationError("Element predicates require --on") }
            let selector = try Self.elementSelector(on)
            if self.exists {
                predicates.append(["kind": "element_exists", "selector": selector, "expected": true])
            }
            if let valueEquals {
                predicates.append(["kind": "element_value", "selector": selector, "expected_value": valueEquals])
            }
            if self.enabled {
                predicates.append(["kind": "element_enabled", "selector": selector, "expected": true])
            }
            if self.selected {
                predicates.append(["kind": "element_selected", "selector": selector, "expected": true])
            }
        } else if self.on != nil {
            throw ValidationError("--on requires --exists, --value-equals, --enabled, or --selected")
        }

        guard !predicates.isEmpty else { throw ValidationError("Specify at least one verification predicate") }
        return predicates
    }

    static func elementSelector(_ raw: String) throws -> [String: String] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ValidationError("--on must not be empty") }
        guard let separator = query.firstIndex(of: ":") else { return ["identifier": query] }
        let role = query[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let label = query[query.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !role.isEmpty, !label.isEmpty else {
            throw ValidationError("Role queries use role:label, for example button:Save")
        }
        return ["role": role, "label": label]
    }

    static func boundsPredicate(_ raw: String) throws -> [String: Any] {
        let values = raw.split(separator: ",", omittingEmptySubsequences: false).map {
            Double($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard (4...5).contains(values.count), values.allSatisfy({ $0 != nil }) else {
            throw ValidationError("--window-bounds requires x,y,width,height[,tolerance]")
        }
        let numbers = values.compactMap(\.self)
        var predicate: [String: Any] = [
            "kind": "window_bounds",
            "bounds": ["x": numbers[0], "y": numbers[1], "width": numbers[2], "height": numbers[3]],
        ]
        if numbers.count == 5 {
            predicate["tolerance"] = numbers[4]
        }
        return predicate
    }

    private func saveScreenshot(from response: ToolResponse) throws -> String? {
        guard let screenshot else { return nil }
        for content in response.content {
            guard case let .image(base64, mimeType, _, _) = content, mimeType == "image/png",
                  let data = Data(base64Encoded: base64)
            else { continue }
            let expanded = (screenshot as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return url.path
        }
        return nil
    }

    private static func resultMetadata(
        response: ToolResponse,
        screenshotPath: String?
    ) throws -> (status: String, payload: Value, screenshotError: String?) {
        guard case let .object(meta)? = response.meta,
              case let .string(status)? = meta["status"],
              case .array? = meta["predicates"]
        else { throw ValidationError("verify_state returned incomplete result metadata") }
        var payload = meta
        payload["unknown_reason"] = status == "unknown" ? meta["reason"] ?? .null : .null
        payload.removeValue(forKey: "reason")
        if let screenshotPath {
            payload["screenshot_path"] = .string(screenshotPath)
        }
        return (status, .object(payload), meta["screenshot_error"]?.stringValue)
    }
}

extension VerifyCommand: ParsableCommand {}
extension VerifyCommand: AsyncRuntimeCommand {}
