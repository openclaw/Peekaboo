import CoreGraphics
import MCP
import PeekabooFoundation
import PeekabooFoundationTestSupport
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit

extension MCPDesktopActionOutcomeProjectionTests {
    @Test
    @MainActor
    func `background scroll failures preserve reported receipts across the outcome matrix`() async throws {
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
                automation.actionOutcome = expectation.outcome
                automation.uiAutomationOutcomeTargetIdentity = target
                let context = await MCPToolTestHelpers.makeContext(
                    automation: automation,
                    snapshots: InMemorySnapshotManager())
                let snapshotID = try await Self.makeExactScrollSnapshot(context: context)

                let response = try await ScrollTool(context: context).execute(arguments: ToolArguments(raw: [
                    "direction": "down",
                    "amount": 3,
                    "on": "T1",
                    "snapshot": snapshotID,
                ]))

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
        }
    }
}
