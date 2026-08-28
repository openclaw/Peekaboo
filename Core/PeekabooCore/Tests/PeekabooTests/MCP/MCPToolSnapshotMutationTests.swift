import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import Tachikoma
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct MCPToolSnapshotMutationTests {
    private let uiSnapshots = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner())

    @Test
    func `Mutation policy distinguishes reads mutations and fresh observations`() {
        #expect(Self.effect("app", ["action": "list"]) == .none)
        #expect(Self.effect("app", ["action": "launch"]) == .conditionalMutation)
        #expect(Self.effect("app", ["action": "launch", "foreground": true]) == .mutation)
        #expect(Self.effect("app", ["action": "launch", "newInstance": true]) == .mutation)
        #expect(Self.effect("app", ["action": "launch", "openTargets": ["https://example.com"]]) == .mutation)
        #expect(Self.effect("menu", ["action": "click"]) == .mutation)
        #expect(Self.effect("menu", ["action": "list"]) == .none)
        #expect(Self.effect("menu", ["action": "list", "foreground": true]) == .mutation)
        #expect(Self.effect("inspect_ui", [:]) == .freshObservation)
        #expect(Self.effect("see", [:]) == .freshObservation)
        #expect(Self.effect("inspect_ui", ["web_focus": true]) == .mutationProducingFreshObservation)
        #expect(Self.effect("see", ["web_focus": true]) == .mutationProducingFreshObservation)
        #expect(Self.effect("capture", [:]) == .none)
        #expect(Self.effect("capture", ["source": "video"]) == .none)
        #expect(Self.effect("capture", ["capture_focus": "background"]) == .none)
        #expect(Self.effect("capture", ["capture_focus": "foreground"]) == .mutation)
        #expect(Self.effect("image", [:]) == .none)
        #expect(Self.effect("image", ["capture_focus": "auto"]) == .mutation)
        #expect(Self.effect("image", ["capture_focus": "background"]) == .none)
        #expect(Self.effect("image", ["capture_focus": "foreground"]) == .mutation)
        #expect(Self.effect("dialog", ["action": "list"]) == .none)
        #expect(Self.effect("dialog", ["action": "list", "app": "TextEdit"]) == .none)
        #expect(Self.effect("dialog", ["action": "list", "window_id": 42]) == .none)
        #expect(Self.effect("clipboard", ["action": "get"]) == .none)
        #expect(Self.effect("clipboard", ["action": "save"]) == .none)
        #expect(Self.effect("clipboard", ["action": "set"]) == .mutation)
        #expect(Self.effect("clipboard", ["action": "clear"]) == .mutation)
        #expect(Self.effect("clipboard", ["action": "restore"]) == .mutation)
        #expect(Self.effect("clipboard", ["action": "load"]) == .none)
        #expect(Self.effect("browser", ["action": "snapshot"]) == .mutation)
        #expect(Self.effect("browser", ["action": "click"]) == .mutation)
        #expect(Self.effect("agent", [:]) == .none)
        #expect(Self.effect("press", [:]) == .mutation)
        #expect(Self.effect("action", [:]) == .mutation)
    }

    @Test
    func `Every cataloged MCP tool has an explicit snapshot effect classification`() {
        let context = MCPToolContext(services: PeekabooServices())
        let tools = MCPToolCatalog.unfilteredTools(context: context)

        for tool in tools {
            let effect = MCPToolSnapshotMutationPolicy.explicitEffect(
                toolName: tool.name,
                arguments: ToolArguments(raw: [:]))
            #expect(effect != nil, "Missing snapshot effect classification for \(tool.name)")
        }
    }

    @Test
    func `Service context inherits its concrete agent gate unless explicitly overridden`() throws {
        let services = PeekabooServices()
        let agentGate = MCPToolSnapshotExecutionGate()
        let agent = try PeekabooAgentService(
            services: services,
            snapshotExecutionGate: agentGate)
        services.agent = agent

        let inheritedContext = MCPToolContext(services: services)
        let explicitGate = MCPToolSnapshotExecutionGate()
        let explicitContext = MCPToolContext(
            services: services,
            snapshotExecutionGate: explicitGate)
        let designatedContext = MCPToolContext(
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
            agent: agent,
            permissions: services.permissions,
            clipboard: services.clipboard,
            browser: services.browser)

        #expect(inheritedContext.snapshotExecutionGate === agentGate)
        #expect(explicitContext.snapshotExecutionGate === explicitGate)
        #expect(designatedContext.snapshotExecutionGate === agentGate)
    }

    @Test
    func `Per-tool execution completes unique mutation scopes for success and error responses`() async throws {
        let coordinator = RecordingMutationCoordinator()
        let context = await MCPToolTestHelpers.makeContext(
            snapshotMutationCoordinator: coordinator,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .unrestricted)

        _ = try await context.execute(
            tool: StubMCPTool(name: "click", responseIsError: false),
            arguments: ToolArguments(raw: [:]))
        _ = try await context.execute(
            tool: StubMCPTool(name: "type", responseIsError: true),
            arguments: ToolArguments(raw: [:]))

        #expect(coordinator.completions.count == 2)
        #expect(Set(coordinator.completions.map(\.scope.id)).count == 2)
        #expect(coordinator.completions.map(\.succeeded) == [true, false])
    }

    @Test
    func `Fresh observation reports an error when snapshot publication fails`() async throws {
        let manager = self.uiSnapshots
        await manager.removeAllSnapshots()
        let coordinator = RecordingMutationCoordinator(completionResult: false)
        let context = await MCPToolTestHelpers.makeContext(
            snapshotMutationCoordinator: coordinator,
            snapshotOwner: manager.owner,
            executionPolicy: .unrestricted)
        let snapshotID = "unpublished-snapshot"

        let response = try await context.execute(
            tool: StubMCPTool(
                name: "see",
                responseSnapshotID: snapshotID,
                createdUISnapshotID: snapshotID,
                uiSnapshots: manager,
                expectsObservationStart: true),
            arguments: ToolArguments(raw: ["web_focus": true]))

        #expect(response.isError)
        #expect(coordinator.completions.map(\.succeeded) == [true, false])
        #expect(Set(coordinator.completions.map(\.scope.id)).count == 1)
        #expect(await manager.getSnapshot(id: nil) == nil)
        await manager.removeAllSnapshots()
    }

    @Test(arguments: ["click", "type", "drag", "shell"])
    func `Ordinary mutation completion failure warns without inviting a retry`(toolName: String) async throws {
        let coordinator = RecordingMutationCoordinator(completionResult: false)
        let gate = MCPToolSnapshotExecutionGate()
        let context = await MCPToolTestHelpers.makeContext(
            snapshotMutationCoordinator: coordinator,
            snapshotExecutionGate: gate,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .unrestricted)

        let response = try await context.execute(
            tool: StubMCPTool(name: toolName),
            arguments: ToolArguments(raw: [:]))

        #expect(!response.isError)
        #expect(Self.snapshotInvalidationStatus(response) == "pending_retry")
        #expect(Self.snapshotInvalidationFlag(response, key: "tool_executed") == true)
        #expect(Self.snapshotInvalidationFlag(response, key: "retry_tool") == false)
        #expect(Self.firstResponseText(response)?.contains("Do not retry this mutation") == true)
        let bridgedJSON = try convertToolResponseToAgentToolResult(response).toJSON()
        let bridgedObject = try #require(bridgedJSON as? [String: Any])
        let bridgedText = try #require(bridgedObject["text"] as? String)
        #expect(bridgedText.contains("Do not retry this mutation"))
        #expect(coordinator.completions.map(\.succeeded) == [true])
        #expect(Set(coordinator.completions.map(\.scope.id)).count == 1)
        #expect(await Self.gateIsAvailable(gate))
    }

    @Test
    func `Pending invalidation blocks stale observation until cleanup retry succeeds`() async throws {
        let coordinator = SequencedMutationCoordinator(results: [false, false, true, true])
        let gate = MCPToolSnapshotExecutionGate()
        let context = await MCPToolTestHelpers.makeContext(
            snapshotMutationCoordinator: coordinator,
            snapshotExecutionGate: gate,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .unrestricted)

        let mutationResponse = try await context.execute(
            tool: StubMCPTool(name: "click"),
            arguments: ToolArguments(raw: [:]))
        #expect(!mutationResponse.isError)
        #expect(Self.snapshotInvalidationStatus(mutationResponse) == "pending_retry")

        let observationLog = ToolExecutionLog()
        let observation = StubMCPTool(name: "see", label: "fresh-observation", log: observationLog)
        let blockedResponse = try await context.execute(
            tool: observation,
            arguments: ToolArguments(raw: [:]))
        #expect(blockedResponse.isError)
        #expect(Self.snapshotInvalidationStatus(blockedResponse) == "pending_retry")
        #expect(Self.snapshotInvalidationFlag(blockedResponse, key: "tool_executed") == false)
        #expect(Self.snapshotInvalidationFlag(blockedResponse, key: "retry_tool") == true)
        #expect(Self.responseText(blockedResponse).contains("was not executed"))
        #expect(await observationLog.events.isEmpty)

        let successfulResponse = try await context.execute(
            tool: observation,
            arguments: ToolArguments(raw: [:]))
        #expect(!successfulResponse.isError)
        #expect(await observationLog.events == ["fresh-observation:start", "fresh-observation:end"])
        #expect(coordinator.completions.map(\.succeeded) == [true, false, false])
        #expect(await Self.gateIsAvailable(gate))
    }

    @Test
    func `Pending invalidation retries against its originating snapshot owner`() async throws {
        let coordinator = SequencedMutationCoordinator(results: [false, true])
        let gate = MCPToolSnapshotExecutionGate()
        let snapshots = InMemorySnapshotManager()
        let firstSnapshots = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner())
        let secondSnapshots = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner())
        await firstSnapshots.removeAllSnapshots()
        await secondSnapshots.removeAllSnapshots()
        let firstSnapshot = await firstSnapshots.createSnapshot(id: "session-a")
        let secondSnapshot = await secondSnapshots.createSnapshot(id: "session-b")
        let firstContext = await MCPToolTestHelpers.makeContext(
            snapshots: snapshots,
            snapshotMutationCoordinator: coordinator,
            snapshotExecutionGate: gate,
            snapshotOwner: firstSnapshots.owner,
            executionPolicy: .unrestricted)
        let secondContext = await MCPToolTestHelpers.makeContext(
            snapshots: snapshots,
            snapshotMutationCoordinator: coordinator,
            snapshotExecutionGate: gate,
            snapshotOwner: secondSnapshots.owner,
            executionPolicy: .unrestricted)

        let mutationResponse = try await firstContext.execute(
            tool: StubMCPTool(name: "click"),
            arguments: ToolArguments(raw: [:]))
        #expect(!mutationResponse.isError)
        #expect(Self.snapshotInvalidationStatus(mutationResponse) == "pending_retry")
        #expect(await firstSnapshots.getSnapshot(id: nil) == nil)
        #expect(await firstSnapshots.getSnapshot(id: firstSnapshot.id) === firstSnapshot)
        #expect(await secondSnapshots.getSnapshot(id: nil) === secondSnapshot)

        let observationResponse = try await secondContext.execute(
            tool: StubMCPTool(name: "see"),
            arguments: ToolArguments(raw: [:]))

        #expect(!observationResponse.isError)
        #expect(await firstSnapshots.getSnapshot(id: nil) == nil)
        #expect(await firstSnapshots.getSnapshot(id: firstSnapshot.id) === firstSnapshot)
        #expect(await secondSnapshots.getSnapshot(id: nil) === secondSnapshot)
        #expect(coordinator.completions.map(\.succeeded) == [true, false])

        await firstSnapshots.removeOwner()
        await secondSnapshots.removeOwner()
    }

    @Test
    func `Original mutation error records pending cleanup without replacing the error`() async throws {
        let coordinator = RecordingMutationCoordinator(completionResult: false)
        let context = await MCPToolTestHelpers.makeContext(
            snapshotMutationCoordinator: coordinator,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .unrestricted)

        let response = try await context.execute(
            tool: StubMCPTool(name: "click", responseIsError: true),
            arguments: ToolArguments(raw: [:]))

        #expect(response.isError)
        #expect(Self.responseText(response).contains("stub error"))
        #expect(coordinator.completions.map(\.succeeded) == [false])

        let blockedLog = ToolExecutionLog()
        let blockedResponse = try await context.execute(
            tool: StubMCPTool(name: "see", label: "blocked", log: blockedLog),
            arguments: ToolArguments(raw: [:]))
        #expect(blockedResponse.isError)
        #expect(await blockedLog.events.isEmpty)
        #expect(coordinator.completions.map(\.succeeded) == [false, false])
    }

    @Test
    func `Cancellation during pending cleanup preserves retry and releases gate`() async throws {
        let coordinator = SequencedMutationCoordinator(
            results: [false, true, true, true],
            cancelOnCall: 2)
        let gate = MCPToolSnapshotExecutionGate()
        let context = await MCPToolTestHelpers.makeContext(
            snapshotMutationCoordinator: coordinator,
            snapshotExecutionGate: gate,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .unrestricted)

        let mutationResponse = try await context.execute(
            tool: StubMCPTool(name: "click"),
            arguments: ToolArguments(raw: [:]))
        #expect(!mutationResponse.isError)

        let observationLog = ToolExecutionLog()
        let observation = StubMCPTool(name: "see", label: "after-cancellation", log: observationLog)
        let canceledRetry = Task {
            try await context.execute(tool: observation, arguments: ToolArguments(raw: [:]))
        }
        await #expect(throws: CancellationError.self) {
            try await canceledRetry.value
        }
        #expect(await observationLog.events.isEmpty)

        let successfulResponse = try await context.execute(
            tool: observation,
            arguments: ToolArguments(raw: [:]))
        #expect(!successfulResponse.isError)
        #expect(await observationLog.events == ["after-cancellation:start", "after-cancellation:end"])
        #expect(await Self.gateIsAvailable(gate))
    }

    @Test
    func `Mutation and observation tool executions serialize on their shared gate`() async throws {
        let log = ToolExecutionLog()
        let gate = MCPToolSnapshotExecutionGate()
        let context = await MCPToolTestHelpers.makeContext(
            snapshotExecutionGate: gate,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .unrestricted)
        let observation = StubMCPTool(name: "inspect_ui", label: "observe", delay: .milliseconds(40), log: log)
        let mutation = StubMCPTool(name: "click", label: "mutate", log: log)

        async let observationResult = context.execute(tool: observation, arguments: ToolArguments(raw: [:]))
        try await Task.sleep(for: .milliseconds(5))
        async let mutationResult = context.execute(tool: mutation, arguments: ToolArguments(raw: [:]))
        _ = try await (observationResult, mutationResult)

        #expect(await log.events == ["observe:start", "observe:end", "mutate:start", "mutate:end"])
    }

    @Test
    func `Direct observation cannot overlap a nested agent mutation`() async throws {
        let log = ToolExecutionLog()
        let gate = MCPToolSnapshotExecutionGate()
        let services = PeekabooServices()
        let agent = try PeekabooAgentService(
            services: services,
            snapshotExecutionGate: gate)
        let directContext = MCPToolContext(
            services: services,
            snapshotExecutionGate: gate)
        let nestedAgentContext = PeekabooAgentService.$toolConstructionExecutionPolicy.withValue(.unrestricted) {
            agent.makeToolContext()
        }
        let directObservation = StubMCPTool(
            name: "see",
            label: "direct-see",
            delay: .milliseconds(40),
            log: log)
        let nestedMutation = StubMCPTool(
            name: "click",
            label: "nested-click",
            log: log)

        #expect(directContext.snapshotExecutionGate === nestedAgentContext.snapshotExecutionGate)
        async let observationResult = directContext.execute(
            tool: directObservation,
            arguments: ToolArguments(raw: [:]))
        try await Task.sleep(for: .milliseconds(5))
        async let mutationResult = nestedAgentContext.execute(
            tool: nestedMutation,
            arguments: ToolArguments(raw: [:]))
        _ = try await (observationResult, mutationResult)

        let events = await log.events
        #expect(events == [
            "direct-see:start",
            "direct-see:end",
            "nested-click:start",
            "nested-click:end",
        ])
    }

    @Test
    func `Outer agent execution remains ungated for its nested mutation`() async throws {
        let log = ToolExecutionLog()
        let context = await MCPToolTestHelpers.makeContext(
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .unrestricted)

        let response = try await context.execute(
            tool: NestedAgentMCPTool(context: context, log: log),
            arguments: ToolArguments(raw: [:]))

        #expect(!response.isError)
        #expect(await log.events == [
            "agent:start",
            "nested-click:start",
            "nested-click:end",
            "agent:end",
        ])
    }

    @Test
    func `Canceled waiter never executes after the gate becomes available`() async throws {
        let log = ToolExecutionLog()
        let gate = MCPToolSnapshotExecutionGate()
        let context = await MCPToolTestHelpers.makeContext(
            snapshotExecutionGate: gate,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .unrestricted)
        try await gate.acquire()

        let waiting = Task {
            try await context.execute(
                tool: StubMCPTool(name: "click", label: "canceled", log: log),
                arguments: ToolArguments(raw: [:]))
        }
        try await Task.sleep(for: .milliseconds(10))
        waiting.cancel()
        await gate.release()

        await #expect(throws: CancellationError.self) {
            try await waiting.value
        }
        #expect(await log.events.isEmpty)
    }

    @Test
    func `Cancellation swallowed by a tool cannot publish success or retain the gate`() async throws {
        let coordinator = RecordingMutationCoordinator()
        let gate = MCPToolSnapshotExecutionGate()
        let context = await MCPToolTestHelpers.makeContext(
            snapshotMutationCoordinator: coordinator,
            snapshotExecutionGate: gate,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .unrestricted)
        let canceledExecution = Task {
            try await context.execute(
                tool: StubMCPTool(name: "click", cancelsCurrentTask: true),
                arguments: ToolArguments(raw: [:]))
        }

        await #expect(throws: CancellationError.self) {
            try await canceledExecution.value
        }
        #expect(coordinator.completions.map(\.succeeded) == [false])

        let log = ToolExecutionLog()
        let followUpCompleted = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    _ = try await context.execute(
                        tool: StubMCPTool(name: "click", label: "follow-up", log: log),
                        arguments: ToolArguments(raw: [:]))
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(250))
                return false
            }

            let completed = await group.next() ?? false
            group.cancelAll()
            return completed
        }

        #expect(followUpCompleted)
        #expect(await log.events == ["follow-up:start", "follow-up:end"])
        #expect(coordinator.completions.map(\.succeeded) == [false, true])
    }

    @Test
    func `Cancellation after dispatch preserves a canonical failure response`() async throws {
        let coordinator = RecordingMutationCoordinator()
        let context = await MCPToolTestHelpers.makeContext(
            snapshotMutationCoordinator: coordinator,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .unrestricted)
        let targetReceipt = DesktopActionTargetReceipt(
            processIdentifier: 42,
            processStartIdentity: 420,
            windowID: 71)
        let failure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "The exact dispatched result must survive caller cancellation.")
            .attributed(to: targetReceipt)
        let canonicalResponse = try MCPToolResponseMetadataProjector.errorResponse(
            for: failure,
            invalidatedSnapshotID: nil)

        let returned = try await Task {
            try await context.execute(
                tool: StubMCPTool(
                    name: "click",
                    providedResponse: canonicalResponse,
                    cancelsCurrentTask: true),
                arguments: ToolArguments(raw: [:]))
        }.value

        #expect(returned.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(failure.outcome, in: returned)
        #expect(returned.meta?.objectValue?["target_receipt"] != nil)
        #expect(coordinator.completions.map(\.succeeded) == [false])
    }

    @Test
    func `Cancellation during completion preserves a canonical mutation response`() async throws {
        let coordinator = CancelingMutationCoordinator()
        let context = await MCPToolTestHelpers.makeContext(
            snapshotMutationCoordinator: coordinator,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .unrestricted)
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let canonicalResponse = try ToolResponse.text(
            "dispatched",
            meta: MCPToolResponseMetadataProjector.metadata(outcome: outcome))

        let returned = try await Task {
            try await context.execute(
                tool: StubMCPTool(name: "click", providedResponse: canonicalResponse),
                arguments: ToolArguments(raw: [:]))
        }.value

        #expect(!returned.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: returned)
        #expect(coordinator.completions.map(\.succeeded) == [true])
    }

    @Test
    func `Background mutation rejects a response without canonical result semantics`() async throws {
        let coordinator = RecordingMutationCoordinator()
        let context = await MCPToolTestHelpers.makeContext(
            snapshotMutationCoordinator: coordinator,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: StubMCPTool(name: "browser"),
            arguments: Self.sourceProvenBackgroundBrowserMutationArguments())

        #expect(response.isError)
        let resolution = MCPToolResponseMetadataProjector.actionOutcomeResolution(from: response.meta)
        guard case let .valid(projection) = resolution else {
            Issue.record("Expected a canonical indeterminate outcome")
            return
        }
        #expect(projection.state == .indeterminate)
        #expect(projection.retrySafety == .unsafe)
        #expect(projection.escalation == .observeBeforeRetry)
        #expect(coordinator.completions.map(\.succeeded) == [false])
    }

    @Test
    func `Browser semantic validation refuses missing uid before mutation preparation`() async throws {
        let coordinator = RecordingMutationCoordinator()
        let context = await MCPToolTestHelpers.makeContext(
            snapshotMutationCoordinator: coordinator,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: BrowserTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "click",
                "page_id": 7,
            ]))

        #expect(response.isError)
        let resolution = MCPToolResponseMetadataProjector.actionOutcomeResolution(from: response.meta)
        guard case let .valid(projection) = resolution else {
            Issue.record("Expected canonical invalid-request semantics")
            return
        }
        #expect(projection.state == .refused)
        #expect(projection.refusalReason == .invalidRequest)
        #expect(projection.dispatchState == .none)
        #expect(projection.retrySafety == .safe)
        #expect(coordinator.completions.isEmpty)
    }

    @Test
    func `Background mutation does not trust a bare legacy no-dispatch boolean`() async throws {
        let coordinator = RecordingMutationCoordinator()
        let context = await MCPToolTestHelpers.makeContext(
            snapshotMutationCoordinator: coordinator,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .backgroundOnly)
        let legacyResponse = ToolResponse.error(
            "legacy refusal",
            meta: .object([
                "mutation_dispatched": .bool(false),
                "retry_safe": .bool(true),
            ]))

        let response = try await context.execute(
            tool: StubMCPTool(name: "browser", providedResponse: legacyResponse),
            arguments: Self.sourceProvenBackgroundBrowserMutationArguments())

        #expect(response.isError)
        let resolution = MCPToolResponseMetadataProjector.actionOutcomeResolution(from: response.meta)
        guard case let .valid(projection) = resolution else {
            Issue.record("Expected a canonical indeterminate outcome")
            return
        }
        #expect(projection.state == .indeterminate)
        #expect(projection.retrySafety == .unsafe)
        #expect(projection.escalation == .observeBeforeRetry)
        #expect(coordinator.completions.map(\.succeeded) == [false])
    }

    @Test
    func `Unrestricted mutation retains explicit legacy response compatibility`() async throws {
        let coordinator = RecordingMutationCoordinator()
        let context = await MCPToolTestHelpers.makeContext(
            snapshotMutationCoordinator: coordinator,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .unrestricted)

        let response = try await context.execute(
            tool: StubMCPTool(name: "browser"),
            arguments: ToolArguments(raw: ["action": "click"]))

        #expect(!response.isError)
        #expect(MCPToolResponseMetadataProjector.actionOutcomeResolution(from: response.meta).projection == nil)
        #expect(coordinator.completions.map(\.succeeded) == [true])
    }

    @Test
    func `Background mutation cannot report success with a non-success outcome`() async throws {
        let coordinator = RecordingMutationCoordinator()
        let context = await MCPToolTestHelpers.makeContext(
            snapshotMutationCoordinator: coordinator,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .backgroundOnly)
        let outcome = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)
        let contradictoryResponse = try ToolResponse.text(
            "success",
            meta: MCPToolResponseMetadataProjector.metadata(outcome: outcome))

        let response = try await context.execute(
            tool: StubMCPTool(name: "browser", providedResponse: contradictoryResponse),
            arguments: Self.sourceProvenBackgroundBrowserMutationArguments())

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
        #expect(coordinator.completions.map(\.succeeded) == [false])
    }

    @Test
    func `Background mutation converts a reported foreground success into a retry-unsafe error`() async throws {
        let targetReceipt = DesktopActionTargetReceipt(
            processIdentifier: 42,
            processStartIdentity: 420,
            windowID: 71)
        let outcomes: [DesktopActionOutcome] = [
            .confirmedChange(
                route: .bridge,
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                unitCount: .one),
            .dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .operationStillRunning,
                unitCount: .one),
        ]

        for outcome in outcomes {
            let coordinator = RecordingMutationCoordinator()
            let context = await MCPToolTestHelpers.makeContext(
                snapshotMutationCoordinator: coordinator,
                snapshotOwner: self.uiSnapshots.owner,
                executionPolicy: .backgroundOnly)
            var metadata = try #require(
                MCPToolResponseMetadataProjector.metadata(outcome: outcome)?.objectValue)
            let targetReceiptValue = try Value(targetReceipt)
            metadata["target_receipt"] = targetReceiptValue
            let providerResponse = ToolResponse.text(
                "foreground provider success",
                meta: .object(metadata))

            let response = try await context.execute(
                tool: StubMCPTool(name: "browser", providedResponse: providerResponse),
                arguments: Self.sourceProvenBackgroundBrowserMutationArguments())

            #expect(response.isError)
            let resolution = MCPToolResponseMetadataProjector.actionOutcomeResolution(from: response.meta)
            guard case let .valid(projection) = resolution else {
                Issue.record("Expected a canonical retry-unsafe foreground delivery failure")
                continue
            }
            #expect(projection.state == .dispatchedUnverified)
            #expect(projection.route == .bridge)
            #expect(projection.deliveryMechanism == .globalEvents)
            #expect(projection.deliveryMode == .foreground)
            #expect(projection.dispatchedUnitCount == .one)
            #expect(projection.retrySafety == .unsafe)
            #expect(response.meta?.objectValue?["target_receipt"] == targetReceiptValue)
            #expect(coordinator.completions.map(\.succeeded) == [false])
        }
    }

    private static func sourceProvenBackgroundBrowserMutationArguments() -> ToolArguments {
        ToolArguments(raw: [
            "action": "performance_trace",
            "page_id": 1,
            "trace_action": "start",
            "reload": true,
        ])
    }

    @Test
    func `Background observation mutation rejects a receipt-incapable provider before execution`() async throws {
        let context = await MCPToolTestHelpers.makeContext(
            automation: StubNonTargetedAutomationService(),
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .backgroundOnly)

        let response = try #require(context.backgroundMutationCapabilityRejection(
            toolName: "click",
            effect: .mutation))

        #expect(response.isError)
        let resolution = MCPToolResponseMetadataProjector.actionOutcomeResolution(from: response.meta)
        guard case let .valid(projection) = resolution else {
            Issue.record("Expected a canonical pre-dispatch refusal")
            return
        }
        #expect(projection.state == .refused)
        #expect(projection.refusalReason == .runtimeIncompatible)
        #expect(projection.dispatchState == .none)
        #expect(projection.retrySafety == .safe)
    }

    @Test
    func `Cancellation during successful completion rolls back observation publication`() async throws {
        let manager = self.uiSnapshots
        await manager.removeAllSnapshots()
        let coordinator = CancelingMutationCoordinator()
        let context = await MCPToolTestHelpers.makeContext(
            snapshotMutationCoordinator: coordinator,
            snapshotOwner: manager.owner,
            executionPolicy: .unrestricted)
        let snapshotID = "canceled-after-completion"
        let canceledExecution = Task {
            try await context.execute(
                tool: StubMCPTool(
                    name: "see",
                    responseSnapshotID: snapshotID,
                    createdUISnapshotID: snapshotID,
                    uiSnapshots: manager,
                    expectsObservationStart: true),
                arguments: ToolArguments(raw: ["web_focus": true]))
        }

        await #expect(throws: CancellationError.self) {
            try await canceledExecution.value
        }
        #expect(coordinator.completions.map(\.succeeded) == [true, false])
        #expect(await manager.getSnapshot(id: nil) == nil)
        await manager.removeAllSnapshots()
    }

    @Test
    func `Queued tool scope starts after execution gate acquisition`() async throws {
        let gate = MCPToolSnapshotExecutionGate()
        let coordinator = RecordingMutationCoordinator()
        let context = await MCPToolTestHelpers.makeContext(
            snapshotMutationCoordinator: coordinator,
            snapshotExecutionGate: gate,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .unrestricted)
        try await gate.acquire()
        let waiting = Task {
            try await context.execute(
                tool: StubMCPTool(name: "see"),
                arguments: ToolArguments(raw: ["web_focus": true]))
        }
        try await Task.sleep(for: .milliseconds(10))
        let releasedAt = Date()
        await gate.release()
        _ = try await waiting.value

        let completion = try #require(coordinator.completions.first)
        #expect(completion.scope.startedAt >= releasedAt)
    }

    @Test
    func `UI snapshot watermark preserves explicit history without resurfacing stale latest`() async {
        let manager = self.uiSnapshots
        await manager.removeAllSnapshots()
        let oldDate = Date(timeIntervalSince1970: 100)
        let cutoff = Date(timeIntervalSince1970: 200)
        let oldSnapshot = await manager.createSnapshot(at: oldDate)

        _ = await manager.invalidateImplicitLatestSnapshot(through: cutoff)

        #expect(await manager.getSnapshot(id: nil) == nil)
        #expect(await manager.getSnapshot(id: oldSnapshot.id)?.id == oldSnapshot.id)

        let freshSnapshot = await manager.createSnapshot(at: Date(timeIntervalSince1970: 300))
        #expect(await manager.getSnapshot(id: nil)?.id == freshSnapshot.id)
        #expect(await manager.getSnapshot(id: oldSnapshot.id)?.id == oldSnapshot.id)
        await manager.removeAllSnapshots()
    }

    @Test
    func `Atomic preservation restores a refreshed UI snapshot unless a newer mutation wins`() async {
        let manager = self.uiSnapshots
        await manager.removeAllSnapshots()
        let snapshot = await manager.createSnapshot(at: Date(timeIntervalSince1970: 100))
        let observationStart = Date(timeIntervalSince1970: 200)

        _ = await manager.invalidateImplicitLatestSnapshot(
            through: observationStart,
            preserving: snapshot.id)
        #expect(await manager.getSnapshot(id: nil)?.id == snapshot.id)

        let newerMutation = Date()
        _ = await manager.invalidateImplicitLatestSnapshot(through: newerMutation)
        #expect(await manager.getSnapshot(id: nil) == nil)

        _ = await manager.invalidateImplicitLatestSnapshot(
            through: observationStart,
            preserving: snapshot.id)
        #expect(await manager.getSnapshot(id: nil) == nil)
        await manager.removeAllSnapshots()
    }

    @Test
    func `pending UI snapshot stays hidden until observation completion`() async throws {
        let manager = self.uiSnapshots
        await manager.removeAllSnapshots()
        let snapshotID = "pending-observation"
        let context = await MCPToolTestHelpers.makeContext(
            snapshotOwner: manager.owner,
            executionPolicy: .unrestricted)

        _ = try await context.execute(
            tool: StubMCPTool(
                name: "see",
                responseSnapshotID: snapshotID,
                createdUISnapshotID: snapshotID,
                uiSnapshots: manager,
                expectsObservationStart: true),
            arguments: ToolArguments(raw: ["web_focus": true]))

        #expect(await manager.getSnapshot(id: nil)?.id == snapshotID)
        await manager.removeAllSnapshots()
    }

    @Test
    func `MCP context applies external watermark before implicit UI snapshot lookup`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-ui-watermark-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let manager = self.uiSnapshots
        await manager.removeAllSnapshots()
        let stale = await manager.createSnapshot(at: Date().addingTimeInterval(-1))
        let staleID = await stale.id
        _ = try store.advance(through: Date())
        let context = await MCPToolTestHelpers.makeContext(
            snapshots: snapshots,
            snapshotOwner: manager.owner,
            executionPolicy: .unrestricted)

        _ = try await context.execute(
            tool: StubMCPTool(name: "app"),
            arguments: ToolArguments(raw: ["action": "list"]))

        #expect(await manager.getSnapshot(id: nil) == nil)
        #expect(await manager.getSnapshot(id: staleID) != nil)
        await manager.removeAllSnapshots()
    }

    @Test
    func `Fresh observation adopts host completion watermark before publication`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-ui-completion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let manager = self.uiSnapshots
        await manager.removeAllSnapshots()
        let snapshotID = "host-completed-observation"
        let context = await MCPToolTestHelpers.makeContext(
            snapshots: snapshots,
            snapshotOwner: manager.owner,
            executionPolicy: .unrestricted)

        let response = try await context.execute(
            tool: StubMCPTool(
                name: "see",
                responseSnapshotID: snapshotID,
                createdUISnapshotID: snapshotID,
                uiSnapshots: manager,
                expectsObservationStart: true,
                completionWatermarkStore: store),
            arguments: ToolArguments(raw: ["web_focus": true]))

        #expect(!response.isError)
        #expect(await manager.getSnapshot(id: nil)?.id == snapshotID)
        await manager.removeAllSnapshots()
    }

    @Test
    func `Fresh observation closes its own durable barrier before publication checks`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-ui-local-barrier-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let coordinator = DurableMutationCoordinator(store: store)
        let manager = self.uiSnapshots
        await manager.removeAllSnapshots()
        let snapshotID = "local-barrier-observation"
        let context = await MCPToolTestHelpers.makeContext(
            snapshots: snapshots,
            snapshotMutationCoordinator: coordinator,
            snapshotOwner: manager.owner,
            executionPolicy: .unrestricted)

        let response = try await context.execute(
            tool: StubMCPTool(
                name: "see",
                responseSnapshotID: snapshotID,
                createdUISnapshotID: snapshotID,
                uiSnapshots: manager,
                expectsObservationStart: true),
            arguments: ToolArguments(raw: ["web_focus": true]))

        #expect(!response.isError)
        #expect(coordinator.prepareCount == 1)
        #expect(coordinator.barrierCompletionCount == 1)
        #expect(await manager.getSnapshot(id: nil)?.id == snapshotID)
        await manager.removeAllSnapshots()
    }

    @Test
    func `Fresh observation cannot publish across a newer shared watermark`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-ui-newer-mutation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let manager = self.uiSnapshots
        await manager.removeAllSnapshots()
        let snapshotID = "superseded-host-observation"
        let context = await MCPToolTestHelpers.makeContext(
            snapshots: snapshots,
            snapshotOwner: manager.owner,
            executionPolicy: .unrestricted)

        let response = try await context.execute(
            tool: StubMCPTool(
                name: "see",
                responseSnapshotID: snapshotID,
                createdUISnapshotID: snapshotID,
                uiSnapshots: manager,
                expectsObservationStart: true,
                completionWatermarkStore: store,
                newerWatermarkAfterCompletion: true),
            arguments: ToolArguments(raw: ["web_focus": true]))

        #expect(response.isError)
        #expect(await manager.getSnapshot(id: nil) == nil)
        #expect(await manager.getSnapshot(id: snapshotID) != nil)
        await manager.removeAllSnapshots()
    }

    @Test
    func `Successful refresh preserves requested snapshot and failed refresh does not`() async throws {
        let manager = self.uiSnapshots
        await manager.removeAllSnapshots()
        let snapshot = await manager.createSnapshot(at: Date().addingTimeInterval(-60))
        let snapshotID = await snapshot.id
        let context = await MCPToolTestHelpers.makeContext(
            snapshotOwner: manager.owner,
            executionPolicy: .unrestricted)
        let arguments = ToolArguments(raw: ["snapshot": snapshotID, "web_focus": true])

        _ = try await context.execute(
            tool: StubMCPTool(name: "see", responseSnapshotID: snapshotID),
            arguments: arguments)
        #expect(await manager.getSnapshot(id: nil)?.id == snapshotID)

        _ = try await context.execute(
            tool: StubMCPTool(name: "click"),
            arguments: ToolArguments(raw: [:]))
        _ = try await context.execute(
            tool: StubMCPTool(name: "see", responseSnapshotID: "different-snapshot"),
            arguments: arguments)
        #expect(await manager.getSnapshot(id: nil) == nil)

        _ = try await context.execute(
            tool: StubMCPTool(name: "see", responseIsError: true),
            arguments: arguments)

        #expect(await manager.getSnapshot(id: nil) == nil)
        await manager.removeAllSnapshots()
    }

    @Test
    func `Fresh observation scope uses start cutoff only after success`() {
        let started = Date(timeIntervalSince1970: 100)
        let completed = Date(timeIntervalSince1970: 200)
        let scope = MCPToolSnapshotMutationScope(
            toolName: "see",
            startedAt: started,
            effect: .mutationProducingFreshObservation)

        #expect(scope.invalidationCutoff(completedAt: completed, succeeded: true) == started)
        #expect(scope.invalidationCutoff(completedAt: completed, succeeded: false) == completed)
    }

    @Test(arguments: ["auto", "foreground"])
    func `Focus-capable image mutation hides snapshots created during execution`(focus: String) async throws {
        let manager = self.uiSnapshots
        await manager.removeAllSnapshots()
        let context = await MCPToolTestHelpers.makeContext(
            snapshotOwner: manager.owner,
            executionPolicy: .unrestricted)
        let arguments: [String: Any] = ["capture_focus": focus]

        _ = try await context.execute(
            tool: StubMCPTool(name: "image", createsUISnapshot: true, uiSnapshots: manager),
            arguments: ToolArguments(raw: arguments))

        #expect(await manager.getSnapshot(id: nil) == nil)
        await manager.removeAllSnapshots()
    }

    private static func effect(_ name: String, _ raw: [String: Any]) -> MCPToolSnapshotEffect {
        MCPToolSnapshotMutationPolicy.effect(toolName: name, arguments: ToolArguments(raw: raw))
    }

    private static func gateIsAvailable(_ gate: MCPToolSnapshotExecutionGate) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await gate.acquire()
                    await gate.release()
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(250))
                return false
            }

            let available = await group.next() ?? false
            group.cancelAll()
            return available
        }
    }

    private static func snapshotInvalidationStatus(_ response: ToolResponse) -> String? {
        guard case let .object(metadata)? = response.meta,
              case let .object(invalidation)? = metadata["snapshot_invalidation"],
              case let .string(status)? = invalidation["status"]
        else { return nil }
        return status
    }

    private static func snapshotInvalidationFlag(_ response: ToolResponse, key: String) -> Bool? {
        guard case let .object(metadata)? = response.meta,
              case let .object(invalidation)? = metadata["snapshot_invalidation"],
              case let .bool(value)? = invalidation[key]
        else { return nil }
        return value
    }

    private static func responseText(_ response: ToolResponse) -> String {
        response.content.compactMap { content in
            guard case let .text(text: text, annotations: _, _meta: _) = content else { return nil }
            return text
        }.joined(separator: "\n")
    }

    private static func firstResponseText(_ response: ToolResponse) -> String? {
        guard case let .text(text: text, annotations: _, _meta: _)? = response.content.first else { return nil }
        return text
    }
}

