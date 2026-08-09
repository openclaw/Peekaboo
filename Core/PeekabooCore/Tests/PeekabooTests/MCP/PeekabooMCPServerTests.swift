import Foundation
import MCP
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooVisualizer

@Suite(.serialized)
struct PeekabooMCPServerTests {
    private static let missingFactoryMessage =
        "MCPToolContext default factory not configured. Call configureDefaultContext(using:)."

    @Test
    func `server initializes with native MCP tool catalog`() async throws {
        let server = try await makeServer()
        let names = await server.registeredToolNamesForTesting()

        #expect(names.count == 28)
        #expect(names == names.sorted())
        #expect(names.contains("capture"))
        #expect(names.contains("image"))
        #expect(names.contains("inspect_ui"))
        #expect(names.contains("verify_state"))
        #expect(names.contains("click"))
        #expect(names.contains("clipboard"))
        #expect(names.contains("paste"))
        #expect(names.contains("set_value"))
        #expect(names.contains("perform_action"))
    }

    @Test
    func `server preserves tool response metadata on the MCP wire result`() throws {
        let response = ToolResponse.text(
            "Captured image",
            meta: .object([
                "coordinate_context": .object([
                    "version": .int(1),
                    "logical_space": .string("global_display_points"),
                ]),
                "internal_diagnostics": .string("not part of the public MCP contract"),
            ]))

        let result = PeekabooMCPServer.callToolResult(from: response)
        let encoded = try JSONEncoder().encode(result)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let metadata = try #require(json["_meta"] as? [String: Any])
        let coordinateContext = try #require(metadata["coordinate_context"] as? [String: Any])

        #expect(coordinateContext["version"] as? Int == 1)
        #expect(coordinateContext["logical_space"] as? String == "global_display_points")
        #expect(metadata["internal_diagnostics"] == nil)
    }

    @Test
    @MainActor
    func `server filters action-only tools with runtime input policy`() async throws {
        let services = PeekabooServices(inputPolicy: UIInputPolicy(
            defaultStrategy: .synthOnly,
            setValue: .synthOnly,
            performAction: .synthOnly))

        let server = try await PeekabooMCPServer(toolContext: MCPToolContext(services: services))
        let names = await server.registeredToolNamesForTesting()

        #expect(!names.contains("set_value"))
        #expect(!names.contains("perform_action"))
    }

    @Test
    @MainActor
    func `default server context inherits the installed agent execution gate`() async throws {
        let services = PeekabooServices()
        services.agent = nil
        services.installAgentRuntimeDefaults()
        let firstFallbackContext = MCPToolContext.makeDefault()
        let secondFallbackContext = MCPToolContext.makeDefault()
        let gate = MCPToolSnapshotExecutionGate()
        let agent = try PeekabooAgentService(
            services: services,
            snapshotExecutionGate: gate)
        services.agent = agent

        let defaultContext = MCPToolContext.makeDefault()
        let server = try await PeekabooMCPServer()

        #expect(firstFallbackContext.snapshotExecutionGate === secondFallbackContext.snapshotExecutionGate)
        #expect(firstFallbackContext.snapshotExecutionGate !== gate)
        #expect(defaultContext.snapshotExecutionGate === gate)
        #expect(await server.snapshotExecutionGateForTesting() === gate)
    }

    @Test
    @MainActor
    func `makeDefaultIfConfigured throws when factory is missing`() async {
        await MCPToolContext.withDefaultContextFactoryForTesting(nil) {
            let error = #expect(throws: PeekabooError.self) {
                _ = try MCPToolContext.makeDefaultIfConfigured()
            }
            guard case let .operationError(message) = error else {
                Issue.record("expected operationError, got \(String(describing: error))")
                return
            }
            #expect(message == Self.missingFactoryMessage)
        }
    }

    @Test
    @MainActor
    func `server init throws when default factory is unconfigured`() async {
        await MCPToolContext.withDefaultContextFactoryForTesting(nil) {
            let error = await #expect(throws: PeekabooError.self) {
                _ = try await PeekabooMCPServer()
            }
            guard case let .operationError(message) = error else {
                Issue.record("expected operationError, got \(String(describing: error))")
                return
            }
            #expect(message == Self.missingFactoryMessage)
        }
    }
}

@MainActor
private func makeServer() async throws -> PeekabooMCPServer {
    let services = PeekabooServices()
    return try await PeekabooMCPServer(toolContext: MCPToolContext(services: services))
}
