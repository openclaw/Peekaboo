import Commander
import Foundation
import PeekabooCore
import TachikomaMCP

@MainActor
struct InspectUICommand: ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable {
    var appTarget: String?
    var snapshot: String?
    var maxDepth: Int?
    var maxElements: Int?
    var maxChildren: Int?

    var runtimeOptions: CommandRuntimeOptions = {
        var options = CommandRuntimeOptions()
        options.requiresInspectAccessibilityTree = true
        return options
    }()

    @RuntimeStorage private var runtime: CommandRuntime?

    static let commandDescription = CommandDescription(
        commandName: "inspect-ui",
        abstract: "Inspect accessible UI text through the inspect_ui MCP tool",
        discussion: """
        Dedicated CLI wrapper around Peekaboo's inspect_ui MCP tool. Use this for
        accessibility-tree text inspection when `see` screenshots are too broad.

        Examples:
          peekaboo inspect-ui --app TextEdit
          peekaboo inspect-ui --snapshot 1234 --max-elements 200 --json
        """
    )

    private var resolvedRuntime: CommandRuntime {
        guard let runtime else {
            preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
        }
        return runtime
    }

    private var services: any PeekabooServiceProviding {
        self.resolvedRuntime.services
    }

    private var logger: Logger {
        self.resolvedRuntime.logger
    }

    var jsonOutput: Bool {
        self.resolvedRuntime.configuration.jsonOutput
    }

    var outputLogger: Logger {
        self.logger
    }

    mutating func setRuntimeOptions(_ options: CommandRuntimeOptions) {
        var options = options
        options.requiresInspectAccessibilityTree = true
        self.runtimeOptions = options
    }

    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)

        do {
            let context = MCPToolContext(
                services: self.services,
                snapshotMutationCoordinator: runtime.toolSnapshotMutationCoordinator
            )
            let tool = InspectUITool(context: context)
            let response = try await context.execute(
                tool: tool,
                arguments: ToolArguments(raw: self.arguments())
            )
            try MCPToolCommandOutput.output(
                tool: tool.name,
                response: response,
                jsonOutput: self.jsonOutput,
                logger: self.outputLogger
            )
        } catch let exit as ExitCode {
            throw exit
        } catch {
            self.handleError(error)
            throw ExitCode(1)
        }
    }

    private func arguments() -> [String: Any] {
        var arguments: [String: Any] = [:]
        self.add(self.appTarget, as: "app_target", to: &arguments)
        self.add(self.snapshot, as: "snapshot", to: &arguments)
        self.add(self.maxDepth, as: "max_depth", to: &arguments)
        self.add(self.maxElements, as: "max_elements", to: &arguments)
        self.add(self.maxChildren, as: "max_children", to: &arguments)
        return arguments
    }

    private func add(_ value: String?, as key: String, to arguments: inout [String: Any]) {
        guard let value, !value.isEmpty else { return }
        arguments[key] = value
    }

    private func add(_ value: Int?, as key: String, to arguments: inout [String: Any]) {
        guard let value else { return }
        arguments[key] = value
    }
}

extension InspectUICommand: ParsableCommand {}
extension InspectUICommand: AsyncRuntimeCommand {}

extension InspectUICommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption("app", help: "App name, bundle ID, PID, or frontmost", long: "app"),
                .commandOption("appTarget", help: "Legacy alias for --app", long: "app-target"),
                .commandOption("snapshot", help: "Existing UI snapshot ID", long: "snapshot"),
                .commandOption("maxDepth", help: "Maximum accessibility-tree depth", long: "max-depth"),
                .commandOption("maxElements", help: "Maximum elements to inspect", long: "max-elements"),
                .commandOption("maxChildren", help: "Maximum children per node", long: "max-children"),
            ]
        )
    }
}

extension InspectUICommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        let app = values.singleOption("app")
        let legacyAppTarget = values.singleOption("appTarget")
        if app != nil, legacyAppTarget != nil {
            throw ValidationError("Cannot specify both --app and --app-target")
        }
        self.appTarget = app ?? legacyAppTarget
        self.snapshot = values.singleOption("snapshot")
        self.maxDepth = try values.decodeOption("maxDepth", as: Int.self)
        self.maxElements = try values.decodeOption("maxElements", as: Int.self)
        self.maxChildren = try values.decodeOption("maxChildren", as: Int.self)
    }
}
