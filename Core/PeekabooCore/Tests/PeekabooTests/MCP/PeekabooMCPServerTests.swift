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
    @MainActor
    func `click wire schema requires an exclusive target and a background coordinate receipt`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let session = try await ClickMCPWireSession.connect(context: context)

        do {
            let (tools, _) = try await session.client.listTools()
            let click = try #require(tools.first { $0.name == "click" })
            guard case let .object(schema) = click.inputSchema,
                  case let .object(properties)? = schema["properties"],
                  case let .array(routes)? = schema["oneOf"]
            else {
                Issue.record("click wire schema is missing its target routes")
                await session.stop()
                return
            }

            #expect(Set(routes.compactMap(Self.requiredFields)) == Set([["on"], ["query"], ["coords"]]))
            for route in routes {
                let required = try #require(Self.requiredFields(route)?.first)
                #expect(Self.excludedTargetFields(route) == Set(["on", "query", "coords"]).subtracting([required]))
            }

            let coordinateRoute = try #require(routes.first { Self.requiredFields($0) == ["coords"] })
            guard case let .object(coordinateFields) = coordinateRoute,
                  case let .array(coordinateAlternatives)? = coordinateFields["anyOf"]
            else {
                Issue.record("coordinate route is missing receipt and foreground alternatives")
                await session.stop()
                return
            }

            #expect(coordinateAlternatives.count == 4)
            #expect(coordinateAlternatives.contains { Self.requiredFields($0) == ["snapshot"] })
            #expect(coordinateAlternatives.contains { Self.requiredFields($0) == ["coordinate_reference"] })
            #expect(Self.hasRequiredBooleanConstant(
                name: "foreground",
                value: true,
                in: coordinateAlternatives))
            #expect(Self.hasRequiredBooleanConstant(
                name: "background",
                value: false,
                in: coordinateAlternatives))

            guard case let .object(snapshotSchema)? = properties["snapshot"],
                  case let .object(referenceSchema)? = properties["coordinate_reference"],
                  case let .object(pidSchema)? = properties["pid"]
            else {
                Issue.record("click receipt properties are missing")
                await session.stop()
                return
            }
            #expect(snapshotSchema["minLength"] == .int(1))
            #expect(referenceSchema["minLength"] == .int(1))
            #expect(pidSchema["type"] == .string("integer"))
            #expect(pidSchema["minimum"] == .int(1))
            for field in ["on", "query", "coords"] {
                guard case let .object(targetSchema)? = properties[field] else {
                    Issue.record("click target property \(field) is missing")
                    continue
                }
                #expect(targetSchema["minLength"] == .int(1))
            }
            #expect(click.description?.contains("pid alone is never a safe coordinate target") == true)
        } catch {
            await session.stop()
            throw error
        }

        await session.stop()
    }

    @Test
    @MainActor
    func `click wire refuses mixed target routes before dispatch`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        let session = try await ClickMCPWireSession.connect(context: context)
        let invalidArguments: [[String: Value]] = [
            ["on": .string("B1"), "query": .string("Save")],
            ["on": .string("B1"), "coords": .string("10,20"), "foreground": .bool(true)],
            ["query": .string("Save"), "coords": .string("10,20"), "foreground": .bool(true)],
            [
                "on": .string("B1"),
                "query": .string("Save"),
                "coords": .string("10,20"),
                "foreground": .bool(true),
            ],
        ]

        do {
            for arguments in invalidArguments {
                let request: RequestContext<CallTool.Result> = try await session.client.callTool(
                    name: "click",
                    arguments: arguments)
                let result = try await request.value
                #expect(result.isError == true)
            }
            #expect(automation.clickCalls.isEmpty)
            #expect(automation.targetedClickCalls.isEmpty)
        } catch {
            await session.stop()
            throw error
        }

        await session.stop()
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
    func `server projects incomplete Accessibility metadata without an effect`() throws {
        let response = ToolResponse.error(
            "AX tree incomplete.",
            meta: .object([
                "error_code": .string("ACCESSIBILITY_INCOMPLETE"),
                "mutation_dispatched": .bool(false),
                "retry_safe": .bool(true),
            ]))

        let result = PeekabooMCPServer.callToolResult(from: response, toolName: "inspect_ui")
        let data = try JSONEncoder().encode(result)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metadata = try #require(json["_meta"] as? [String: Any])

        #expect(metadata["error_code"] as? String == "ACCESSIBILITY_INCOMPLETE")
        #expect(metadata["mutation_dispatched"] as? Bool == false)
        #expect(metadata["retry_safe"] as? Bool == true)
        #expect(metadata["effect"] == nil)
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

    private static func requiredFields(_ schema: Value) -> Set<String>? {
        guard case let .object(fields) = schema,
              case let .array(required)? = fields["required"]
        else { return nil }
        return Set(required.compactMap(\.stringValue))
    }

    private static func excludedTargetFields(_ schema: Value) -> Set<String>? {
        guard case let .object(fields) = schema,
              case let .object(notSchema)? = fields["not"],
              case let .array(alternatives)? = notSchema["anyOf"]
        else { return nil }
        return Set(alternatives.flatMap { Self.requiredFields($0) ?? [] })
    }

    private static func hasRequiredBooleanConstant(
        name: String,
        value: Bool,
        in schemas: [Value]) -> Bool
    {
        schemas.contains { schema in
            guard Self.requiredFields(schema) == [name],
                  case let .object(fields) = schema,
                  case let .object(properties)? = fields["properties"],
                  case let .object(property)? = properties[name]
            else { return false }
            return property["const"] == .bool(value)
        }
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

private struct ClickMCPWireSession {
    let client: Client
    let server: PeekabooMCPServer

    static func connect(context: MCPToolContext) async throws -> Self {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = try await PeekabooMCPServer(toolContext: context)
        let client = Client(name: "PeekabooClickWireTests", version: "1.0")
        try await server.startForTesting(transport: serverTransport)
        do {
            _ = try await client.connect(transport: clientTransport)
        } catch {
            await client.disconnect()
            await server.stopForTesting()
            throw error
        }
        return Self(client: client, server: server)
    }

    func stop() async {
        await self.client.disconnect()
        await self.server.stopForTesting()
    }
}

@MainActor
private func makeServer() async throws -> PeekabooMCPServer {
    let services = PeekabooServices()
    return try await PeekabooMCPServer(toolContext: MCPToolContext(services: services))
}
