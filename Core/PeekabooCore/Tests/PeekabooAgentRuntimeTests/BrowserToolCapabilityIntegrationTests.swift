import Foundation
import MCP
import PeekabooCore
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserToolCapabilityIntegrationTests {
    @Test
    func `command line and MCP uid schemas distinguish raw provider IDs from opaque capabilities`() throws {
        let context = Self.context(client: CapabilityBrowserMCPClient())
        let commandLineTool = BrowserTool(context: context, instructionAudience: .commandLine)
        let mcpTool = BrowserTool(context: context)

        let commandLineDescription = try Self.uidSchemaDescription(for: commandLineTool)
        let mcpDescription = try Self.uidSchemaDescription(for: mcpTool)

        #expect(commandLineDescription == "Raw snapshot-local provider element UID from the latest browser snapshot.")
        #expect(!commandLineDescription.contains("Opaque element capability"))
        #expect(mcpDescription.contains("Opaque element capability"))
        #expect(!mcpDescription.contains("Raw snapshot-local provider element UID"))
    }

    @Test
    func `BrowserTool projects opaque refs and rejects another context before provider dispatch`() async throws {
        let client = CapabilityBrowserMCPClient()
        let firstContext = Self.context(client: client)
        let secondContext = Self.context(client: client)
        let first = BrowserTool(context: firstContext)
        let second = BrowserTool(context: secondContext)

        let listed = try await firstContext.execute(
            tool: first,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)
        #expect(pageReference.hasPrefix("bp1_"))
        #expect(!Self.text(from: listed).contains("\n7:"))

        let snapshotted = try await firstContext.execute(
            tool: first,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        let elementReference = try Self.elementReference(from: snapshotted)
        #expect(elementReference.hasPrefix("be1_"))
        #expect(!Self.text(from: snapshotted).contains("uid=1_0"))
        #expect(client.sequences.count == 2)
        #expect(client.sequences.last?.first?.arguments["pageId"] as? Int == 7)

        let rejected = try await secondContext.execute(
            tool: second,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        #expect(rejected.isError)
        #expect(Self.text(from: rejected).contains("another or expired provider session"))
        #expect(!Self.text(from: rejected).contains("remote debugging"))
        #expect(client.sequences.count == 2)

        let rawUID = try await firstContext.execute(
            tool: first,
            arguments: ToolArguments(raw: [
                "action": "click",
                "page_id": pageReference,
                "uid": "1_0",
            ]))
        #expect(rawUID.isError)
        #expect(Self.text(from: rawUID).contains("opaque element reference"))
        #expect(!Self.text(from: rawUID).contains("remote debugging"))
        #expect(client.sequences.count == 2)
    }

    @Test
    func `indeterminate status retains opaque refs until confirmed disconnect`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)
        let snapshot = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        let elementReference = try Self.elementReference(from: snapshot)
        let connected = await client.status(channel: nil)
        client.statusResponses = [BrowserMCPStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: [],
            connectionReceipt: connected.connectionReceipt,
            providerSessionEpoch: connected.providerSessionEpoch,
            error: CancellationError().localizedDescription,
            observation: .indeterminate)]
        let sequencesBeforeClick = client.sequences.count

        let clicked = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "click",
                "page_id": pageReference,
                "uid": elementReference,
            ]))

        #expect(!clicked.isError)
        #expect(client.sequences.count == sequencesBeforeClick + 1)
        #expect(client.sequences.last?.last?.toolName == "click")
        let recordedPreflight = try #require(client.elementPreflights.last)
        let preflight = try #require(recordedPreflight)
        #expect(preflight.providerUIDs == ["1_0"])

        client.statusResponses = [BrowserMCPStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: [])]
        _ = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "status"]))
        let sequencesBeforeStalePage = client.sequences.count
        let stalePage = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        #expect(stalePage.isError)
        #expect(client.sequences.count == sequencesBeforeStalePage)
    }

    @Test
    func `text only daemon snapshot refuses instead of minting ambiguous element refs`() async throws {
        let client = CapabilityBrowserMCPClient(structuredResponses: false)
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)

        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try #require(
            Self.text(from: listed).split(separator: "\n").first(where: { $0.hasPrefix("bp1_") })?.split(
                separator: ":").first.map(String.init))
        let snapshot = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        #expect(snapshot.isError)
        #expect(!Self.allText(from: snapshot).contains("uid=1_0"))
    }

    @Test
    func `raw snapshot and evaluate script resolve only schema owned element positions`() async throws {
        let client = CapabilityBrowserMCPClient()
        let coordinator = CapabilityMutationCoordinator()
        let context = Self.context(
            client: client,
            coordinator: coordinator,
            executionPolicy: .foregroundAllowed)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "call",
                "mcp_tool": "list_pages",
            ]))
        let pageReference = try Self.pageReference(from: listed)
        // Page listing and snapshots can also grant provider user activation and own shared mutation barriers.
        #expect(coordinator.sharedPrepareCount == 1)
        #expect(coordinator.completionCount == 1)
        let snapshot = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "call",
                "mcp_tool": "take_snapshot",
                "page_id": pageReference,
            ]))
        let elementReference = try Self.elementReference(from: snapshot)
        #expect(coordinator.sharedPrepareCount == 2)
        #expect(coordinator.completionCount == 2)
        let evaluateArguments = #"{"function":"(el) => el.textContent","args":["\#(elementReference)"],"# +
            #""uid":"domain-value"}"#

        let evaluated = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "call",
                "mcp_tool": "evaluate_script",
                "page_id": pageReference,
                "mcp_args_json": evaluateArguments,
            ]))

        #expect(!evaluated.isError)
        let call = try #require(client.sequences.last?.last)
        #expect(call.toolName == "evaluate_script")
        #expect(call.arguments["pageId"] as? Int == 7)
        #expect(call.arguments["args"] as? [String] == ["1_0"])
        #expect(call.arguments["uid"] as? String == "domain-value")
        #expect(coordinator.sharedPrepareCount == 3)
        #expect(coordinator.concurrentPrepareCount == 0)
        #expect(coordinator.completionCount == 3)
    }

    @Test
    func `evaluate script domain uid text is not rewritten as an element capability`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client, executionPolicy: .foregroundAllowed)
        let tool = BrowserTool(context: context)
        let pageReference = try await Self.pageReference(from: context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"])))
        let snapshot = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        let elementReference = try Self.elementReference(from: snapshot)
        let domainResult = "uid 1_0 active\n7: order\nNote: Page 7 domain"
        client.executeHandler = { toolName in
            toolName == "evaluate_script" ? .text(domainResult) : .text("ok")
        }

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "call",
                "mcp_tool": "evaluate_script",
                "page_id": pageReference,
                "mcp_args_json": #"{"function":"(el) => el","args":["\#(elementReference)"]}"#,
            ]))

        #expect(!response.isError)
        #expect(Self.text(from: response) == domainResult)
    }

    @Test
    func `background capability evaluation refuses before status or provider execution`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client, executionPolicy: .backgroundOnly)
        let tool = BrowserTool(context: context)
        let pageReference = "bp1_" + String(repeating: "a", count: 32)

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "call",
                "mcp_tool": "evaluate_script",
                "page_id": pageReference,
                "mcp_args_json": #"{"function":"() => navigator.userActivation.isActive"}"#,
            ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["refusal_reason"] == .string("foreground_consent_required"))
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        #expect(client.statusCount == 0)
        #expect(client.sequences.isEmpty)
    }

    @Test(arguments: ["1_0", "stashed-0"])
    func `third party projection refusal preserves exact postdispatch evidence`(providerUID: String) async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let pageReference = try await Self.pageReference(from: context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"])))
        let snapshot = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        let elementReference = try Self.elementReference(from: snapshot)
        let providerResult = #"{"result":{"uid":"\#(providerUID)"}}"#
        client.executeHandler = { toolName in
            guard toolName == "execute_3p_developer_tool" else { return .text("ok") }
            return ToolResponse(
                content: [.text(text: providerResult, annotations: nil, _meta: nil)],
                structuredContent: .object(["message": .string(providerResult)]))
        }
        let params = #"{"target":{"uid":"\#(elementReference)"}}"#
        let encodedArguments = try JSONSerialization.data(
            withJSONObject: ["toolName": "fixture", "params": params],
            options: [.sortedKeys])
        let rawArguments = try #require(String(data: encodedArguments, encoding: .utf8))

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "call",
                "mcp_tool": "execute_3p_developer_tool",
                "page_id": pageReference,
                "mcp_args_json": rawArguments,
            ]))

        #expect(response.isError)
        #expect(!Self.allText(from: response).contains(providerUID))
        #expect(!Self.allText(from: response).contains(elementReference))
        let outcome = try #require(
            MCPToolResponseMetadataProjector.actionOutcomeResolution(from: response.meta).projection?.outcome)
        #expect(outcome.state == .indeterminate)
        #expect(outcome.route == .local)
        #expect(outcome.delivery == .init(mechanism: .browserProtocol, mode: .foreground))
        #expect(outcome.evidence == .completionUnknown)
        #expect(outcome.dispatchState.unitCount == .one)
        #expect(outcome.retrySafety == .unsafe)
    }

    @Test
    func `third party singleton uid omitted from fresh snapshot fails closed`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let pageReference = try await Self.pageReference(from: context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"])))
        let snapshot = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        let elementReference = try Self.elementReference(from: snapshot)
        let providerResult = #"{"result":{"uid":"2_0"}}"#
        client.executeHandler = { toolName in
            guard toolName == "execute_3p_developer_tool" else { return .text("ok") }
            return ToolResponse(
                content: [.text(
                    text: providerResult + "\n## Latest page snapshot\nuid=1_0 button \"Continue\"",
                    annotations: nil,
                    _meta: nil)],
                structuredContent: .object([
                    "message": .string(providerResult),
                    "snapshot": .object([
                        "id": .string("1_0"),
                        "role": .string("button"),
                        "name": .string("Continue"),
                    ]),
                ]))
        }
        let params = #"{"target":{"uid":"\#(elementReference)"}}"#
        let encodedArguments = try JSONSerialization.data(
            withJSONObject: ["toolName": "fixture", "params": params],
            options: [.sortedKeys])
        let rawArguments = try #require(String(data: encodedArguments, encoding: .utf8))

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "call",
                "mcp_tool": "execute_3p_developer_tool",
                "page_id": pageReference,
                "mcp_args_json": rawArguments,
            ]))

        #expect(response.isError)
        #expect(!Self.allText(from: response).contains("2_0"))
    }

    @Test
    func `console domain uid line outside affected resources remains unchanged`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let pageReference = try await Self.pageReference(from: context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"])))
        let snapshot = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        let elementReference = try Self.elementReference(from: snapshot)
        client.executeHandler = { toolName in
            guard toolName == "get_console_message" else { return .text("ok") }
            return ToolResponse(
                content: [.text(
                    text: "Value:\nuid=1_0\n### Affected resources\nuid=1_0",
                    annotations: nil,
                    _meta: nil)],
                structuredContent: .object([
                    "consoleMessage": .object([
                        "value": .string("uid=1_0"),
                        "affectedResources": .array([.object([
                            "uid": .string("1_0"),
                            "label": .string("uid=1_0"),
                        ])]),
                    ]),
                ]))
        }

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "console",
                "page_id": pageReference,
                "message_id": 1,
            ]))

        #expect(!response.isError)
        #expect(Self.text(from: response) == "Value:\nuid=1_0\n### Affected resources\nuid=\(elementReference)")
        let consoleMessage = try #require(response.structuredContent?.objectValue?["consoleMessage"]?.objectValue)
        #expect(consoleMessage["value"] == .string("uid=1_0"))
        let affected = try #require(consoleMessage["affectedResources"]?.arrayValue?.first?.objectValue)
        #expect(affected["uid"] == .string(elementReference))
        #expect(affected["label"] == .string("uid=1_0"))
    }

    @Test
    func `console affected resource without opaque snapshot mapping fails closed`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let pageReference = try await Self.pageReference(from: context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"])))
        client.executeHandler = { toolName in
            guard toolName == "get_console_message" else { return .text("ok") }
            return ToolResponse(
                content: [.text(
                    text: "### Affected resources\nuid=1_0",
                    annotations: nil,
                    _meta: nil)],
                structuredContent: .object([
                    "consoleMessage": .object([
                        "affectedResources": .array([.object(["uid": .string("1_0")])]),
                    ]),
                ]))
        }

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "console",
                "page_id": pageReference,
                "message_id": 1,
            ]))

        #expect(response.isError)
        #expect(!Self.allText(from: response).contains("1_0"))
    }

    @Test
    func `foreground capable browser connect retains the shared desktop mutation lane`() async throws {
        let client = CapabilityBrowserMCPClient()
        let coordinator = CapabilityMutationCoordinator()
        let context = Self.context(client: client, coordinator: coordinator)

        let response = try await context.execute(
            tool: BrowserTool(context: context),
            arguments: ToolArguments(raw: ["action": "connect"]))

        #expect(response.isError)
        #expect(coordinator.sharedPrepareCount == 1)
        #expect(coordinator.concurrentPrepareCount == 0)
        #expect(coordinator.completionCount == 1)
    }

    @Test
    func `capability snapshot file output refuses before provider dispatch`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)
        let before = client.sequences.count

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "call",
                "mcp_tool": "take_snapshot",
                "page_id": pageReference,
                "mcp_args_json": #"{"filePath":"/tmp/provider-uids.txt"}"#,
            ]))

        #expect(response.isError)
        #expect(Self.text(from: response).contains("cannot write provider UIDs"))
        #expect(client.sequences.count == before)
    }

    @Test
    func `capability action refuses a receipt without provider child epoch`() async throws {
        let client = CapabilityBrowserMCPClient(providesEpoch: false)
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))

        #expect(response.isError)
        #expect(Self.text(from: response).contains("provider child epoch"))
        #expect(client.sequences.isEmpty)
    }

    @Test
    func `dialog handling does not require a provider snapshot preflight`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)

        _ = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "handle_dialog",
                "page_id": pageReference,
                "dialog_action": "accept",
            ]))

        #expect(client.sequences.last?.map(\.toolName) == ["handle_dialog"])
        #expect(client.elementPreflights.count == 2)
        #expect(client.elementPreflights[1] == nil)
    }

    @Test
    func `capability FIFO keeps snapshot dispatch and projection in issue order`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)
        let barrier = CapabilitySequenceBarrier()
        var invocation = 0
        client.executeHandler = { toolName in
            guard toolName == "take_snapshot" else { return .text("ok") }
            invocation += 1
            if invocation == 1 {
                await barrier.block()
            }
            return Self.snapshotResponse(uid: "\(invocation)_0")
        }

        let first = Task { @MainActor in
            try await context.execute(
                tool: tool,
                arguments: ToolArguments(raw: [
                    "action": "snapshot",
                    "page_id": pageReference,
                ]))
        }
        await barrier.waitUntilBlocked()
        let second = Task { @MainActor in
            try await context.execute(
                tool: tool,
                arguments: ToolArguments(raw: [
                    "action": "snapshot",
                    "page_id": pageReference,
                ]))
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(invocation == 1)
        await barrier.release()
        let firstResponse = try await first.value
        _ = try await second.value
        let staleElement = try Self.elementReference(from: firstResponse)
        let beforeRefusal = client.sequences.count

        let refused = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "click",
                "page_id": pageReference,
                "uid": staleElement,
            ]))
        #expect(refused.isError)
        #expect(client.sequences.count == beforeRefusal)
    }
}