@MainActor
private final class RecordingMutationCoordinator: MCPToolSnapshotMutationCoordinating {
    struct Completion {
        let scope: MCPToolSnapshotMutationScope
        let succeeded: Bool
    }

    private(set) var completions: [Completion] = []
    private let completionResult: Bool

    init(completionResult: Bool = true) {
        self.completionResult = completionResult
    }

    @discardableResult
    func completeMutation(_ scope: MCPToolSnapshotMutationScope, succeeded: Bool) async -> Bool {
        self.completions.append(Completion(scope: scope, succeeded: succeeded))
        return self.completionResult
    }
}

@MainActor
private final class DurableMutationCoordinator: MCPToolSnapshotMutationCoordinating {
    private let store: DesktopMutationWatermarkStore
    private var pendingMutation: DesktopMutationWatermarkStore.PendingMutation?
    private(set) var prepareCount = 0
    private(set) var barrierCompletionCount = 0

    init(store: DesktopMutationWatermarkStore) {
        self.store = store
    }

    func prepareMutation(_: MCPToolSnapshotMutationScope) throws {
        self.pendingMutation = try self.store.beginMutation()
        self.prepareCount += 1
    }

    func completeMutationBarrier(
        _: MCPToolSnapshotMutationScope) throws -> MCPToolMutationBarrierCompletion?
    {
        guard let pendingMutation else { return nil }
        let completion = try self.store.completeMutation(pendingMutation)
        self.pendingMutation = nil
        self.barrierCompletionCount += 1
        return MCPToolMutationBarrierCompletion(
            cutoff: completion.cutoff,
            allowsObservationPreservation: completion.allowsObservationPreservation)
    }

