import CoreGraphics
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
            #expect(click.description?.contains("pid alone is never a safe coordinate target") == true)
        } catch {
            await session.stop()
            throw error
        }

        await session.stop()
    }

    @Test
    @MainActor
    func `click wire refuses loose background coordinates without dispatch or invalidation`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        let retainedSnapshot = await UISnapshotManager.shared.createSnapshot()
        let retainedSnapshotID = await retainedSnapshot.id
        let session = try await ClickMCPWireSession.connect(context: context)
        let invalidArguments: [[String: Value]] = [
            ["coords": .string("100,200")],
            ["coords": .string("100,200"), "pid": .int(111)],
            ["coords": .string("100,200"), "pid": .int(111), "snapshot": .string("")],
        ]

        do {
            for arguments in invalidArguments {
                let request: RequestContext<CallTool.Result> = try await session.client.callTool(
                    name: "click",
                    arguments: arguments)
                let result = try await request.value
                #expect(result.isError == true)
                #expect(result._meta?["mutation_dispatched"] == .bool(false))
                #expect(result._meta?["retry_safe"] == .bool(true))
                guard case let .text(text, _, _)? = result.content.first else {
                    Issue.record("expected a click refusal over the MCP wire")
                    continue
                }
                #expect(text.contains("exact target window"))
                #expect(text.contains("PID-only"))
            }

            #expect(automation.clickCalls.isEmpty)
            #expect(automation.targetedClickCalls.isEmpty)
            #expect(await UISnapshotManager.shared.getSnapshot(id: nil)?.id == retainedSnapshotID)
        } catch {
            await session.stop()
            throw error
        }

        await session.stop()
    }

    @Test
    @MainActor
    func `click wire sends an exact background receipt and preserves explicit foreground coordinates`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = MockAutomationService(accessibilityGranted: true)
        let bounds = CGRect(x: 100, y: 50, width: 1000, height: 500)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 111,
            ownerProcessStartIdentity: 7,
            capturedBounds: bounds)
        let window = ServiceWindowInfo(
            windowID: 42,
            title: "Wire Coordinate Window",
            bounds: bounds,
            index: 0,
            mutationIdentity: identity)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: PointerPolicyWindowService(window: window))
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotID = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/wire-coordinate-snapshot.png",
            metadata: CaptureMetadata(
                size: bounds.size,
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 111,
                    bundleIdentifier: "com.example.wire",
                    name: "WireApp"),
                windowInfo: window))
        let session = try await ClickMCPWireSession.connect(context: context)

        do {
            let backgroundRequest: RequestContext<CallTool.Result> = try await session.client.callTool(
                name: "click",
                arguments: [
                    "coords": .string("300,200"),
                    "coordinate_reference": .string(snapshotID),
                ])
            let background = try await backgroundRequest.value
            #expect(background.isError != true)
            #expect(background._meta?["mutation_dispatched"] == .bool(true))
            let targeted = try #require(automation.targetedClickCalls.first)
            #expect(targeted.snapshotId == snapshotID)
            #expect(targeted.targetProcessIdentifier == 111)
            #expect(targeted.targetWindowID == 42)
            guard case let .coordinates(point) = targeted.target else {
                Issue.record("expected an exact coordinate request")
                await session.stop()
                return
            }
            #expect(point == CGPoint(x: 300, y: 200))

            let foreground = try await session.client.callTool(name: "click", arguments: [
                "coords": .string("25,30"),
                "foreground": .bool(true),
            ])
            #expect(foreground.isError != true)
            guard case let .coordinates(foregroundPoint) = try #require(automation.clickCalls.last).target else {
                Issue.record("expected a foreground coordinate request")
                await session.stop()
                return
            }
            #expect(foregroundPoint == CGPoint(x: 25, y: 30))
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