extension BrowserToolCapabilityIntegrationTests {
    @Test
    func `third party raw params and returned DOM refs use exact singleton object paths`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)
        let snapshot = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        let elementReference = try Self.elementReference(from: snapshot)
        let parameters = #"{"target":{"uid":"\#(elementReference)"},"# +
            #""metadata":{"uid":"domain-value","extra":true}}"#
        let encodedArguments = try JSONSerialization.data(
            withJSONObject: ["toolName": "fixture", "params": parameters],
            options: [.sortedKeys])
        let rawArguments = try #require(String(data: encodedArguments, encoding: .utf8))
        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "call",
                "mcp_tool": "execute_3p_developer_tool",
                "page_id": pageReference,
                "mcp_args_json": rawArguments,
            ]))

        let call = try #require(client.sequences.last?.last)
        let params = try #require(call.arguments["params"] as? String)
        let data = try #require(params.data(using: .utf8))
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((decoded["target"] as? [String: Any])?["uid"] as? String == "1_0")
        #expect((decoded["metadata"] as? [String: Any])?["uid"] as? String == "domain-value")
        let text = Self.text(from: response)
        #expect(text.contains(#""label" : "uid=1_0""#))
        #expect(text.contains(#""uid" : "customer-42""#))
        #expect(!text.contains("\nuid=1_0"))
        #expect(!text.contains(#""uid" : "1_0""#))
        #expect(text.contains("be1_"))
        #expect(text.contains("Emulating viewport: {\"width\":800}"))
        let message = try #require(response.structuredContent?.objectValue?["message"]?.stringValue)
        #expect(message.contains("be1_"))
        #expect(!message.contains(#""uid" : "1_0""#))
        #expect(response.meta?.objectValue?["state"] == .string("dispatched_unverified"))
    }

    @Test(arguments: ["customer-42", "١_٢"])
    func `third party domain uid text without a snapshot remains unchanged`(domainUID: String) async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)
        let providerText = #"{"uid":"\#(domainUID)"}"#
        client.executeHandler = { toolName in
            toolName == "execute_3p_developer_tool" ? .text(providerText) : .text("ok")
        }

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "call",
                "mcp_tool": "execute_3p_developer_tool",
                "page_id": pageReference,
                "mcp_args_json": #"{"toolName":"fixture"}"#,
            ]))

        #expect(Self.text(from: response) == providerText)
        #expect(response.meta?.objectValue?["browser_snapshot_ref"] == nil)
    }

    @Test
    func `provider error projects existing opaque refs and preserves canonical outcome`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)
        let snapshot = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        let elementReference = try Self.elementReference(from: snapshot)
        let diagnostic = "Element with uid 1_0 no longer exists on the page."
        client.executeHandler = { toolName in
            guard toolName == "click" else { return .text("ok") }
            return ToolResponse(
                content: [.text(
                    text: diagnostic,
                    annotations: nil,
                    _meta: Metadata(additionalFields: ["provider_diagnostic": .string(diagnostic)]))],
                isError: true,
                meta: .object([
                    "provider_diagnostic": .string(diagnostic),
                    "provider_page": .int(7),
                ]),
                structuredContent: .object([
                    "message": .string(diagnostic),
                    "snapshot": .object(["id": .string("1_0")]),
                    "domain": .string("order uid 1_0 active"),
                ]))
        }

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "click",
                "page_id": pageReference,
                "uid": elementReference,
            ]))
        let allText = Self.allText(from: response)

        #expect(response.isError)
        #expect(!allText.contains("uid 1_0"))
        #expect(!allText.contains(elementReference))
        #expect(allText.contains("provider diagnostics were withheld"))
        #expect(response.structuredContent == nil)
        #expect(response.meta?.objectValue?["state"] == .string("indeterminate"))
    }

    @Test
    func `non snapshot success projects echoed element uid across every result surface`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)
        let snapshot = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        let elementReference = try Self.elementReference(from: snapshot)
        let providerMessage = "Took a screenshot of node with uid \"1_0\"."
        client.executeHandler = { toolName in
            guard toolName == "take_screenshot" else { return .text("ok") }
            return ToolResponse(
                content: [.text(
                    text: providerMessage,
                    annotations: nil,
                    _meta: Metadata(additionalFields: ["provider_message": .string(providerMessage)]))],
                meta: .object(["provider_message": .string(providerMessage)]),
                structuredContent: .object(["message": .string(providerMessage)]))
        }

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "screenshot",
                "page_id": pageReference,
                "uid": elementReference,
            ]))
        let allText = Self.allText(from: response)

        #expect(!response.isError)
        #expect(!allText.contains("uid \"1_0\""))
        #expect(allText.contains("uid \"\(elementReference)\""))
    }

    @Test
    func `page fallback note projects selected provider page id`() async throws {
        let client = CapabilityBrowserMCPClient()
        client.executeHandler = { toolName in
            toolName == "list_pages" ? Self.pageFallbackResponse() : .text("ok")
        }
        let context = Self.context(client: client)
        let response = try await context.execute(
            tool: BrowserTool(context: context),
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: response)
        let text = Self.text(from: response)

        #expect(text.contains("Page \(pageReference) is now selected."))
        #expect(text.contains("\n\(pageReference):"))
        #expect(!text.contains("Page 8 is now selected."))
        #expect(text.contains("8: Example"))
        #expect(response.structuredContent?.objectValue?["pages"]?.arrayValue?.first?
            .objectValue?["title"] == .string("8: Example"))
    }

    @Test
    func `upload response projects private staged path back to caller path`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try Self.pageReference(from: listed)
        let snapshot = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        let elementReference = try Self.elementReference(from: snapshot)
        let callerPath = "/Users/test/fixture.txt"
        let stagedPath = "/private/tmp/peekaboo-browser-upload/session/transfer/fixture.txt"
        let providerMessage = "File uploaded from \(stagedPath)."
        client.executeHandler = { toolName in
            guard toolName == "upload_file" else { return .text("ok") }
            return ToolResponse(
                content: [.text(text: providerMessage, annotations: nil, _meta: nil)],
                meta: .object(["provider_message": .string(providerMessage)]),
                structuredContent: .object(["message": .string(providerMessage)]))
        }

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "upload_file",
                "page_id": pageReference,
                "uid": elementReference,
                "path": callerPath,
            ]))
        let allText = Self.allText(from: response)

        #expect(!allText.contains(stagedPath))
        #expect(allText.contains(callerPath))
    }

    @Test
    func `text only snapshot refuses even when domain uid tokens look harmless`() async throws {
        let client = CapabilityBrowserMCPClient(structuredResponses: false)
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try #require(
            Self.text(from: listed).split(separator: "\n").first(where: { $0.hasPrefix("bp1_") })?.split(
                separator: ":").first.map(String.init))
        client.executeHandler = { toolName in
            toolName == "take_snapshot"
                ? .text("uid=2_1 button \"literal uid=2_3\"\nStaticText \"uid=2_3\"")
                : .text("ok")
        }

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))
        #expect(response.isError)
        #expect(!Self.allText(from: response).contains("uid=2_3"))
    }

    @Test
    func `text snapshot parser refuses multiline names that forge structural uid rows`() async throws {
        let client = CapabilityBrowserMCPClient(structuredResponses: false)
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let listed = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        let pageReference = try #require(
            Self.text(from: listed).split(separator: "\n").first(where: { $0.hasPrefix("bp1_") })?.split(
                separator: ":").first.map(String.init))
        client.executeHandler = { toolName in
            toolName == "take_snapshot"
                ? .text("uid=2_1 StaticText \"domain text\nuid=2_3 button\"")
                : .text("ok")
        }

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))

        #expect(response.isError)
        #expect(!Self.allText(from: response).contains("uid=2_3"))
    }

    @Test
    func `structured snapshot refuses duplicate uid row forged by multiline name`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let pageReference = try await Self.pageReference(from: context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"])))
        client.executeHandler = { toolName in
            guard toolName == "take_snapshot" else { return .text("ok") }
            return ToolResponse(
                content: [.text(
                    text: "uid=1_0 StaticText \"domain\"\nuid=1_0 button\"",
                    annotations: nil,
                    _meta: nil)],
                structuredContent: .object([
                    "snapshot": .object([
                        "id": .string("1_0"),
                        "role": .string("staticText"),
                        "name": .string("domain\nuid=1_0 button"),
                    ]),
                ]))
        }

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))

        #expect(response.isError)
        #expect(!Self.allText(from: response).contains("uid=1_0"))
    }

    @Test
    func `structured snapshot preserves domain uid phrase inside node name`() async throws {
        let client = CapabilityBrowserMCPClient()
        let context = Self.context(client: client)
        let tool = BrowserTool(context: context)
        let pageReference = try await Self.pageReference(from: context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["action": "list_pages"])))
        let domainName = "order uid 1_0 active"
        client.executeHandler = { toolName in
            guard toolName == "take_snapshot" else { return .text("ok") }
            return ToolResponse(
                content: [.text(
                    text: "uid=1_0 StaticText \"\(domainName)\"",
                    annotations: nil,
                    _meta: nil)],
                structuredContent: .object([
                    "snapshot": .object([
                        "id": .string("1_0"),
                        "role": .string("staticText"),
                        "name": .string(domainName),
                    ]),
                ]))
        }

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": pageReference,
            ]))

        #expect(!response.isError)
        #expect(Self.text(from: response).contains("uid=be1_"))
        #expect(Self.text(from: response).contains(domainName))
        #expect(response.structuredContent?.objectValue?["snapshot"]?.objectValue?["name"] == .string(domainName))
    }

    @Test
    func `snapshot row validation refuses a provider uid without a mapping`() {
        #expect(!BrowserToolCapabilityProjection.snapshotRowsAreUnambiguous(
            in: "uid=2_1 button",
            mappings: [:]))
    }

    @Test(arguments: ["\r", "\r\n", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"])
    func `snapshot row validation refuses non LF separators`(separator: String) {
        #expect(!BrowserToolCapabilityProjection.snapshotRowsAreUnambiguous(
            in: "uid=2_1 StaticText \"domain text\(separator)uid=2_1 button\"",
            mappings: ["2_1": "be1_fixture"]))
    }

    private static func context(
        client: any BrowserMCPClientProviding,
        coordinator: (any MCPToolSnapshotMutationCoordinating)? = nil,
        executionPolicy: MCPToolExecutionPolicy = .unrestricted) -> MCPToolContext
    {
        let services = PeekabooServices()
        return MCPToolContext(
            automation: services.automation,
            menu: services.menu,
            windows: services.windows,
            applications: services.applications,
            dialogs: services.dialogs,
            dock: services.dock,
            screenCapture: services.screenCapture,
            desktopObservation: services.desktopObservation,
            snapshots: services.snapshots,
            screens: services.screens,
            agent: nil,
            permissions: services.permissions,
            clipboard: services.clipboard,
            browser: client,
            snapshotMutationCoordinator: coordinator,
            executionPolicy: executionPolicy)
    }

    private static func pageReference(from response: ToolResponse) throws -> String {
        let root = try #require(response.structuredContent?.objectValue)
        let pages = try #require(root["pages"]?.arrayValue)
        return try #require(pages.first?.objectValue?["id"]?.stringValue)
    }

    private static func uidSchemaDescription(for tool: BrowserTool) throws -> String {
        guard case let .object(schema) = tool.inputSchema,
              case let .object(properties)? = schema["properties"],
              case let .object(uid)? = properties["uid"],
              case let .string(description)? = uid["description"]
        else {
            throw BrowserToolCapabilitySchemaError.missingUIDDescription
        }
        return description
    }

    private static func elementReference(from response: ToolResponse) throws -> String {
        let root = try #require(response.structuredContent?.objectValue)
        return try #require(root["snapshot"]?.objectValue?["id"]?.stringValue)
    }

    private static func text(from response: ToolResponse) -> String {
        guard case let .text(text, _, _)? = response.content.first else { return "" }
        return text
    }

    private static func allText(from response: ToolResponse) -> String {
        let content: [String] = response.content.flatMap { item -> [String] in
            switch item {
            case let .text(text, _, metadata):
                return [text] + Self.strings(in: metadata.map { .object($0.fields) })
            case let .image(_, _, _, metadata),
                 let .audio(_, _, _, metadata),
                 let .resource(_, _, metadata):
                return Self.strings(in: metadata.map { .object($0.fields) })
            case .resourceLink:
                return []
            }
        }
        return (content + Self.strings(in: response.meta) + Self.strings(in: response.structuredContent))
            .joined(separator: "\n")
    }

    private static func strings(in value: Value?) -> [String] {
        guard let value else { return [] }
        switch value {
        case let .object(fields):
            return fields.values.flatMap { self.strings(in: $0) }
        case let .array(values):
            return values.flatMap { self.strings(in: $0) }
        case let .string(string):
            return [string]
        case .int, .double, .bool, .null, .data:
            return []
        }
    }

    private static func pageFallbackResponse() -> ToolResponse {
        ToolResponse(
            content: [.text(
                text: "Note: the previously selected page was closed. Page 8 is now selected.\n" +
                    "## Pages\n8: 8: Example (https://example.test/) [selected]",
                annotations: nil,
                _meta: nil)],
            structuredContent: .object([
                "pages": .array([.object([
                    "id": .int(8),
                    "url": .string("https://example.test/"),
                    "title": .string("8: Example"),
                    "selected": .bool(true),
                ])]),
            ]))
    }

    private static func snapshotResponse(uid: String) -> ToolResponse {
        ToolResponse(
            content: [.text(text: "uid=\(uid) button \"Continue\"", annotations: nil, _meta: nil)],
            structuredContent: .object([
                "snapshot": .object([
                    "id": .string(uid),
                    "role": .string("button"),
                    "name": .string("Continue"),
                ]),
            ]))
    }
}