    func completeMutation(_: MCPToolSnapshotMutationScope, succeeded _: Bool) async -> Bool {
        true
    }
}

@MainActor
private final class SequencedMutationCoordinator: MCPToolSnapshotMutationCoordinating {
    struct Completion {
        let scope: MCPToolSnapshotMutationScope
        let succeeded: Bool
    }

    private(set) var completions: [Completion] = []
    private var results: [Bool]
    private let cancelOnCall: Int?

    init(results: [Bool], cancelOnCall: Int? = nil) {
        self.results = results
        self.cancelOnCall = cancelOnCall
    }

    func completeMutation(_ scope: MCPToolSnapshotMutationScope, succeeded: Bool) async -> Bool {
        self.completions.append(Completion(scope: scope, succeeded: succeeded))
        if self.completions.count == self.cancelOnCall {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return self.results.isEmpty ? true : self.results.removeFirst()
    }
}

@MainActor
private final class CancelingMutationCoordinator: MCPToolSnapshotMutationCoordinating {
    struct Completion {
        let succeeded: Bool
    }

    private(set) var completions: [Completion] = []

    func completeMutation(_ scope: MCPToolSnapshotMutationScope, succeeded: Bool) async -> Bool {
        self.completions.append(Completion(succeeded: succeeded))
        if succeeded {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return true
    }
}

private actor ToolExecutionLog {
    private(set) var events: [String] = []

    func append(_ event: String) {
        self.events.append(event)
    }
}

private struct StubMCPTool: MCPTool {
    let name: String
    let label: String
    let providedResponse: ToolResponse?
    let responseIsError: Bool
    let responseSnapshotID: String?
    let createsUISnapshot: Bool
    let createdUISnapshotID: String?
    let uiSnapshots: MCPToolUISnapshotStore
    let expectsObservationStart: Bool
    let cancelsCurrentTask: Bool
    let delay: Duration
    let log: ToolExecutionLog?
    let completionWatermarkStore: DesktopMutationWatermarkStore?
    let newerWatermarkAfterCompletion: Bool

