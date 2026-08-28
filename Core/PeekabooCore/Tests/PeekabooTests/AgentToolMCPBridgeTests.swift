import CoreGraphics
import Foundation
import ImageIO
import MCP
import Tachikoma
import TachikomaMCP
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@MainActor
struct AgentToolMCPBridgeTests {
    @Test
    func `Verification metadata becomes a structured agent receipt`() throws {
        let response = ToolResponse(
            content: [.text(text: "Window 7: Verification satisfied in its title", annotations: nil, _meta: nil)],
            meta: .object([
                "status": .string("unknown"),
                "target": .object(["pid": .int(42), "window_id": .int(7)]),
                "predicates": .array([.object([
                    "kind": .string("element_value"),
                    "selector": .object(["identifier": .string("total-field")]),
                    "expected_value": .string("42"),
                    "status": .string("unknown"),
                ])]),
            ]))

        let bridged = AgentToolMCPBridge.convert(response)
        let receipt = try #require(bridged.value.objectValue?["verification_receipt"]?.objectValue)

        #expect(receipt["status"]?.stringValue == "unknown")
        #expect(receipt["target"]?.objectValue?["pid"]?.intValue == 42)
        #expect(receipt["target"]?.objectValue?["window_id"]?.intValue == 7)
        #expect(receipt["predicates"]?.arrayValue?.first?.objectValue?["expected_value"]?.stringValue == "42")
        #expect(bridged.value.objectValue?["content"]?.stringValue?.contains("Verification satisfied") == true)
    }

    @Test
    func `Mixed MCP content preserves every text item and extracts real image pixels`() throws {
        let pngData = Self.makePNGData(width: 2, height: 2)
        let encodedImage = pngData.base64EncodedString()
        let response = ToolResponse.multiContent([
            .text(text: "first", annotations: nil, _meta: nil),
            .image(data: encodedImage, mimeType: "image/png", annotations: nil, _meta: nil),
            .text(text: "second", annotations: nil, _meta: nil),
        ])

        let bridged = AgentToolMCPBridge.convert(response)

        let values = try #require(bridged.value.arrayValue)
        #expect(values.map(\.stringValue) == ["first", "second"])
        #expect(bridged.images.count == 1)
        #expect(bridged.images[0].data == encodedImage)
        #expect(bridged.images[0].mimeType == "image/png")

        let toolJSON = try JSONSerialization.data(withJSONObject: bridged.value.toJSON())
        let toolText = try #require(String(data: toolJSON, encoding: .utf8))
        #expect(!toolText.contains(encodedImage))
    }

    @Test
    func `MCP errors preserve only safe dispatch metadata through turn boundary and trace`() async throws {
        let mcpTool = BridgeProbeTool(
            name: "click",
            response: ToolResponse.error(
                "Capture-owned coordinate reference is stale",
                meta: .object([
                    "mutation_dispatched": .bool(false),
                    "private_payload": .string("must not cross the agent bridge"),
                    "retry_safe": .bool(true),
                    "success": .bool(true),
                ])))
        let service = try PeekabooAgentService(services: PeekabooServices())
        let agentTool = PeekabooAgentService.$toolConstructionExecutionPolicy.withValue(.unrestricted) {
            service.makeAgentTool(from: mcpTool)
        }
        let call = AgentToolCall(id: "pre-dispatch-click", name: mcpTool.name, arguments: [:])
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: [agentTool],
            eventHandler: nil,
            sessionId: "bridge-error-trace",
            executionPolicy: .unrestricted)
        var messages: [ModelMessage] = []

        let step = try await service.handleToolCalls(
            stepText: "",
            toolCalls: [call],
            context: context,
            currentMessages: &messages,
            stepIndex: 0)
        let toolResult = try #require(step.toolResults.first)
        let payload = try #require(toolResult.result.objectValue)
        let failure = try #require(toolResult.failure)
        let metadata = try #require(payload["metadata"]?.objectValue)
        let boundary = try #require(metadata["turn_boundary"]?.objectValue)