private enum BrowserToolCapabilitySchemaError: Error {
    case missingUIDDescription
}

@MainActor
private final class CapabilityBrowserMCPClient: BrowserMCPClientProviding, BrowserMCPActionResultProviding,
    BrowserMCPAtomicSessionActionProviding,
    @unchecked Sendable
{
    let structuredResponses: Bool
    let providesEpoch: Bool
    let providerSessionEpoch = BrowserMCPProviderSessionEpoch()
    private(set) var sequences: [[BrowserMCPMappedCall]] = []
    private(set) var elementPreflights: [BrowserMCPElementPreflight?] = []
    private(set) var statusCount = 0
    var statusResponses: [BrowserMCPStatus] = []
    var executeHandler: (@MainActor (String) async -> ToolResponse)?

    init(structuredResponses: Bool = true, providesEpoch: Bool = true) {
        self.structuredResponses = structuredResponses
        self.providesEpoch = providesEpoch
    }

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        self.statusCount += 1
        if !self.statusResponses.isEmpty {
            return self.statusResponses.removeFirst()
        }
        return self.connectedStatus()
    }

    private func connectedStatus() -> BrowserMCPStatus {
        BrowserMCPStatus(
            isConnected: true,
            toolCount: 52,
            detectedBrowsers: [],
            connectionReceipt: BrowserMCPConnectionReceipt(
                browserURL: "http://127.0.0.1:9222/",
                webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
                devToolsBrowserID: "browser-a",
                browserVersion: "Chrome/151.0",
                protocolVersion: "1.3"),
            providerSessionEpoch: self.providesEpoch ? self.providerSessionEpoch : nil)
    }

    func connect(channel: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        await self.status(channel: channel)
    }

    func disconnect() async {}

    func execute(
        toolName: String,
        arguments: [String: Any],
        channel _: BrowserMCPChannel?) async throws -> ToolResponse
    {
        let call = BrowserMCPMappedCall(toolName: toolName, arguments: arguments)
        self.sequences.append([call])
        return self.response(for: toolName)
    }

    func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel _: BrowserMCPChannel?) async throws -> DesktopActionResult<ToolResponse>
    {
        self.sequences.append(calls)
        if let executeHandler {
            let response = await executeHandler(calls.last?.toolName ?? "")
            return DesktopActionResult(payload: response, outcome: self.outcome(for: calls, response: response))
        }
        let response = self.response(for: calls.last?.toolName)
        return DesktopActionResult(payload: response, outcome: self.outcome(for: calls, response: response))
    }

    func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedSessionBinding: BrowserMCPExecutionSessionBinding,
        elementPreflight: BrowserMCPElementPreflight?) async throws -> DesktopActionResult<ToolResponse>
    {
        let current = await self.status(channel: channel)
        guard current.connectionReceipt == expectedSessionBinding.connectionReceipt,
              current.providerSessionEpoch == expectedSessionBinding.providerSessionEpoch
        else {
            throw BrowserMCPConnectionError.expectedProviderSessionEpochMismatch
        }
        self.elementPreflights.append(elementPreflight)
        return try await self.executeSequenceWithOutcome(calls, channel: channel)
    }

    private func response(for toolName: String?) -> ToolResponse {
        switch toolName {
        case "list_pages": self.pageResponse()
        case "take_snapshot": self.snapshotResponse()
        case "execute_3p_developer_tool": self.thirdPartyResponse()
        default: .text("ok")
        }
    }

    private func outcome(
        for calls: [BrowserMCPMappedCall],
        response: ToolResponse) -> DesktopActionOutcome?
    {
        let mutationCount = calls.count { call in
            BrowserMCPPageRoutingContract.actionSemantics(
                for: call.toolName,
                arguments: call.arguments) != .readOnly
        }
        guard let unitCount = DesktopActionOutcome.DispatchUnitCount(mutationCount) else { return nil }
        if response.isError {
            return .indeterminate(
                delivery: .init(mechanism: .browserProtocol, mode: .background),
                evidence: .completionUnknown,
                unitCount: unitCount)
        }
        return .dispatchedUnverified(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: unitCount)
    }

    private func pageResponse() -> ToolResponse {
        let content: [MCP.Tool.Content] = [
            .text(
                text: "## Pages\n7: Example (https://example.test/) [selected]",
                annotations: nil,
                _meta: nil),
        ]
        guard self.structuredResponses else { return ToolResponse(content: content) }
        return ToolResponse(
            content: content,
            structuredContent: .object([
                "pages": .array([.object([
                    "id": .int(7),
                    "url": .string("https://example.test/"),
                    "title": .string("Example"),
                    "selected": .bool(true),
                ])]),
            ]))
    }

    private func snapshotResponse() -> ToolResponse {
        let content: [MCP.Tool.Content] = [
            .text(text: "uid=1_0 button \"Continue\"", annotations: nil, _meta: nil),
        ]
        guard self.structuredResponses else { return ToolResponse(content: content) }
        return ToolResponse(
            content: content,
            structuredContent: .object([
                "snapshot": .object([
                    "id": .string("1_0"),
                    "role": .string("button"),
                    "name": .string("Continue"),
                ]),
            ]))
    }

    private func thirdPartyResponse() -> ToolResponse {
        let message = """
        {
          "result": {
            "uid": "1_0"
          },
          "account": {
            "uid": "customer-42"
          },
          "label": "uid=1_0"
        }
        """
        return ToolResponse(
            content: [.text(
                text: """
                \(message)
                Emulating viewport: {"width":800}
                ## Latest page snapshot
                uid=1_0 button "Continue"
                """,
                annotations: nil,
                _meta: Metadata(additionalFields: ["provider_message": .string(message)]))],
            structuredContent: .object([
                "message": .string(message),
                "viewport": .object(["width": .int(800)]),
                "snapshot": .object([
                    "id": .string("1_0"),
                    "role": .string("button"),
                    "name": .string("Continue"),
                ]),
            ]))
    }
}

@MainActor
private final class CapabilityMutationCoordinator: MCPToolSnapshotMutationCoordinating, @unchecked Sendable {
    private(set) var sharedPrepareCount = 0
    private(set) var concurrentPrepareCount = 0
    private(set) var completionCount = 0

    func prepareMutation(_: MCPToolSnapshotMutationScope) throws {
        self.sharedPrepareCount += 1
    }

    func prepareConcurrentMutation(_: MCPToolSnapshotMutationScope) throws {
        self.concurrentPrepareCount += 1
    }

    func completeMutation(_: MCPToolSnapshotMutationScope, succeeded _: Bool) async -> Bool {
        self.completionCount += 1
        return true
    }
}

private actor CapabilitySequenceBarrier {
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        self.blocked = true
        self.blockedWaiters.forEach { $0.resume() }
        self.blockedWaiters.removeAll()
        guard !self.released else { return }
        await withCheckedContinuation { self.releaseWaiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard !self.blocked else { return }
        await withCheckedContinuation { self.blockedWaiters.append($0) }
    }

    func release() {
        self.released = true
        self.releaseWaiters.forEach { $0.resume() }
        self.releaseWaiters.removeAll()
    }
}