    var description: String {
        "Stub tool"
    }

    var inputSchema: Value {
        SchemaBuilder.object(properties: [:], required: [], additionalProperties: true)
    }

    init(
        name: String,
        label: String = "stub",
        providedResponse: ToolResponse? = nil,
        responseIsError: Bool = false,
        responseSnapshotID: String? = nil,
        createsUISnapshot: Bool = false,
        createdUISnapshotID: String? = nil,
        uiSnapshots: MCPToolUISnapshotStore = MCPToolUISnapshotStore(owner: .compatibility),
        expectsObservationStart: Bool = false,
        cancelsCurrentTask: Bool = false,
        delay: Duration = .zero,
        log: ToolExecutionLog? = nil,
        completionWatermarkStore: DesktopMutationWatermarkStore? = nil,
        newerWatermarkAfterCompletion: Bool = false)
    {
        self.name = name
        self.label = label
        self.providedResponse = providedResponse
        self.responseIsError = responseIsError
        self.responseSnapshotID = responseSnapshotID
        self.createsUISnapshot = createsUISnapshot
        self.createdUISnapshotID = createdUISnapshotID
        self.uiSnapshots = uiSnapshots
        self.expectsObservationStart = expectsObservationStart
        self.cancelsCurrentTask = cancelsCurrentTask
        self.delay = delay
        self.log = log
        self.completionWatermarkStore = completionWatermarkStore
        self.newerWatermarkAfterCompletion = newerWatermarkAfterCompletion
    }

