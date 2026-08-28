import Commander
import Foundation
import MCP
import PeekabooCore
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCLI

@Suite(.tags(.safe), .serialized)
@MainActor
struct BrowserMutationLaneInvalidatorTests {
    @Test
    func `Concurrent browser lanes share a durable cross process barrier`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-cli-browser-lanes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let externalSnapshots = InMemorySnapshotManager(
            desktopMutationWatermarkStore: DesktopMutationWatermarkStore(directoryURL: root)
        )
        let tracker = InteractionMutationTracker(desktopMutationWatermarkStore: store)
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: snapshots),
            interactionMutationTracker: tracker
        )
        let coordinator = runtime.toolSnapshotMutationCoordinator
        let first = MCPToolSnapshotMutationScope(toolName: "browser", effect: .mutation)
        let second = MCPToolSnapshotMutationScope(toolName: "browser", effect: .mutation)
        _ = try await snapshots.createSnapshot()
        _ = try await externalSnapshots.createSnapshot()

        try coordinator.prepareConcurrentMutation(first)
        try coordinator.prepareConcurrentMutation(second)
        #expect(tracker.hasPendingDurableMutation)
        #expect(store.effectiveWatermark() != nil)
        #expect(await externalSnapshots.getMostRecentSnapshot() == nil)

        let completedFirst = first.completed(at: Date(), preserving: nil)
        let firstCompletion = try coordinator.completeMutationBarrier(completedFirst)
        let firstBarrier = try #require(firstCompletion)
        #expect(!firstBarrier.allowsObservationPreservation)
        #expect(await coordinator.completeMutation(completedFirst, succeeded: true))
        #expect(tracker.hasPendingDurableMutation)
        #expect(store.effectiveWatermark() != nil)
        let completedSecond = second.completed(at: Date(), preserving: nil)
        let secondCompletion = try coordinator.completeMutationBarrier(completedSecond)
        _ = try #require(secondCompletion)
        #expect(await coordinator.completeMutation(completedSecond, succeeded: true))
        #expect(!tracker.hasPendingDurableMutation)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Completed browser mutation stays durable when its peer cancels`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-cli-browser-complete-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let tracker = InteractionMutationTracker(desktopMutationWatermarkStore: store)
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: InMemorySnapshotManager()),
            interactionMutationTracker: tracker
        )
        let coordinator = runtime.toolSnapshotMutationCoordinator
        let completed = MCPToolSnapshotMutationScope(toolName: "browser", effect: .mutation)
        let refused = MCPToolSnapshotMutationScope(toolName: "browser", effect: .mutation)

        try coordinator.prepareConcurrentMutation(completed)
        try coordinator.prepareConcurrentMutation(refused)
        let completionScope = completed.completed(at: Date(), preserving: nil)
        let barrierCompletion = try coordinator.completeMutationBarrier(completionScope)
        let completedBarrier = try #require(barrierCompletion)
        #expect(await coordinator.completeMutation(completionScope, succeeded: true))

        #expect(await coordinator.cancelMutation(refused))
        #expect(!tracker.hasPendingDurableMutation)
        #expect(try #require(store.effectiveWatermark()) >= completedBarrier.cutoff)
    }

    @Test
    func `Overlapping browser refusals cancel their shared uncommitted boundary`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-cli-browser-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let tracker = InteractionMutationTracker(desktopMutationWatermarkStore: store)
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: InMemorySnapshotManager()),
            interactionMutationTracker: tracker
        )
        let coordinator = runtime.toolSnapshotMutationCoordinator
        let first = MCPToolSnapshotMutationScope(toolName: "browser", effect: .mutation)
        let second = MCPToolSnapshotMutationScope(toolName: "browser", effect: .mutation)

        try coordinator.prepareConcurrentMutation(first)
        try coordinator.prepareConcurrentMutation(second)
        #expect(tracker.mutationStartedAt != nil)
        #expect(tracker.hasPendingDurableMutation)

        #expect(await coordinator.cancelMutation(second))
        #expect(tracker.mutationStartedAt != nil)
        #expect(tracker.hasPendingDurableMutation)
        #expect(await coordinator.cancelMutation(first))
        #expect(tracker.mutationStartedAt == nil)
        #expect(!tracker.hasPendingDurableMutation)
        #expect(store.effectiveWatermark() == nil)
    }

    @Test
    func `Session teardown recovers durable debt through its originating coordinator`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-cli-browser-teardown-debt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let watermarkURL = root.appendingPathComponent("desktop-mutation-watermark.json", isDirectory: false)
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let tracker = InteractionMutationTracker(desktopMutationWatermarkStore: store)
        let services = PeekabooServices(snapshotManager: snapshots)
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: services,
            interactionMutationTracker: tracker
        )
        let sharedGate = MCPToolSnapshotExecutionGate()
        let context = MCPToolContext(
            services: services,
            snapshotMutationCoordinator: runtime.toolSnapshotMutationCoordinator,
            snapshotExecutionGate: sharedGate,
            browserMutationExecutionGate: MCPToolSnapshotExecutionGate(),
            snapshotOwner: MCPToolSnapshotOwner(),
            executionPolicy: .unrestricted
        )
        let response = try await context.execute(
            tool: DurableBrowserMutationTool {
                try FileManager.default.createDirectory(
                    at: watermarkURL,
                    withIntermediateDirectories: true
                )
            },
            arguments: ToolArguments(raw: [
                "action": "new_page",
                "url": "https://example.test/",
                "background": true,
            ])
        )

        #expect(!response.isError)
        #expect(tracker.hasPendingDurableMutation)
        #expect(await sharedGate.pendingInvalidation()?.scope.toolName == "browser")
        try FileManager.default.removeItem(at: watermarkURL)

        await context.releaseSnapshotOwner()

        #expect(!tracker.hasPendingDurableMutation)
        #expect(await sharedGate.pendingInvalidation()?.scope == nil)
        let followupContext = MCPToolContext(
            services: services,
            snapshotMutationCoordinator: runtime.toolSnapshotMutationCoordinator,
            snapshotExecutionGate: sharedGate,
            snapshotOwner: MCPToolSnapshotOwner(),
            executionPolicy: .unrestricted
        )
        let followup = try await followupContext.execute(
            tool: DurableFollowupMutationTool(),
            arguments: ToolArguments(raw: [:])
        )
        #expect(!followup.isError)
        #expect(!tracker.hasPendingDurableMutation)
    }

    @Test
    func `Browser command applies exact per-call native snapshot mutation semantics`() async throws {
        let snapshots = InMemorySnapshotManager()
        let originalSnapshot = try await snapshots.createSnapshot()
        let browser = SnapshotPreservingBrowserClient()
        let services = Self.services(browser: browser, snapshots: snapshots)
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: services
        )
        var read = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(
                positional: ["console"],
                options: ["pageId": ["1"]],
                flags: []
            )
        )

        try await read.run(using: runtime)

        #expect(browser.executionCount == 1)
        #expect(await snapshots.getMostRecentSnapshot() == originalSnapshot)
        #expect(!runtime.interactionMutationTracker.hasPendingDurableMutation)

        var refused = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(
                positional: ["snapshot"],
                options: ["pageId": ["1"]],
                flags: []
            )
        )
        do {
            try await refused.run(using: runtime)
            Issue.record("Expected background snapshot to require foreground browser authority")
        } catch {}

        #expect(browser.executionCount == 1)
        #expect(await snapshots.getMostRecentSnapshot() == originalSnapshot)
        #expect(!runtime.interactionMutationTracker.hasPendingDurableMutation)

        var foregroundRead = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(
                positional: ["list-pages"],
                options: [:],
                flags: ["foreground"]
            )
        )
        try await foregroundRead.run(using: runtime)

        #expect(browser.executionCount == 2)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
        #expect(!runtime.interactionMutationTracker.hasPendingDurableMutation)

        _ = try await snapshots.createSnapshot()
        var backgroundMutation = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(
                positional: ["performance-trace"],
                options: [
                    "pageId": ["1"],
                    "traceAction": ["start"],
                ],
                flags: []
            )
        )
        try await backgroundMutation.run(using: runtime)

        #expect(browser.executionCount == 3)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
        #expect(!runtime.interactionMutationTracker.hasPendingDurableMutation)
    }

    private static func services(
        browser: any BrowserMCPClientProviding,
        snapshots: any SnapshotManagerProtocol
    ) -> PeekabooServices {
        let defaults = PeekabooServices()
        return PeekabooServices(
            logging: defaults.logging,
            screenCapture: defaults.screenCapture,
            applications: defaults.applications,
            automation: defaults.automation,
            windows: defaults.windows,
            menu: defaults.menu,
            dock: defaults.dock,
            dialogs: defaults.dialogs,
            snapshots: snapshots,
            files: defaults.files,
            clipboard: defaults.clipboard,
            permissions: defaults.permissions,
            audioInput: defaults.audioInput,
            browser: browser,
            configuration: defaults.configuration,
            screens: defaults.screens
        )
    }
}

