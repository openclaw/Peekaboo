import Foundation
import MCP
import os.log
import PeekabooAutomation
import TachikomaMCP

/// Transport types supported by the MCP server
public enum TransportType: CustomStringConvertible, Sendable {
    case stdio
    case http
    case sse

    public nonisolated var description: String {
        switch self {
        case .stdio: "stdio"
        case .http: "http"
        case .sse: "sse"
        }
    }
}

/// Peekaboo MCP Server implementation
public actor PeekabooMCPServer {
    @TaskLocal private static var toolCallServingGeneration: UUID?

    private enum StrictCallTool: MCP.Method {
        typealias Parameters = Value
        typealias Result = CallTool.Result

        static let name = CallTool.name
    }

    private struct ToolCallRequest {
        let name: String
        let arguments: [String: Value]

        init(params: Value) throws {
            guard case let .object(fields) = params else {
                throw MCP.MCPError.invalidParams("tools/call params must be an object")
            }
            guard case let .string(name)? = fields["name"], !name.isEmpty else {
                throw MCP.MCPError.invalidParams("tools/call requires a nonempty string name")
            }
            self.name = name

            switch fields["arguments"] {
            case nil:
                self.arguments = [:]
            case let .object(arguments):
                self.arguments = arguments
            default:
                throw MCP.MCPError.invalidParams("Tool '\(name)' arguments must be an object")
            }
        }
    }

    private let server: Server
    private let toolRegistry: MCPToolRegistry
    private let logger: os.Logger
    private let toolContext: MCPToolContext
    private var servingGeneration: UUID?
    private var startupTask: Task<Void, any Error>?
    private var shutdownTask: Task<Void, Never>?
    private var acceptsToolCalls = false
    private var activeToolCalls: [UUID: Task<CallTool.Result, any Error>] = [:]
    private let serverName = PeekabooMCPVersion.serverName
    private let serverVersion = PeekabooMCPVersion.current

    public init(
        browserHandoff: BrowserMCPHandoffGrant? = nil,
        toolFilters: ToolFilters = ToolFiltering.currentFilters()) async throws
    {
        self.logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "server")
        self.toolRegistry = await MCPToolRegistry()
        let context = try await MainActor.run {
            try MCPToolContext.makeDefaultIfConfigured()
        }
        let prepared = try await Self.prepareToolContext(
            context,
            browserHandoff: browserHandoff,
            toolFilters: toolFilters,
            logger: self.logger)
        self.toolContext = prepared.context
        self.server = Self.makeServer(name: PeekabooMCPVersion.serverName, version: PeekabooMCPVersion.current)

        await self.setupHandlers()
        await self.registerAllTools(selection: prepared.selection)
    }

    public init(
        toolContext: MCPToolContext,
        browserHandoff: BrowserMCPHandoffGrant? = nil,
        toolFilters: ToolFilters = ToolFiltering.currentFilters()) async throws
    {
        self.logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "server")
        self.toolRegistry = await MCPToolRegistry()
        let prepared = try await Self.prepareToolContext(
            toolContext,
            browserHandoff: browserHandoff,
            toolFilters: toolFilters,
            logger: self.logger)
        self.toolContext = prepared.context
        self.server = Self.makeServer(name: PeekabooMCPVersion.serverName, version: PeekabooMCPVersion.current)

        await self.setupHandlers()
        await self.registerAllTools(selection: prepared.selection)
    }

    private static func prepareToolContext(
        _ context: MCPToolContext,
        browserHandoff: BrowserMCPHandoffGrant?,
        toolFilters: ToolFilters,
        logger: os.Logger) async throws -> (context: MCPToolContext, selection: MCPToolCatalog.Selection)
    {
        let inputPolicy = await self.runtimeInputPolicy(for: context)
        let selection = await MainActor.run {
            MCPToolCatalog.selection(
                context: context,
                inputPolicy: inputPolicy,
                filters: toolFilters,
                log: { message in
                    logger.notice("\(message, privacy: .public)")
                })
        }
        let browserContext = if selection.contains("browser") || browserHandoff != nil {
            try await context.openingBrowserSession(
                named: "mcp:\(UUID().uuidString.lowercased())",
                handoff: browserHandoff)
        } else {
            context
        }
        return (
            browserContext.replacingSnapshotOwner(with: MCPToolSnapshotOwner()),
            selection)
    }

    private static func makeServer(name: String, version: String) -> Server {
        // Initialize the official MCP Server
        Server(
            name: name,
            version: version,
            capabilities: Server.Capabilities(
                prompts: .init(listChanged: false),
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: true)))
    }

    private func setupHandlers() async {
        // Tool list handler
        await self.server.withMethodHandler(ListTools.self) { [weak self] _ in
            guard let self else { return ListTools.Result(tools: []) }

            let tools = await self.toolRegistry.toolInfos()
            return ListTools.Result(tools: tools)
        }

        // Tool call handler
        await self.server.withMethodHandler(StrictCallTool.self) { [weak self] params in
            guard let self else {
                throw MCP.MCPError.methodNotFound("Server deallocated")
            }

            guard let generation = Self.toolCallServingGeneration else {
                throw MCP.MCPError.internalError("MCP request has no serving lifetime")
            }
            return try await self.handleToolCall(params, generation: generation)
        }

        // Resources list handler (empty for now, but prevents inspector errors)
        await self.server.withMethodHandler(ListResources.self) { _ in
            // Return empty resources list
            ListResources.Result(resources: [], nextCursor: nil)
        }

        // Resources read handler (returns error for now)
        await self.server.withMethodHandler(ReadResource.self) { params in
            throw MCP.MCPError.invalidParams("Resource '\(params.uri)' not found")
        }

        // Initialize handler
        await self.server.withMethodHandler(Initialize.self) { [weak self] request in
            guard let self else {
                throw MCP.MCPError.methodNotFound("Server deallocated")
            }

            let clientDescription = "\(request.clientInfo.name) \(request.clientInfo.version)"
            let protocolVersion = request.protocolVersion
            self.logger.info(
                """
                Client connected: \(clientDescription, privacy: .public), \
                protocol: \(protocolVersion, privacy: .public)
                """)

            // Create a response struct that matches Initialize.Result
            struct InitializeResult: Codable {
                let protocolVersion: String
                let capabilities: Server.Capabilities
                let serverInfo: Server.Info
                let instructions: String?
            }

            let result = await InitializeResult(
                protocolVersion: "2024-11-05",
                capabilities: self.server.capabilities,
                serverInfo: Server.Info(
                    name: self.serverName,
                    version: self.serverVersion),
                instructions: nil)

            // Convert to Initialize.Result via JSON
            let data = try JSONEncoder().encode(result)
            return try JSONDecoder().decode(Initialize.Result.self, from: data)
        }
    }

    private func handleToolCall(_ parameters: Value, generation: UUID) async throws -> CallTool.Result {
        guard self.acceptsToolCalls, self.servingGeneration == generation else {
            throw MCP.MCPError.internalError("MCP server is shutting down")
        }
        let id = UUID()
        let execution = Task { try await self.executeToolCall(parameters) }
        self.activeToolCalls[id] = execution
        defer { self.activeToolCalls[id] = nil }
        return try await withTaskCancellationHandler {
            try await execution.value
        } onCancel: {
            execution.cancel()
        }
    }

    private func executeToolCall(_ parameters: Value) async throws -> CallTool.Result {
        try Task.checkCancellation()
        let request = try ToolCallRequest(params: parameters)
        guard let tool = await self.toolRegistry.tool(named: request.name) else {
            throw MCP.MCPError.invalidParams("Tool '\(request.name)' not found")
        }
        try Task.checkCancellation()
        let arguments = ToolArguments(value: .object(request.arguments))
        do {
            try MCPToolArgumentValidator.validateClosedProperties(tool: tool, arguments: arguments)
        } catch let error as MCPToolArgumentSchemaError {
            throw MCP.MCPError.invalidParams(
                "Invalid arguments for tool '\(request.name)': \(error.localizedDescription)")
        }
        let response = try await self.toolContext.execute(tool: tool, arguments: arguments)
        return Self.callToolResult(from: response, toolName: request.name)
    }

    private func startServing(transport: any Transport, generation: UUID) async throws {
        let startup = Task {
            try await Self.$toolCallServingGeneration.withValue(generation) {
                try await self.server.start(transport: transport)
            }
        }
        self.startupTask = startup
        try await startup.value
    }

    private func stopServing(generation: UUID? = nil) async {
        if let generation, self.servingGeneration != generation {
            return
        }
        if let shutdownTask = self.shutdownTask {
            await shutdownTask.value
            return
        }
        self.acceptsToolCalls = false
        let calls = Array(self.activeToolCalls.values)
        for call in calls {
            call.cancel()
        }
        let startup = self.startupTask
        startup?.cancel()
        let shutdown = Task {
            // A cancelled connect can still complete; finish startup before disconnecting its SDK session.
            _ = try? await startup?.value
            await self.server.stop()
            // SDK shutdown does not own incoming tool tasks. Keep their context alive until they drain.
            for call in calls {
                _ = try? await call.value
            }
        }
        self.shutdownTask = shutdown
        await shutdown.value
    }

    static func callToolResult(from response: ToolResponse, toolName: String? = nil) -> CallTool.Result {
        let fields = MCPToolResponseMetadataProjector.externalFields(from: response.meta, toolName: toolName)
        let metadata = fields.isEmpty ? nil : Metadata(additionalFields: fields)

        return CallTool.Result(
            content: response.content,
            isError: response.isError,
            _meta: metadata)
    }

    private func registerAllTools(selection: MCPToolCatalog.Selection) async {
        let context = self.toolContext
        let nativeTools = await MainActor.run {
            MCPToolCatalog.tools(context: context, selection: selection)
        }

        await self.toolRegistry.register(nativeTools)

        let toolCount = await self.toolRegistry.allTools().count
        self.logger.info("Registered \(toolCount) tools")
    }

    private static func runtimeInputPolicy(for context: MCPToolContext) async -> UIInputPolicy {
        await MainActor.run {
            if let automation = context.automation as? UIAutomationService {
                return automation.inputPolicy
            }

            return ConfigurationManager.shared.getUIInputPolicy()
        }
    }

    func registeredToolNamesForTesting() async -> [String] {
        await self.toolRegistry.allTools().map(\.name).sorted()
    }

    func snapshotExecutionGateForTesting() -> MCPToolSnapshotExecutionGate {
        self.toolContext.snapshotExecutionGate
    }

    func snapshotOwnerForTesting() -> MCPToolSnapshotOwner {
        self.toolContext.uiSnapshots.owner
    }

    func browserClientForTesting() -> any BrowserMCPClientProviding {
        self.toolContext.browser
    }

    func startForTesting(transport: any Transport) async throws {
        let generation = UUID()
        self.servingGeneration = generation
        self.acceptsToolCalls = true
        try await self.startServing(transport: transport, generation: generation)
    }

    @discardableResult
    func stopForTesting() async -> Bool {
        await self.stopServing()
        let released = await self.releaseToolContextForTeardown()
        self.servingGeneration = nil
        self.startupTask = nil
        self.shutdownTask = nil
        return released
    }

    private func releaseToolContextForTeardown() async -> Bool {
        var cleanupConfirmed = await self.toolContext.releaseSnapshotOwner()
        if !cleanupConfirmed {
            cleanupConfirmed = await self.toolContext.releaseSnapshotOwner()
        }
        return cleanupConfirmed
    }

    public func serve(transport: TransportType, port: Int = 8080) async throws {
        self.logger.info("Starting Peekaboo MCP server on \(transport) transport, version: \(self.serverVersion)")
        try await self.run {
            switch transport {
            case .stdio:
                EOFDrainingTransport(wrapping: StdioTransport())
            case .http:
                // HTTP transport needs a server implementation; the SDK provides only an HTTP client.
                throw MCPError.notImplemented("HTTP server transport not yet implemented")
            case .sse:
                throw MCPError.notImplemented("SSE server transport not yet implemented")
            }
        }
    }

    /// Serves over a transport supplied by the host process.
    ///
    /// For hosts that embed the server instead of spawning the CLI — an application that
    /// links `PeekabooCore` and speaks MCP over a connection it owns. The lifecycle is the
    /// one `serve(transport:port:)` gives the built-in stdio transport: the server runs
    /// until the transport completes, and the tool context is released on the way out,
    /// on success and on failure alike.
    public func serve(transport: any Transport) async throws {
        self.logger.info("Starting Peekaboo MCP server on a host transport, version: \(self.serverVersion)")
        try await self.run { transport }
    }

    private func run(makingTransport: () throws -> any Transport) async throws {
        guard self.servingGeneration == nil else {
            throw MCPError.executionFailed("MCP server is already serving a transport")
        }
        let generation = UUID()
        self.servingGeneration = generation
        self.acceptsToolCalls = true
        defer {
            self.servingGeneration = nil
            self.startupTask = nil
            self.shutdownTask = nil
        }
        do {
            let serverTransport = try makingTransport()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await self.startServing(transport: serverTransport, generation: generation)
                try Task.checkCancellation()
                await self.server.waitUntilCompleted()
                try Task.checkCancellation()
            } onCancel: {
                Task { await self.stopServing(generation: generation) }
            }
        } catch {
            await self.stopServing(generation: generation)
            let cleanupConfirmed = await self.releaseToolContextForTeardown()
            if !cleanupConfirmed {
                self.logger.error("Browser session cleanup remains pending after MCP server failure")
            }
            throw error
        }
        await self.stopServing(generation: generation)
        let cleanupConfirmed = await self.releaseToolContextForTeardown()
        guard cleanupConfirmed else {
            throw MCPError.executionFailed(
                "Browser session cleanup remains pending after MCP server teardown")
        }
    }
}

// MARK: - Supporting Types

public enum MCPError: LocalizedError {
    case notImplemented(String)
    case toolNotFound(String)
    case invalidArguments(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .notImplemented(feature):
            "\(feature) is not yet implemented"
        case let .toolNotFound(tool):
            "Tool '\(tool)' not found"
        case let .invalidArguments(details):
            "Invalid arguments: \(details)"
        case let .executionFailed(message):
            "Execution failed: \(message)"
        }
    }
}