    func execute(arguments _: ToolArguments) async throws -> ToolResponse {
        await self.log?.append("\(self.label):start")
        if self.delay > .zero {
            try await Task.sleep(for: self.delay)
        }
        await self.log?.append("\(self.label):end")
        if self.cancelsCurrentTask {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        if let providedResponse {
            return providedResponse
        }
        if self.createsUISnapshot {
            _ = await self.uiSnapshots.createSnapshot()
        }
        if let createdUISnapshotID {
            let observationStartedAt = MCPToolContext.snapshotObservationStartedAt
            if self.expectsObservationStart, observationStartedAt == nil {
                return ToolResponse.error("missing observation start")
            }
            _ = await self.uiSnapshots.createSnapshot(
                id: createdUISnapshotID,
                at: observationStartedAt ?? Date(),
                pending: observationStartedAt != nil)
            #expect(await self.uiSnapshots.getSnapshot(id: nil) == nil)
        }
        var metadataValues: [String: Value] = [:]
        if let responseSnapshotID {
            metadataValues["snapshot_id"] = .string(responseSnapshotID)
        }
        if let completionWatermarkStore {
            let mutation = try completionWatermarkStore.beginMutation()
            let completion = try completionWatermarkStore.completeMutation(mutation)
            metadataValues["desktop_mutation_completed_at"] =
                .double(completion.cutoff.timeIntervalSinceReferenceDate)
            metadataValues["desktop_mutation_preservation_allowed"] =
                .bool(completion.allowsObservationPreservation)
            if self.newerWatermarkAfterCompletion {
                let newerMutation = try completionWatermarkStore.beginMutation()
                _ = try completionWatermarkStore.completeMutation(
                    newerMutation,
                    through: completion.cutoff.addingTimeInterval(1))
            }
        }
        let meta = metadataValues.isEmpty ? nil : Value.object(metadataValues)
        if self.responseIsError {
            return ToolResponse.error("stub error", meta: meta)
        }
        return ToolResponse.text("ok", meta: meta)
    }
}

private struct NestedAgentMCPTool: MCPTool {
    let context: MCPToolContext
    let log: ToolExecutionLog
    let name = "agent"
    let description = "Stub nested agent tool"

    var inputSchema: Value {
        SchemaBuilder.object(properties: [:], required: [])
    }

    func execute(arguments _: ToolArguments) async throws -> ToolResponse {
        await self.log.append("agent:start")
        let nestedMutationCompleted = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    _ = try await self.context.execute(
                        tool: StubMCPTool(name: "click", label: "nested-click", log: self.log),
                        arguments: ToolArguments(raw: [:]))
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(250))
                return false
            }

            let completed = await group.next() ?? false
            group.cancelAll()
            return completed
        }
        await self.log.append("agent:end")

        return nestedMutationCompleted
            ? ToolResponse.text("ok")
            : ToolResponse.error("Nested mutation was blocked by the outer agent execution")
    }
}