private struct DurableBrowserMutationTool: MCPTool {
    let name = "browser"
    let description = "Durable browser mutation failure fixture"
    let inputSchema = SchemaBuilder.object(properties: [
        "action": SchemaBuilder.string(),
        "url": SchemaBuilder.string(),
        "background": SchemaBuilder.boolean(),
    ])
    let onExecute: @MainActor @Sendable () throws -> Void

    @MainActor
    func execute(arguments _: ToolArguments) async throws -> ToolResponse {
        try self.onExecute()
        return .text("ok")
    }
}

private struct DurableFollowupMutationTool: MCPTool {
    let name = "click"
    let description = "Durable follow-up mutation fixture"
    let inputSchema = SchemaBuilder.object(properties: [:])

    @MainActor
    func execute(arguments _: ToolArguments) async throws -> ToolResponse {
        .text("ok")
    }
}

@MainActor
private final class SnapshotPreservingBrowserClient: BrowserMCPActionResultProviding, @unchecked Sendable {
    private(set) var executionCount = 0

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        BrowserMCPStatus(isConnected: true, toolCount: 1, detectedBrowsers: [])
    }

    func connect(channel: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        await self.status(channel: channel)
    }

    func disconnect() async {}

    func execute(
        toolName _: String,
        arguments _: [String: Any],
        channel _: BrowserMCPChannel?
    ) async throws -> ToolResponse {
        self.executionCount += 1
        return .text("read")
    }

    func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?
    ) async throws -> DesktopActionResult<ToolResponse> {
        try await self.executeSequenceWithOutcome(
            calls,
            channel: channel,
            connectionPolicy: .requireExistingLiveReceipt
        )
    }

    func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel _: BrowserMCPChannel?,
        connectionPolicy _: BrowserMCPExecutionConnectionPolicy
    ) async throws -> DesktopActionResult<ToolResponse> {
        self.executionCount += 1
        let isMutation = calls.contains { call in
            BrowserToolActionSemantics.classify(toolName: call.toolName) { name in
                call.arguments[name] as? Bool
            } == .mutating
        }
        let outcome = isMutation
            ? DesktopActionOutcome.dispatchedUnverified(
                route: .local,
                delivery: .init(mechanism: .browserProtocol, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one
            )
            : nil
        return DesktopActionResult(payload: .text("read"), outcome: outcome)
    }
}
