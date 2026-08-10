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
    private let server: Server
    private let toolRegistry: MCPToolRegistry
    private let logger: os.Logger
    private let toolContext: MCPToolContext
    private let serverName = PeekabooMCPVersion.serverName
    private let serverVersion = PeekabooMCPVersion.current

    public init() async throws {
        self.logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "server")
        self.toolRegistry = await MCPToolRegistry()
        self.toolContext = try await MainActor.run { try MCPToolContext.makeDefaultIfConfigured() }
        self.server = Self.makeServer(name: PeekabooMCPVersion.serverName, version: PeekabooMCPVersion.current)

        await self.setupHandlers()
        await self.registerAllTools()
    }

    public init(toolContext: MCPToolContext) async throws {
        self.logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "server")
        self.toolRegistry = await MCPToolRegistry()
        self.toolContext = toolContext
        self.server = Self.makeServer(name: PeekabooMCPVersion.serverName, version: PeekabooMCPVersion.current)

        await self.setupHandlers()
        await self.registerAllTools()
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
        await self.server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else {
                throw MCP.MCPError.methodNotFound("Server deallocated")
            }

            guard let tool = await self.toolRegistry.tool(named: params.name) else {
                throw MCP.MCPError.invalidParams("Tool '\(params.name)' not found")
            }

            let arguments = ToolArguments(value: .object(params.arguments ?? [:]))

            // Execute tool on main thread
            let response = try await self.toolContext.execute(tool: tool, arguments: arguments)

            return Self.callToolResult(from: response, toolName: params.name)
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

    static func callToolResult(from response: ToolResponse, toolName: String? = nil) -> CallTool.Result {
        let fields = MCPToolResponseMetadataProjector.externalFields(from: response.meta, toolName: toolName)
        let metadata = fields.isEmpty ? nil : Metadata(additionalFields: fields)

        return CallTool.Result(
            content: response.content,
            isError: response.isError,
            _meta: metadata)
    }

    private func registerAllTools() async {
        let context = self.toolContext

        let filters = ToolFiltering.currentFilters()
        let logger = self.logger
        let inputPolicy = await self.runtimeInputPolicy()
        let nativeTools = await MainActor.run {
            MCPToolCatalog.tools(
                context: context,
                inputPolicy: inputPolicy,
                filters: filters,
                log: { message in
                    logger.notice("\(message, privacy: .public)")
                })
        }

        await self.toolRegistry.register(nativeTools)

        let toolCount = await self.toolRegistry.allTools().count
        self.logger.info("Registered \(toolCount) tools")
    }

    private func runtimeInputPolicy() async -> UIInputPolicy {
        await MainActor.run {
            if let automation = self.toolContext.automation as? UIAutomationService {
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

    public func serve(transport: TransportType, port: Int = 8080) async throws {
        self.logger.info("Starting Peekaboo MCP server on \(transport) transport, version: \(self.serverVersion)")

        let serverTransport: any Transport

        switch transport {
        case .stdio:
            serverTransport = EOFDrainingTransport(wrapping: StdioTransport())

        case .http:
            // Note: HTTP transport would need custom implementation
            // as the SDK only provides HTTPClientTransport
            throw MCPError.notImplemented("HTTP server transport not yet implemented")

        case .sse:
            throw MCPError.notImplemented("SSE server transport not yet implemented")
        }

        try await self.server.start(transport: serverTransport)

        // Keep the server running
        await self.server.waitUntilCompleted()
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
