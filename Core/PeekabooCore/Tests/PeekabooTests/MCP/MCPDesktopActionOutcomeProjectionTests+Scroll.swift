import CoreGraphics
import MCP
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit

extension MCPDesktopActionOutcomeProjectionTests {
    @MainActor
    private static func coordinateScrollContext(
        automation: StubAutomationService,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 200, height: 100)) async throws -> MCPToolContext
    {
        let linked = AutomationTestFixtures.linkedSnapshotTarget(
            snapshotID: SnapshotReference.generate().rawValue,
            processIdentity: .init(processIdentifier: 778, processStartIdentity: 78),
            bundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            windowID: 42,
            bounds: bounds)
        let graph = try LinkedApplicationInventoryGraph(nodes: [
            .init(application: linked.desktopTarget.application, windows: [linked.desktopTarget.window]),
        ])
        automation.uiAutomationOutcomeTargetIdentity = try linked.targetIdentity
        return await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: ScriptedApplicationInventoryService(graph: graph),
            windows: ScriptedWindowInventoryService(graph: graph),
            snapshots: InMemorySnapshotManager())
    }

    @MainActor
    static func makeExactScrollSnapshot(
        context: MCPToolContext,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 200, height: 100),
        imageSize: CGSize? = nil,
        viewport: CaptureViewport? = nil) async throws -> String
    {
        let snapshot = try await MCPToolTestHelpers.createSnapshot(in: context)
        let snapshotID = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/scroll-outcome.png",
            metadata: CaptureMetadata(
                size: imageSize ?? bounds.size,
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 778,
                    processStartIdentity: 78,
                    bundleIdentifier: "com.example.editor",
                    name: "Editor"),
                windowInfo: ServiceWindowInfo(
                    windowID: 42,
                    title: "Editor",
                    bounds: bounds,
                    mutationIdentity: WindowMutationIdentity(
                        windowID: 42,
                        ownerProcessIdentifier: 778,
                        ownerProcessStartIdentity: 78,
                        capturedBounds: bounds)),
                viewport: viewport))
        await snapshot.setUIElements([
            UIElement(
                id: "T1",
                elementId: "T1",
                role: "scrollArea",
                title: nil,
                label: "Editor",
                value: nil,
                description: nil,
                help: nil,
                roleDescription: "scroll area",
                identifier: nil,
                frame: CGRect(x: 10, y: 10, width: 100, height: 30),
                isActionable: true),
        ])
        try await MCPToolTestHelpers.publishSnapshotMetadata(snapshot, in: context)
        return snapshotID
    }

    @Test(arguments: [false, true])
    @MainActor
    func `background scroll failures preserve reported receipts across the outcome matrix`(
        coordinates: Bool) async throws
    {
        let bounds = CGRect(x: 20, y: 30, width: 200, height: 100)
        let reportedTarget = try DesktopTargetIdentity(exactWindow: .init(
            identity: WindowMutationIdentity(
                windowID: 99,
                ownerProcessIdentifier: 779,
                ownerProcessStartIdentity: 79,
                capturedBounds: bounds),
            bounds: bounds))
        for expectation in DesktopActionOutcomeFixtures.canonicalCases where expectation.isFailureEligible {
            for target in [reportedTarget, nil] {
                let automation = StubAutomationService()
                automation.supportsBackgroundCoordinateScroll = true
                automation.actionOutcome = expectation.outcome
                automation.uiAutomationOutcomeTargetIdentity = target
                let context = await MCPToolTestHelpers.makeContext(
                    automation: automation,
                    snapshots: InMemorySnapshotManager())
                let snapshotID = try await Self.makeExactScrollSnapshot(context: context)

                var arguments: [String: Value] = [
                    "direction": "down",
                    "amount": 3,
                    "snapshot": .string(snapshotID),
                ]
                arguments[coordinates ? "coords" : "on"] = coordinates ? "45,67" : "T1"
                let response = try await ScrollTool(context: context).execute(arguments: ToolArguments(raw: arguments))

                #expect(response.isError)
                try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expectation.outcome, in: response)
                let meta = try #require(response.meta?.objectValue)
                let expectedReceipt = try target.map { try Value($0.actionTargetReceipt) }
                #expect(meta["target_receipt"] == expectedReceipt)
                #expect(meta["target_identity"] == nil)
                #expect(meta["invalidated_snapshot"] == (
                    expectation.mutationDispatched ? .string(snapshotID) : nil))
                #expect(MCPToolResponseMetadataProjector.externalFields(
                    from: response.meta,
                    toolName: "scroll")["target_receipt"] == expectedReceipt)
                #expect(MCPToolResponseMetadataProjector.agentFields(
                    from: response.meta)["target_receipt"] == expectedReceipt)
                #expect(automation.uiAutomationOutcomeScript.callCount(for: .scroll) == 1)
                guard case let .text(text, _, _) = response.content.first else {
                    Issue.record("Expected scroll failure text")
                    return
                }
                #expect(text.contains("Scroll did not return a confirmed outcome."))
            }
        }
    }

    @Test(arguments: ["global_display_points", "image_pixels", "normalized"])
    @MainActor
    func `coordinate scroll maps global image and normalized ROI points like click`(space: String) async throws {
        let automation = StubAutomationService()
        automation.supportsBackgroundCoordinateScroll = true
        automation.actionOutcome = .confirmedNoChange()
        let bounds = CGRect(x: 100, y: 50, width: 1000, height: 500)
        let context = try await Self.coordinateScrollContext(automation: automation, bounds: bounds)
        let viewport = CaptureViewport(
            sourceLogicalBounds: bounds,
            requestedWindowRelativeBounds: CGRect(x: 200, y: 100, width: 200, height: 100),
            deliveredWindowRelativeBounds: CGRect(x: 200, y: 100, width: 200, height: 100),
            logicalBounds: CGRect(x: 300, y: 150, width: 200, height: 100),
            sourceImageSize: CGSize(width: 2000, height: 1000))
        let snapshotID = try await Self.makeExactScrollSnapshot(
            context: context, bounds: bounds, imageSize: CGSize(width: 400, height: 200), viewport: viewport)
        let coords = space == "image_pixels" ? "100,50" : space == "normalized" ? "0.25,0.25" : "350,175"
        let response = try await context.execute(tool: ScrollTool(context: context), arguments: ToolArguments(raw: [
            "direction": "down", "coords": Value.string(coords), "coordinate_space": Value.string(space),
            "coordinate_reference": Value.string(snapshotID), "snapshot": Value.string(snapshotID),
        ]))
        #expect(!response.isError)
        let request = try #require(automation.scrollRequests.last)
        #expect(request.point == CGPoint(x: 350, y: 175))
        #expect(request.target == nil && !request.foreground)
        #expect(request.expectedWindow?.bounds == bounds)
        #expect(request.expectedWindow?.identity.windowID == 42)
        #expect(automation.uiAutomationOutcomeScript.callCount(for: .scroll) == 1)
        guard case let .text(text, _, _) = response.content.first else {
            Issue.record("Expected confirmed no-change scroll text")
            return
        }
        #expect(text.hasPrefix("✅ Scroll confirmed; no change was needed\nScroll request:"))
    }

    @Test
    @MainActor
    func `coordinate scroll refuses malformed selectors references and out-of-window points`() async throws {
        let automation = StubAutomationService()
        automation.supportsBackgroundCoordinateScroll = true
        let context = await MCPToolTestHelpers.makeContext(automation: automation, snapshots: InMemorySnapshotManager())
        let snapshotID = try await Self.makeExactScrollSnapshot(context: context)
        let cases: [[String: Value]] = [
            ["coords": "20,30", "on": "T1"], ["coords": "20,30", "foreground": true],
            ["coords": "NaN,30"], ["coords": "20,"], ["coords": 42],
            ["coords": "20,30", "coordinate_space": 42],
            ["coords": "20,30", "coordinate_space": "image_pixels"],
            ["coords": "0.5,0.5", "coordinate_space": "normalized"],
            ["coords": "20,30", "coordinate_reference": .string(SnapshotReference.generate().rawValue)],
            ["coords": "20,30", "delay": 1], ["coords": "20,30", "smooth": true],
            ["coords": "201,20"], ["on": "T1", "coordinate_space": "normalized"],
        ]
        for testCase in cases {
            let arguments = ["direction": Value.string("down"), "snapshot": .string(snapshotID)]
                .merging(testCase) { _, incoming in incoming }
            let response = try await ScrollTool(context: context).execute(arguments: ToolArguments(raw: arguments))
            #expect(response.isError)
            #expect(response.meta?.objectValue?["retry_safe"]?.boolValue == true)
            #expect(response.meta?.objectValue?["mutation_dispatched"]?.boolValue == false)
        }
        #expect(automation.scrollRequests.isEmpty)
        #expect(automation.uiAutomationOutcomeScript.callCount(for: .scroll) == 0)
    }

    @Test
    @MainActor
    func `coordinate scroll consumes its snapshot after unverified dispatch and refuses replay`() async throws {
        let automation = StubAutomationService()
        automation.supportsBackgroundCoordinateScroll = true
        automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted)
        let context = try await Self.coordinateScrollContext(automation: automation)
        let snapshotID = try await Self.makeExactScrollSnapshot(context: context)
        let arguments = ToolArguments(raw: [
            "direction": "down", "coords": "20,30", "coordinate_reference": Value.string(snapshotID),
        ])
        let first = try await context.execute(tool: ScrollTool(context: context), arguments: arguments)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(automation.actionOutcome, in: first)
        #expect(first.meta?.objectValue?["invalidated_snapshot"] == .string(snapshotID))
        let replay = try await context.execute(tool: ScrollTool(context: context), arguments: arguments)
        #expect(replay.isError)
        #expect(automation.uiAutomationOutcomeScript.callCount(for: .scroll) == 1)
    }

    @Test
    @MainActor
    func `coordinate scroll rejects capability missing services before dispatch`() async throws {
        let automation = StubAutomationService()
        let context = await MCPToolTestHelpers.makeContext(automation: automation, snapshots: InMemorySnapshotManager())
        let snapshotID = try await Self.makeExactScrollSnapshot(context: context)
        let response = try await ScrollTool(context: context).execute(arguments: ToolArguments(raw: [
            "direction": "down", "coords": "20,30", "snapshot": Value.string(snapshotID),
        ]))
        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .runtimeIncompatible, in: response)
        #expect(automation.scrollRequests.isEmpty)
    }

    @Test
    @MainActor
    func `foreground scroll failures do not attribute global input to a reported target`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted)
        automation.uiAutomationOutcomeTargetIdentity = try DesktopTargetIdentity(
            processIdentity: .init(processIdentifier: 778, processStartIdentity: 78))
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            snapshots: InMemorySnapshotManager())

        let response = try await ScrollTool(context: context).execute(arguments: ToolArguments(raw: [
            "direction": "down",
            "foreground": true,
        ]))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(automation.actionOutcome, in: response)
        #expect(response.meta?.objectValue?["target_receipt"] == nil)
        #expect(response.meta?.objectValue?["target_identity"] == nil)
    }

    @Test
    @MainActor
    func `scroll nil outcomes retain legacy success without fabricated metadata`() async throws {
        for foreground in [false, true] {
            let automation = StubAutomationService()
            automation.uiAutomationOutcomeScript.append(nil, for: .scroll)
            automation.uiAutomationOutcomeTargetIdentity = try DesktopTargetIdentity(
                processIdentity: .init(processIdentifier: 778, processStartIdentity: 78))
            let context = await MCPToolTestHelpers.makeContext(
                automation: automation,
                snapshots: InMemorySnapshotManager())
            let snapshotID = try await Self.makeExactScrollSnapshot(context: context)
            var arguments: [String: Value] = ["direction": "down", "snapshot": .string(snapshotID)]
            if foreground {
                arguments["foreground"] = true
            } else {
                arguments["on"] = "T1"
            }

            let response = try await ScrollTool(context: context).execute(arguments: ToolArguments(raw: arguments))

            #expect(!response.isError)
            let meta = try #require(response.meta?.objectValue)
            #expect(meta["state"] == nil)
            #expect(meta["target_receipt"] == nil)
            #expect(meta["target_identity"] == nil)
            #expect(meta["invalidated_snapshot"] == .string(snapshotID))
            #expect(automation.uiAutomationOutcomeScript.callCount(for: .scroll) == 1)
            guard case let .text(text, _, _) = response.content.first else {
                Issue.record("Expected legacy scroll outcome guidance")
                return
            }
            let expectedStatus = "⚠️ Scroll request completed; receiver effect was not reported; " +
                "observe the target before retrying"
            #expect(text.hasPrefix(expectedStatus + "\nScroll request:"))
            #expect(!text.contains("✅"))
        }
    }
}
