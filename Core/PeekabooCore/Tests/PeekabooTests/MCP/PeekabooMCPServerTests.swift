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

        #expect(names.count == 26)
        #expect(names == names.sorted())
        #expect(names.contains("capture"))
        #expect(names.contains("image"))
        #expect(names.contains("inspect_ui"))
        #expect(names.contains("verify_state"))
        #expect(names.contains("click"))
        #expect(names.contains("clipboard"))
        #expect(names.contains("paste"))
        #expect(names.contains("set_value"))
        #expect(names.contains("action"))
        #expect(names.contains("press"))
        #expect(!names.contains("hotkey"))
        #expect(!names.contains("swipe"))
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
    func `server projects bounded capture failure metadata onto the MCP wire`() throws {
        let response = ToolResponse.error(
            "Video capture produced no decodable frames.",
            meta: .object([
                "decode_failures": .int(3),
                "effect": .string("partial"),
                "error_code": .string("CAPTURE_NO_VALID_FRAMES"),
                "first_decode_error": .string("first"),
                "internal_diagnostics": .string("private"),
                "mutation_dispatched": .bool(true),
                "retry_safe": .bool(false),
                "source": .string("video"),
            ]))

        let result = PeekabooMCPServer.callToolResult(from: response, toolName: "capture")
        let data = try JSONEncoder().encode(result)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metadata = try #require(json["_meta"] as? [String: Any])

        #expect(metadata["error_code"] as? String == "CAPTURE_NO_VALID_FRAMES")
        #expect(metadata["effect"] as? String == "partial")
        #expect(metadata["mutation_dispatched"] as? Bool == true)
        #expect(metadata["retry_safe"] as? Bool == false)
        #expect(metadata["decode_failures"] as? Int == 3)
        #expect(metadata["source"] as? String == "video")
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
        #expect(!names.contains("action"))
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