        #expect(payload["error"]?.stringValue == "Capture-owned coordinate reference is stale")
        #expect(metadata["mutation_dispatched"]?.boolValue == false)
        #expect(metadata["retry_safe"]?.boolValue == true)
        #expect(metadata["private_payload"] == nil)
        #expect(boundary["disposition"]?.stringValue == "continue_next_step")
        #expect(failure.message == "Capture-owned coordinate reference is stale")
        #expect(toolResult.isError)

        let result = AgentExecutionResult(
            content: "",
            messages: messages,
            metadata: AgentMetadata(
                executionTime: 0,
                toolCallCount: 1,
                modelName: "test",
                startTime: Date(),
                endTime: Date()))
        let traceEntry = try #require(result.executionTrace().entries.first)
        let traceSummary = try #require(traceEntry.result?.objectValue)

        #expect(traceEntry.disposition == .executedFailed)
        #expect(traceEntry.isError == true)
        #expect(traceSummary["error_present"]?.boolValue == true)
        #expect(traceSummary["mutation_dispatched"]?.boolValue == false)
        #expect(traceSummary["retry_safe"]?.boolValue == true)
    }

    @Test
    func `Ordinary MCP errors remain failures without exposing arbitrary metadata`() {
        let bridged = AgentToolMCPBridge.convert(ToolResponse.error(
            "Ordinary failure",
            meta: .object([
                "nested": .object(["secret": .string("private")]),
                "number": .int(42),
            ])))
        let payload = bridged.value.objectValue

        #expect(payload?["success"]?.boolValue == false)
        #expect(payload?["error"]?.stringValue == "Ordinary failure")
        #expect(payload?["nested"] == nil)
        #expect(payload?["number"] == nil)
        #expect(PeekabooAgentService.resultEncodesToolFailure(bridged.value))
    }

    @Test
    func `Successful MCP mutation without dispatch metadata remains possibly dispatched`() async throws {
        let mcpTool = BridgeProbeTool(name: "click", response: .text("Clicked target"))
        let service = try PeekabooAgentService(services: PeekabooServices())
        let agentTool = PeekabooAgentService.$toolConstructionExecutionPolicy.withValue(.unrestricted) {
            service.makeAgentTool(from: mcpTool)
        }
        let call = AgentToolCall(id: "successful-click", name: mcpTool.name, arguments: [:])
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: [agentTool],
            eventHandler: nil,
            sessionId: "bridge-success-trace",
            executionPolicy: .unrestricted)
        var messages: [ModelMessage] = []

        let step = try await service.handleToolCalls(
            stepText: "",
            toolCalls: [call],
            context: context,
            currentMessages: &messages,
            stepIndex: 0)
        let toolResult = try #require(step.toolResults.first)
        let result = AgentExecutionResult(
            content: "",
            messages: messages,
            metadata: AgentMetadata(
                executionTime: 0,
                toolCallCount: 1,
                modelName: "test",
                startTime: Date(),
                endTime: Date()))
        let traceEntry = try #require(result.executionTrace().entries.first)

        #expect(!toolResult.isError)
        #expect(traceEntry.disposition == .executedSucceeded)
        #expect(traceEntry.isError == false)
        #expect(traceEntry.mutationDispatch == .possiblyDispatched)
        #expect(traceEntry.result?.objectValue?["mutation_dispatched"] == nil)
        #expect(traceEntry.result?.objectValue?["mutation_dispatch"]?.stringValue == "possibly_dispatched")
        #expect(traceEntry.result?.objectValue?["retry_safe"]?.boolValue == false)
    }

    @Test
    func `Inline See image redacts its local screenshot path from agent text`() {
        let encodedImage = Self.makePNGData(width: 1, height: 1).base64EncodedString()
        let response = ToolResponse.multiContent([
            .text(
                text: "Snapshot ID: abc\nScreenshot: /Users/example/private/screen.png\nElements found: 1",
                annotations: nil,
                _meta: nil),
            .image(data: encodedImage, mimeType: "image/png", annotations: nil, _meta: nil),
        ])

        let bridged = AgentToolMCPBridge.convert(response)

        #expect(bridged.value.stringValue?.contains("Screenshot: inline image attached") == true)
        #expect(bridged.value.stringValue?.contains("/Users/example") == false)
        #expect(bridged.images.count == 1)
    }

    @Test
    func `Text-only model is told pixels were withheld and incomplete AX cannot prove absence`() throws {
        let encodedImage = Self.makePNGData(width: 1, height: 1).base64EncodedString()
        let response = ToolResponse.multiContent([
            .text(
                text: """
                Snapshot ID: text-only
                Screenshot: /Users/example/private/screen.png
                Warning: AX tree incomplete at incomplete accessibility read. Retry the observation.
                """,
                annotations: nil,
                _meta: nil),
            .image(data: encodedImage, mimeType: "image/png", annotations: nil, _meta: nil),
        ])

        let bridged = AgentToolMCPBridge.convert(response, allowsModelImages: false)
        let values = try #require(bridged.value.arrayValue)
        let observation = try #require(values.first?.stringValue)
        let omission = try #require(try values.last?.toJSON() as? [String: Any])

        #expect(observation.contains("Screenshot: not delivered to this text-only model"))
        #expect(observation.contains(AgentToolMCPBridge.incompleteVisualEvidenceMarker))
        #expect(observation.contains("Missing text or elements do not prove absence"))
        #expect(!observation.contains("/Users/example"))
        #expect(omission["reason"] as? String == "agent model does not accept images")
        #expect(bridged.images.isEmpty)
    }

    @Test
    func `Large inline screenshots are downscaled before entering model context`() throws {
        let source = Self.makePNGData(width: 2000, height: 1000)
        let response = ToolResponse.image(data: source, mimeType: "image/png")

        let bridged = AgentToolMCPBridge.convert(response)

        let image = try #require(bridged.images.first)
        let output = try #require(Data(base64Encoded: image.data))
        let dimensions = try #require(Self.dimensions(of: output))
        #expect(max(dimensions.width, dimensions.height) <= AgentToolMCPBridge.maxImageDimension)
        #expect(output.count <= AgentToolMCPBridge.maxImageBytes)
        #expect(image.mimeType == "image/jpeg")
        #expect(bridged.value.stringValue == "Image attached.")
    }

    @Test
    func `Source image metadata rejects hostile dimensions frames and aggregate pixels`() {
        let maximumDimension = UInt64(AgentToolMCPBridge.maxSourceDimension)
        let safeEdge = UInt64(8192)

        #expect(AgentToolMCPBridge.sourceFrameDimensionsAreSafe([(width: safeEdge, height: safeEdge)]))
        #expect(!AgentToolMCPBridge.sourceFrameDimensionsAreSafe([
            (width: maximumDimension + 1, height: UInt64(1)),
        ]))
        #expect(!AgentToolMCPBridge.sourceFrameDimensionsAreSafe([
            (width: safeEdge, height: safeEdge + 1),
        ]))
        #expect(!AgentToolMCPBridge.sourceFrameDimensionsAreSafe(
            Array(repeating: (width: UInt64(1), height: UInt64(1)), count: 33)))
        #expect(!AgentToolMCPBridge.sourceFrameDimensionsAreSafe([
            (width: safeEdge, height: safeEdge),
            (width: safeEdge, height: safeEdge),
            (width: UInt64(1), height: UInt64(1)),
        ]))
        #expect(!AgentToolMCPBridge.sourceFrameDimensionsAreSafe([
            (width: UInt64.max, height: UInt64.max),
        ]))
    }

    @Test
    func `Oversized animation is rejected before delivery and incomplete AX remains ungrounded`() throws {
        let encodedImage = Self.makeGIFData(frameCount: 33).base64EncodedString()
        let response = ToolResponse.multiContent([
            .text(
                text: "Screenshot: /tmp/animated.gif\nWarning: AX tree incomplete at time deadline.",
                annotations: nil,
                _meta: nil),
            .image(data: encodedImage, mimeType: "image/gif", annotations: nil, _meta: nil),
        ])

        let bridged = AgentToolMCPBridge.convert(response, allowsModelImages: true)
        let values = try #require(bridged.value.arrayValue)
        let observation = try #require(values.first?.stringValue)
        let omission = try #require(try values.last?.toJSON() as? [String: Any])

        #expect(observation.contains("Screenshot: inline image unavailable"))
        #expect(observation.contains(AgentToolMCPBridge.incompleteVisualEvidenceMarker))
        #expect(omission["reason"] as? String == "invalid or oversized inline data")
        #expect(bridged.images.isEmpty)
    }

    @Test
    func `Resources do not inline blobs or secret-bearing local URLs`() throws {
        let response = ToolResponse.multiContent([
            .resource(resource: .binary(
                Data("private bytes".utf8),
                uri: "file:///Users/example/private.bin",
                mimeType: "application/octet-stream")),
            .resourceLink(
                uri: "https://user:password@example.com/help?token=secret#fragment",
                name: "help"),
        ])

        let bridged = AgentToolMCPBridge.convert(response)
        let jsonData = try JSONSerialization.data(withJSONObject: bridged.value.toJSON())
        let json = try #require(String(data: jsonData, encoding: .utf8))
        let resources = try #require(JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]])

        #expect(json.contains("<local resource>"))
        #expect(resources.last?["uri"] as? String == "https://example.com/help")
        #expect(!json.contains("private bytes"))
        #expect(!json.contains("password"))
        #expect(!json.contains("secret"))
    }

    @Test
    func `Agent turn receives pixels after tool result then removes them once consumed`() async throws {
        let imageData = Self.makePNGData(width: 2, height: 2)
        let mcpTool = BridgeProbeTool(response: ToolResponse.multiContent([
            .text(text: "structured observation", annotations: nil, _meta: nil),
            .image(data: imageData.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil),
        ]))
        let service = try PeekabooAgentService(services: PeekabooServices())
        let agentTool = PeekabooAgentService.$toolConstructionExecutionPolicy.withValue(.unrestricted) {
            service.makeAgentTool(from: mcpTool)
        }
        let call = AgentToolCall(id: "probe-call", name: mcpTool.name, arguments: [:])
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: [agentTool],
            eventHandler: nil,
            sessionId: "multimodal-test",
            executionPolicy: .unrestricted)
        var messages: [ModelMessage] = []
        #expect(await AgentToolMCPImageStore.shared.register(executionID: context.imageContextID))

        let step = try await service.handleToolCalls(
            stepText: "",
            toolCalls: [call],
            context: context,
            currentMessages: &messages,
            stepIndex: 0)

        #expect(step.toolResults.first?.result.stringValue == "structured observation")
        #expect(messages.map(\.role) == [.assistant, .tool, .user])
        let imageParts = messages.last?.content.compactMap { part -> ModelMessage.ContentPart.ImageContent? in
            guard case let .image(image) = part else { return nil }
            return image
        }
        #expect(imageParts?.count == 1)
        #expect(imageParts?.first?.data == imageData.base64EncodedString())
        let attribution = messages.last?.content.compactMap { part -> String? in
            guard case let .text(text) = part else { return nil }
            return text
        }.joined(separator: "\n")
        #expect(attribution?.contains("bridge_probe") == true)
        #expect(attribution?.contains("probe-call") == true)

        messages.removeConsumedAgentToolImageContext()
        #expect(messages.map(\.role) == [.assistant, .tool])
        await AgentToolMCPImageStore.shared.close(executionID: context.imageContextID)
    }

    @Test
    func `Invalid inline screenshot reports unavailable without leaking its local path`() {
        let response = ToolResponse.multiContent([
            .text(
                text: "Screenshot: /Users/example/private/screen.png",
                annotations: nil,
                _meta: nil),
            .image(data: "not-base64", mimeType: "image/png", annotations: nil, _meta: nil),
        ])

        let bridged = AgentToolMCPBridge.convert(response)

        let values = bridged.value.arrayValue
        #expect(values?.first?.stringValue == "Screenshot: inline image unavailable")
        #expect(bridged.images.isEmpty)
        #expect(!String(describing: bridged.value).contains("/Users/example"))
    }

    @Test
    func `Inline image MIME type follows decoded bytes instead of an incorrect declaration`() {
        let imageData = Self.makePNGData(width: 2, height: 2)
        let response = ToolResponse.image(data: imageData, mimeType: "image/jpeg")

        let bridged = AgentToolMCPBridge.convert(response)

        #expect(bridged.images.first?.mimeType == "image/png")
        #expect(bridged.images.first?.data == imageData.base64EncodedString())
    }

    @Test
    func `Loop checkpoints and persistent history omit unconsumed transient pixels`() async throws {
        let imageData = Self.makePNGData(width: 2, height: 2).base64EncodedString()
        let transientMessage = ModelMessage(
            role: .user,
            content: [
                .text("Visual output"),
                .image(ModelMessage.ContentPart.ImageContent(data: imageData, mimeType: "image/png")),
            ],
            metadata: MessageMetadata(customData: [
                "peekaboo.agent.transient_tool_images": "true",
            ]))
        let durableMessages = [ModelMessage.system("system"), ModelMessage.user("task")]
        let state = PeekabooAgentService.StreamingLoopState(messages: durableMessages + [transientMessage])
        let sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-multimodal-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        let sessionManager = try AgentSessionManager(sessionDirectory: sessionDirectory)
        let service = try PeekabooAgentService(
            services: PeekabooServices(),
            sessionManager: sessionManager)

        let outcome = service.makeLoopOutcome(state: state, reachedStepLimit: true)
        let now = Date()
        let context = PeekabooAgentService.SessionContext(
            id: "transient-image-session",
            isPersistent: true,
            messages: durableMessages,
            createdAt: now,
            executionStart: now,
            metadata: SessionMetadata(),
            modelIdentity: PeekabooAgentService.PersistedModelIdentity(
                displayName: "test-model",
                selection: nil,
                endpointIdentity: nil,
                providerIdentity: nil),
            storedToolExecutionPolicy: .backgroundOnly,
            toolExecutionPolicy: .backgroundOnly,
            provider: nil,
            executionGeneration: nil)
        try service.saveExecutionSession(
            context: context,
            model: .openai(.gpt55),
            finalMessages: durableMessages + [transientMessage],
            endTime: now,
            toolCallCount: 0,
            usage: nil,
            status: "failed")
        let savedSession = try #require(try await sessionManager.loadSession(id: context.id))

        #expect(state.messages.count == 3)
        #expect(outcome.messages == durableMessages)
        #expect((durableMessages + [transientMessage]).removingConsumedAgentToolImageContext() == durableMessages)
        #expect(savedSession.messages == durableMessages)
    }

    @Test
    func `Transient image store isolates concurrent executions of the same session`() async {
        let store = AgentToolMCPImageStore()
        let firstImage = ModelMessage.ContentPart.ImageContent(data: "first", mimeType: "image/png")
        let secondImage = ModelMessage.ContentPart.ImageContent(data: "second", mimeType: "image/png")
        let firstKey = AgentToolMCPImageStore.Key(
            sessionID: "shared-session",
            executionID: "first-execution",
            stepIndex: 0,
            toolCallID: "reused-call-id")
        let secondKey = AgentToolMCPImageStore.Key(
            sessionID: "shared-session",
            executionID: "second-execution",
            stepIndex: 0,
            toolCallID: "reused-call-id")

        #expect(await store.register(executionID: firstKey.executionID))
        #expect(await store.register(executionID: secondKey.executionID))
        #expect(await store.store([firstImage], for: firstKey) == .admitted)
        #expect(await store.store([secondImage], for: secondKey) == .admitted)

        let storedFirstImage = await store.take(for: firstKey)
        let storedSecondImage = await store.take(for: secondKey)
        #expect(storedFirstImage == [firstImage])
        #expect(storedSecondImage == [secondImage])
    }

    @Test
    func `full image store preserves pending entries and explicitly omits the current response`() async throws {
        let capacity = 3
        let store = AgentToolMCPImageStore(maximumEntries: capacity)
        let imageData = Self.makePNGData(width: 2, height: 2).base64EncodedString()
        let response = ToolResponse.multiContent([
            .text(text: "Screenshot: /tmp/pending.png", annotations: nil, _meta: nil),
            .image(data: imageData, mimeType: "image/png", annotations: nil, _meta: nil),
        ])
        let executionID = "bounded-execution"
        let keys = (0...(capacity + 1)).map { index in
            AgentToolMCPImageStore.Key(
                sessionID: "bounded-session",
                executionID: executionID,
                stepIndex: 0,
                toolCallID: "call-\(index)")
        }
        #expect(await store.register(executionID: executionID))
        for index in 0..<capacity {
            let value = await convertToolResponseToAgentToolResultAsync(
                response,
                executionContext: Self.imageExecutionContext(key: keys[index]),
                imageStore: store)
            #expect(value.stringValue?.contains("inline image attached") == true)
        }

        let overflow = await convertToolResponseToAgentToolResultAsync(
            response,
            executionContext: Self.imageExecutionContext(key: keys[capacity]),
            imageStore: store)
        let overflowJSON = try Self.jsonString(overflow)
        #expect(overflowJSON.contains("transient image capacity reached"))
        #expect(overflowJSON.contains("\"attached\":false"))
        #expect(!overflowJSON.contains("inline image attached"))
        #expect(await store.take(for: keys[capacity]).isEmpty)

        #expect(await store.take(for: keys[0]).map(\.data) == [imageData])
        let admittedAfterConsumption = await convertToolResponseToAgentToolResultAsync(
            response,
            executionContext: Self.imageExecutionContext(key: keys[capacity + 1]),
            imageStore: store)
        #expect(admittedAfterConsumption.stringValue?.contains("inline image attached") == true)

        for key in [keys[1], keys[2], keys[capacity + 1]] {
            #expect(await store.take(for: key).map(\.data) == [imageData])
        }
    }

    @Test
    func `image result before registration is explicitly omitted and never stored`() async throws {
        let store = AgentToolMCPImageStore(maximumEntries: 1)
        let imageData = Self.makePNGData(width: 2, height: 2).base64EncodedString()
        let response = ToolResponse.multiContent([
            .text(text: "Screenshot: /tmp/late.png", annotations: nil, _meta: nil),
            .image(data: imageData, mimeType: "image/png", annotations: nil, _meta: nil),
        ])
        let key = AgentToolMCPImageStore.Key(
            sessionID: "closed-session",
            executionID: "never-registered",
            stepIndex: 0,
            toolCallID: "late-call")

        let value = await convertToolResponseToAgentToolResultAsync(
            response,
            executionContext: Self.imageExecutionContext(key: key),
            imageStore: store)
        let json = try Self.jsonString(value)

        #expect(json.contains("image execution is not active or already closed"))
        #expect(json.contains("\"attached\":false"))
        #expect(!json.contains("inline image attached"))
        #expect(await store.take(for: key).isEmpty)
    }

    @Test
    func `live admitted image remains deliverable until consumed`() async throws {
        let store = AgentToolMCPImageStore(maximumEntries: 1)
        let image = ModelMessage.ContentPart.ImageContent(data: "live", mimeType: "image/png")
        let key = AgentToolMCPImageStore.Key(
            sessionID: "live-session",
            executionID: "live-execution",
            stepIndex: 0,
            toolCallID: "live-call")

        #expect(await store.register(executionID: key.executionID))
        #expect(await store.store([image], for: key) == .admitted)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await store.take(for: key) == [image])
    }

    @Test
    func `close removes only its execution and preserves other sessions`() async {
        let store = AgentToolMCPImageStore(maximumEntries: 4)
        let image = ModelMessage.ContentPart.ImageContent(data: "pending", mimeType: "image/png")
        let discardedKeys = (0..<2).map { index in
            AgentToolMCPImageStore.Key(
                sessionID: "first-session",
                executionID: "discarded-execution",
                stepIndex: index,
                toolCallID: "discarded-\(index)")
        }
        let sameSessionKey = AgentToolMCPImageStore.Key(
            sessionID: "first-session",
            executionID: "retained-execution",
            stepIndex: 0,
            toolCallID: "same-session")
        let otherSessionKey = AgentToolMCPImageStore.Key(
            sessionID: "second-session",
            executionID: "other-session-execution",
            stepIndex: 0,
            toolCallID: "other-session")
        for executionID in ["discarded-execution", "retained-execution", "other-session-execution"] {
            #expect(await store.register(executionID: executionID))
        }
        for key in discardedKeys + [sameSessionKey, otherSessionKey] {
            #expect(await store.store([image], for: key) == .admitted)
        }

        await store.close(executionID: "discarded-execution")
        for key in discardedKeys {
            #expect(await store.take(for: key).isEmpty)
        }
        #expect(await store.store([image], for: discardedKeys[0]) == .rejected(.executionNotActive))
        let replacementKey = AgentToolMCPImageStore.Key(
            sessionID: "replacement-session",
            executionID: "replacement-execution",
            stepIndex: 0,
            toolCallID: "replacement")
        #expect(await store.register(executionID: replacementKey.executionID))
        #expect(await store.store([image], for: replacementKey) == .admitted)
        #expect(await store.take(for: sameSessionKey) == [image])
        #expect(await store.take(for: otherSessionKey) == [image])
        #expect(await store.take(for: replacementKey) == [image])
    }

    @Test
    func `three read-only image calls retain ordered tool and call attribution without turn truncation`() async throws {
        let store = AgentToolMCPImageStore(maximumEntries: 3)
        let service = try PeekabooAgentService(services: PeekabooServices())
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: [],
            eventHandler: nil,
            sessionId: "three-image-calls",
            executionPolicy: .unrestricted)
        let calls = [
            AgentToolCall(id: "see-1", name: "see", arguments: [:]),
            AgentToolCall(id: "image-2", name: "image", arguments: [:]),
            AgentToolCall(id: "inspect-3", name: "inspect_ui", arguments: [:]),
        ]
        #expect(await store.register(executionID: context.imageContextID))
        for (index, call) in calls.enumerated() {
            let key = AgentToolMCPImageStore.Key(
                sessionID: context.sessionId,
                executionID: context.imageContextID,
                stepIndex: 4,
                toolCallID: call.id)
            #expect(await store.store([
                ModelMessage.ContentPart.ImageContent(data: "pixels-\(index)", mimeType: "image/png"),
            ], for: key) == .admitted)
        }
        var messages: [ModelMessage] = []

        await service.appendAgentToolImageContext(
            toolCalls: calls,
            context: context,
            stepIndex: 4,
            imageStore: store,
            to: &messages)

        let message = try #require(messages.last)
        let deliveredImages = message.content.compactMap { part -> ModelMessage.ContentPart.ImageContent? in
            guard case let .image(image) = part else { return nil }
            return image
        }
        let attribution = message.content.compactMap { part -> String? in
            guard case let .text(text) = part else { return nil }
            return text
        }.joined(separator: "\n")
        #expect(deliveredImages.map(\.data) == ["pixels-0", "pixels-1", "pixels-2"])
        #expect(attribution.contains("'see' (call ID see-1)"))
        #expect(attribution.contains("'image' (call ID image-2)"))
        #expect(attribution.contains("'inspect_ui' (call ID inspect-3)"))
    }

    @Test
    func `multiple images in one result explicitly mark bounded omission`() throws {
        let imageData = Self.makePNGData(width: 2, height: 2).base64EncodedString()
        let bridged = AgentToolMCPBridge.convert(ToolResponse.multiContent([
            .text(text: "Screenshot: /tmp/result.png", annotations: nil, _meta: nil),
            .image(data: imageData, mimeType: "image/png", annotations: nil, _meta: nil),
            .image(data: imageData, mimeType: "image/png", annotations: nil, _meta: nil),
        ]))

        #expect(bridged.images.count == 1)
        let json = try JSONSerialization.data(withJSONObject: bridged.value.toJSON())
        let description = try #require(String(data: json, encoding: .utf8))
        #expect(description.contains("inline image attached"))
        #expect(description.contains("per-response image limit reached"))
        #expect(description.contains("\"attached\":false"))
    }

    @Test
    func `Text-only OpenRouter model does not receive provider-wide vision payloads`() async throws {
        let store = AgentToolMCPImageStore()
        let service = try PeekabooAgentService(services: PeekabooServices())
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .openRouter(modelId: "text-only-model"),
            providerSupportsVision: true,
            tools: [],
            eventHandler: nil,
            sessionId: "provider-wide-vision",
            executionPolicy: .unrestricted)
        let toolCall = AgentToolCall(id: "see-call", name: "see", arguments: [:])
        let image = ModelMessage.ContentPart.ImageContent(data: "pixels", mimeType: "image/png")
        let key = AgentToolMCPImageStore.Key(
            sessionID: context.sessionId,
            executionID: context.imageContextID,
            stepIndex: 0,
            toolCallID: toolCall.id)
        #expect(await store.register(executionID: context.imageContextID))
        #expect(await store.store([image], for: key) == .admitted)
        var messages: [ModelMessage] = []

        await service.appendAgentToolImageContext(
            toolCalls: [toolCall],
            context: context,
            stepIndex: 0,
            imageStore: store,
            to: &messages)

        #expect(!context.supportsVision)
        #expect(messages.isEmpty)
    }

    @Test
    func `Text-only tool execution does not claim its MCP image was attached`() async throws {
        let imageData = Self.makePNGData(width: 2, height: 2)
        let mcpTool = BridgeProbeTool(response: ToolResponse.multiContent([
            .text(
                text: "Screenshot: /tmp/probe.png\nWarning: AX tree truncated at element count 1.",
                annotations: nil,
                _meta: nil),
            .image(data: imageData.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil),
        ]))
        let service = try PeekabooAgentService(services: PeekabooServices())
        let agentTool = PeekabooAgentService.$toolConstructionExecutionPolicy.withValue(.unrestricted) {
            service.makeAgentTool(from: mcpTool)
        }
        let call = AgentToolCall(id: "text-only-probe", name: mcpTool.name, arguments: [:])
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .openRouter(modelId: "text-only-model"),
            providerSupportsVision: true,
            tools: [agentTool],
            eventHandler: nil,
            sessionId: "text-only-tool-test",
            executionPolicy: .unrestricted)
        var messages: [ModelMessage] = []

        let step = try await service.handleToolCalls(
            stepText: "",
            toolCalls: [call],
            context: context,
            currentMessages: &messages,
            stepIndex: 0)

        let values = try #require(step.toolResults.first?.result.arrayValue)
        #expect(values.first?.stringValue?.contains("not delivered to this text-only model") == true)
        #expect(values.first?.stringValue?.contains(AgentToolMCPBridge.incompleteVisualEvidenceMarker) == true)
        #expect(messages.map(\.role) == [.assistant, .tool])
    }

    private static func imageExecutionContext(key: AgentToolMCPImageStore.Key) -> ToolExecutionContext {
        ToolExecutionContext(
            sessionId: key.sessionID,
            stepIndex: key.stepIndex,
            metadata: [
                "toolCallId": key.toolCallID,
                "imageContextId": key.executionID,
                "supportsVision": "true",
            ])
    }

    private static func jsonString(_ value: AnyAgentToolValue) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value.toJSON(), options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
    }

    private static func makePNGData(width: Int, height: Int) -> Data {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0x7F, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let image = context.makeImage()
        else {
            fatalError("Failed to make test image")
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil)
        else {
            fatalError("Failed to make PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            fatalError("Failed to encode test PNG")
        }
        return data as Data
    }

    private static func makeGIFData(frameCount: Int) -> Data {
        let pngData = Self.makePNGData(width: 1, height: 1)
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            fatalError("Failed to make GIF source image")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.gif.identifier as CFString,
            frameCount,
            nil)
        else {
            fatalError("Failed to make GIF destination")
        }
        for _ in 0..<frameCount {
            CGImageDestinationAddImage(destination, image, nil)
        }
        guard CGImageDestinationFinalize(destination) else {
            fatalError("Failed to encode GIF")
        }
        return data as Data
    }

    private static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else {
            return nil
        }
        return (width, height)
    }
}

private struct BridgeProbeTool: MCPTool {
    let name: String
    let description = "Returns deterministic mixed MCP content"
    let response: ToolResponse

    init(name: String = "bridge_probe", response: ToolResponse) {
        self.name = name
        self.response = response
    }

    var inputSchema: Value {
        SchemaBuilder.object(properties: [:], required: [])
    }

    func execute(arguments _: ToolArguments) async throws -> ToolResponse {
        self.response
    }
}
