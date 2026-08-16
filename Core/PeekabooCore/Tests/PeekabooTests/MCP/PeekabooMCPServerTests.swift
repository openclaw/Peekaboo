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
    func `each direct MCP server owns one isolated snapshot namespace`() async throws {
        let first = try await makeServer()
        let second = try await makeServer()
        let firstOwner = await first.snapshotOwnerForTesting()
        let secondOwner = await second.snapshotOwnerForTesting()

        #expect(firstOwner != .legacyProcess)
        #expect(secondOwner != .legacyProcess)
        #expect(firstOwner != secondOwner)
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
    func `server preserves the complete permission snapshot on MCP failures`() throws {
        let response = ToolResponse.error(
            "Accessibility is required.",
            meta: .object([
                "permission_snapshot_available": .bool(true),
                "screen_recording": .bool(true),
                "accessibility": .bool(false),
                "event_synthesizing": .bool(false),
                "required_permissions_granted": .bool(false),
                "event_synthesizing_limits": .array([
                    .string("background keyboard input"),
                    .string("foreground synthetic pointer input"),
                ]),
                "internal_diagnostics": .string("private"),
            ]))

        let result = PeekabooMCPServer.callToolResult(from: response, toolName: "permissions")
        let encoded = try JSONEncoder().encode(result)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let metadata = try #require(json["_meta"] as? [String: Any])

        #expect(result.isError == true)
        #expect(metadata["permission_snapshot_available"] as? Bool == true)
        #expect(metadata["screen_recording"] as? Bool == true)
        #expect(metadata["accessibility"] as? Bool == false)
        #expect(metadata["event_synthesizing"] as? Bool == false)
        #expect(metadata["required_permissions_granted"] as? Bool == false)
        #expect(metadata["event_synthesizing_limits"] as? [String] == [
            "background keyboard input",
            "foreground synthetic pointer input",
        ])
        #expect(metadata["internal_diagnostics"] == nil)
    }

    @Test
    @MainActor
    func `click wire schema requires an exclusive target and a background coordinate receipt`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let session = try await MCPWireSession.connect(context: context)

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
            for variant in ["middle", "triple"] {
                guard case let .object(variantSchema)? = properties[variant] else {
                    Issue.record("click variant property \(variant) is missing")
                    continue
                }
                #expect(variantSchema["type"] == .string("boolean"))
                #expect(variantSchema["default"] == .bool(false))
            }
            guard case let .array(variantConstraints)? = schema["allOf"] else {
                Issue.record("click wire schema is missing variant conflicts")
                await session.stop()
                return
            }
            #expect(!variantConstraints.isEmpty)
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
        let session = try await MCPWireSession.connect(context: context)
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
    @MainActor
    func `click wire refuses conflicting true variants while accepting explicit false defaults`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        let session = try await MCPWireSession.connect(context: context)

        do {
            let conflicting: RequestContext<CallTool.Result> = try await session.client.callTool(
                name: "click",
                arguments: [
                    "coords": .string("10,20"),
                    "foreground": .bool(true),
                    "middle": .bool(true),
                    "triple": .bool(true),
                ])
            let refusal = try await conflicting.value
            #expect(refusal.isError == true)
            #expect(automation.clickCalls.isEmpty)

            let explicitDefaults: RequestContext<CallTool.Result> = try await session.client.callTool(
                name: "click",
                arguments: [
                    "coords": .string("10,20"),
                    "foreground": .bool(true),
                    "middle": .bool(true),
                    "triple": .bool(false),
                    "double": .bool(false),
                    "right": .bool(false),
                ])
            let accepted = try await explicitDefaults.value
            #expect(accepted.isError == true)
            #expect(accepted.content.contains { content in
                guard case let .text(text, _, _) = content else { return false }
                return text.contains("Execution policy refused")
            })
            #expect(automation.clickCalls.isEmpty)
        } catch {
            await session.stop()
            throw error
        }

        await session.stop()
    }

    @Test
    @MainActor
    func `press wire reports an empty chord sequence without dispatch`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        let session = try await MCPWireSession.connect(context: context)

        do {
            let request: RequestContext<CallTool.Result> = try await session.client.callTool(
                name: "press",
                arguments: ["keys": .array([])])
            let result = try await request.value
            #expect(result.isError == true)
            #expect(result.content.contains { content in
                guard case let .text(text, _, _) = content else { return false }
                return text.contains("keys must contain at least one chord")
            })
            let encoded = try JSONEncoder().encode(result)
            let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let metadata = try #require(json["_meta"] as? [String: Any])
            #expect(metadata["refusal_reason"] as? String == "invalid_request")
            #expect(metadata["mutation_dispatched"] as? Bool == false)
            #expect(metadata["retry_safe"] as? Bool == true)
            #expect(automation.lastHotkeyKeys == nil)
            #expect(automation.targetedHotkeyCalls.isEmpty)
        } catch {
            await session.stop()
            throw error
        }

        await session.stop()
    }

    @Test
    @MainActor
    func `press wire rejects malformed modifier shapes without dispatch`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        let session = try await MCPWireSession.connect(context: context)
        let cases: [([String: Value], String)] = [
            (
                ["key": .string("c"), "modifiers": .string("cmd")],
                "modifiers must be an array of modifier strings"),
            (
                ["key": .string("c"), "modifiers": .object(["cmd": .bool(true)])],
                "modifiers must be an array of modifier strings"),
            (
                ["key": .string("c"), "modifiers": .array([.string("cmd"), .int(7)])],
                "modifiers[1] must be a non-empty modifier string"),
            (
                ["key": .string("c"), "modifiers": .array([.string("cmd"), .string("  ")])],
                "modifiers[1] must be a non-empty modifier string"),
            (
                [
                    "keys": .array([.string("cmd+c")]),
                    "modifiers": .object(["unexpected": .bool(true)]),
                ],
                "Use either keys or key+modifiers, not both"),
            (
                ["keys": .array([.string("cmd+c")]), "modifiers": .array([])],
                "Use either keys or key+modifiers, not both"),
        ]

        do {
            for (arguments, expectedMessage) in cases {
                var foregroundArguments = arguments
                foregroundArguments["foreground"] = .bool(true)
                let request: RequestContext<CallTool.Result> = try await session.client.callTool(
                    name: "press",
                    arguments: foregroundArguments)
                let result = try await request.value
                #expect(result.isError == true)
                #expect(result.content.contains { content in
                    guard case let .text(text, _, _) = content else { return false }
                    return text.contains(expectedMessage)
                })

                let encoded = try JSONEncoder().encode(result)
                let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
                let metadata = try #require(json["_meta"] as? [String: Any])
                #expect(metadata["refusal_reason"] as? String == "invalid_request")
                #expect(metadata["mutation_dispatched"] as? Bool == false)
                #expect(metadata["retry_safe"] as? Bool == true)
                #expect(automation.lastHotkeyKeys == nil)
                #expect(automation.targetedHotkeyCalls.isEmpty)
            }
        } catch {
            await session.stop()
            throw error
        }

        await session.stop()
    }

    @Test
    @MainActor
    func `press wire rejects non-string primary keys without dispatch`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        let session = try await MCPWireSession.connect(context: context)
        let cases: [Value] = [
            .int(7),
            .double(7),
            .bool(true),
            .array([.string("c")]),
            .object(["value": .string("c")]),
            .null,
        ]

        do {
            for key in cases {
                let request: RequestContext<CallTool.Result> = try await session.client.callTool(
                    name: "press",
                    arguments: [
                        "key": key,
                        "foreground": .bool(true),
                    ])
                let result = try await request.value
                #expect(result.isError == true)
                #expect(result.content.contains { content in
                    guard case let .text(text, _, _) = content else { return false }
                    return text.contains("key must be a primary key string")
                })

                let encoded = try JSONEncoder().encode(result)
                let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
                let metadata = try #require(json["_meta"] as? [String: Any])
                #expect(metadata["refusal_reason"] as? String == "invalid_request")
                #expect(metadata["mutation_dispatched"] as? Bool == false)
                #expect(metadata["retry_safe"] as? Bool == true)
                #expect(automation.lastHotkeyKeys == nil)
                #expect(automation.targetedHotkeyCalls.isEmpty)
            }
        } catch {
            await session.stop()
            throw error
        }

        await session.stop()
    }

    @Test
    @MainActor
    func `press wire still enforces background policy after semantic validation`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        let session = try await MCPWireSession.connect(context: context)

        do {
            let request: RequestContext<CallTool.Result> = try await session.client.callTool(
                name: "press",
                arguments: [
                    "key": .string("c"),
                    "modifiers": .array([.string("cmd")]),
                    "foreground": .bool(true),
                ])
            let result = try await request.value
            #expect(result.isError == true)
            let encoded = try JSONEncoder().encode(result)
            let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let metadata = try #require(json["_meta"] as? [String: Any])
            #expect(metadata["error_code"] as? String == MCPToolExecutionPolicy.refusalErrorCode)
            #expect(metadata["refusal_reason"] as? String == "foreground_consent_required")
            #expect(metadata["mutation_dispatched"] as? Bool == false)
            #expect(metadata["retry_safe"] as? Bool == true)
            #expect(automation.lastHotkeyKeys == nil)
            #expect(automation.targetedHotkeyCalls.isEmpty)
        } catch {
            await session.stop()
            throw error
        }

        await session.stop()
    }

    @Test
    @MainActor
    func `every advertised closed schema rejects unknown properties as invalid params`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let session = try await MCPWireSession.connect(context: context)
        let probeValues: [Value] = [
            .bool(true),
            .string("unexpected"),
            .int(17),
            .array([.string("nested")]),
            .object(["nested": .bool(false)]),
        ]

        do {
            let (tools, _) = try await session.client.listTools()
            #expect(tools.count == 26)

            for (index, tool) in tools.sorted(by: { $0.name < $1.name }).enumerated() {
                guard case let .object(schema) = tool.inputSchema else {
                    Issue.record("Expected \(tool.name) to advertise an object schema")
                    continue
                }
                #expect(schema["additionalProperties"] == .bool(false))

                let unknownKey = "__unexpected_\(index)"
                let detail = await Self.invalidParamsDetail(
                    session: session,
                    params: .object([
                        "name": .string(tool.name),
                        "arguments": .object([
                            unknownKey: probeValues[index % probeValues.count],
                        ]),
                    ]))
                #expect(detail?.contains(tool.name) == true)
                #expect(detail?.contains(unknownKey) == true)
            }
        } catch {
            await session.stop()
            throw error
        }

        await session.stop()
    }

    @Test
    @MainActor
    func `wire decoder rejects non-object tool calls and preserves omitted arguments`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let session = try await MCPWireSession.connect(context: context)

        do {
            for params: Value in [.null, .array([]), .string("permissions"), .bool(true)] {
                let detail = await Self.invalidParamsDetail(session: session, params: params)
                #expect(detail?.contains("params must be an object") == true)
            }

            for arguments: Value in [.null, .array([]), .string("bogus"), .bool(true), .int(1)] {
                let detail = await Self.invalidParamsDetail(
                    session: session,
                    params: .object([
                        "name": .string("permissions"),
                        "arguments": arguments,
                    ]))
                #expect(detail?.contains("arguments must be an object") == true)
            }

            let result = try await session.callRaw(params: .object([
                "name": .string("permissions"),
            ]))
            #expect(result.isError != true)
        } catch {
            await session.stop()
            throw error
        }

        await session.stop()
    }

    @Test
    @MainActor
    func `wire decoder enforces nested closed schemas before dispatch`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let session = try await MCPWireSession.connect(context: context)
        let cases: [(name: String, arguments: [String: Value], path: String)] = [
            (
                "analyze",
                [
                    "question": .string("What is shown?"),
                    "provider_config": .object(["bogus": .bool(true)]),
                ],
                "$.provider_config"),
            (
                "verify_state",
                [
                    "predicates": .array([.object([
                        "kind": .string("window_exists"),
                        "expected": .bool(true),
                        "bogus": .string("nested"),
                    ])]),
                ],
                "$.predicates[0]"),
            (
                "verify_state",
                [
                    "predicates": .array([.object([
                        "kind": .string("element_exists"),
                        "selector": .object([
                            "identifier": .string("save-button"),
                            "bogus": .int(9),
                        ]),
                        "expected": .bool(true),
                    ])]),
                ],
                "$.predicates[0].selector"),
        ]

        for testCase in cases {
            let detail = await Self.invalidParamsDetail(
                session: session,
                params: .object([
                    "name": .string(testCase.name),
                    "arguments": .object(testCase.arguments),
                ]))
            #expect(detail?.contains(testCase.path) == true)
            #expect(detail?.contains("bogus") == true)
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

    private static func invalidParamsDetail(session: MCPWireSession, params: Value) async -> String? {
        do {
            _ = try await session.callRaw(params: params)
            Issue.record("Expected tools/call to fail with invalid params")
            return nil
        } catch let error as MCP.MCPError {
            #expect(error.code == -32602)
            guard case let .invalidParams(detail) = error else {
                Issue.record("Expected invalidParams, got \(error)")
                return nil
            }
            return detail
        } catch {
            Issue.record("Expected MCPError.invalidParams, got \(error)")
            return nil
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

private struct MCPWireSession {
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

    func callRaw(params: Value) async throws -> CallTool.Result {
        let request = RawCallTool.request(params)
        let context: RequestContext<CallTool.Result> = try await self.client.send(request)
        return try await context.value
    }
}

private enum RawCallTool: MCP.Method {
    typealias Parameters = Value
    typealias Result = CallTool.Result

    static let name = CallTool.name
}

@MainActor
private func makeServer() async throws -> PeekabooMCPServer {
    let services = PeekabooServices()
    return try await PeekabooMCPServer(toolContext: MCPToolContext(services: services))
}
