import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
@Suite(.serialized)
struct ClickToolQueryWaitTests {
    @Test(arguments: [
        (PeekabooError.permissionDeniedAccessibility, "permission_denied"),
        (PeekabooError.timeout("Synthetic AX timeout"), "target_unavailable"),
        (PeekabooError.notImplemented("Synthetic unsupported AX host"), "runtime_incompatible"),
    ])
    func `native inspection errors retain their codes and remediation`(scenario: (PeekabooError, String)) async throws {
        let (error, reason) = scenario
        let fixture = try await ClickQueryWaitFixture.make(steps: [.nativeError(error)])
        let response = try await fixture.execute()

        #expect(response.isError)
        #expect(response.meta?.objectValue?["refusal_reason"] == .string(reason))
        #expect(response.meta?.objectValue?["error_code"] == .string(error.code.rawValue))
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        #expect(fixture.automation.requests.count == 1)
        #expect(fixture.automation.targetedClickCalls.isEmpty)
        #expect(fixture.snapshots.createCalls.isEmpty)
    }

    @Test(arguments: [DesktopActionOutcome.RefusalReason.permissionDenied, .runtimeIncompatible])
    func `inspection refusal retains its original classification`(reason: DesktopActionOutcome
        .RefusalReason) async throws
    {
        let fixture = try await ClickQueryWaitFixture.make(steps: [.refused(reason)])
        let response = try await fixture.execute()

        #expect(response.isError)
        #expect(response.meta?.objectValue?["refusal_reason"] == .string(reason.rawValue))
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        #expect(fixture.automation.requests.count == 1)
        #expect(fixture.automation.targetedClickCalls.isEmpty)
        #expect(fixture.snapshots.createCalls.isEmpty)
    }

    @Test
    func `missing snapshot-local id does not wait`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        let snapshot = await context.uiSnapshots.createSnapshot()
        let started = ContinuousClock.now
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "B9",
            "snapshot": snapshot.id,
            "wait_for": 5000,
        ]))

        #expect(started.duration(to: .now) < .seconds(1))
        #expect(response.isError)
        #expect(automation.targetedClickCalls.isEmpty)
    }

    @Test
    func `zero wait reports the current snapshot once`() async throws {
        let fixture = try await ClickQueryWaitFixture.make(steps: [.match])

        let response = try await fixture.execute(waitFor: 0)

        #expect(response.isError)
        #expect(Self.responseText(response).contains("LateControl"))
        #expect(fixture.automation.requests.isEmpty)
        #expect(fixture.automation.targetedClickCalls.isEmpty)
        Self.expectNoCapture(fixture)
    }

    @Test
    func `negative wait is rejected`() async throws {
        let context = await MCPToolTestHelpers.makeContext(
            automation: MockAutomationService(accessibilityGranted: true))
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl",
            "wait_for": -1,
        ]))

        #expect(response.isError)
    }

    @Test
    func `query wait requires an exact window`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        let snapshot = await context.uiSnapshots.createSnapshot()
        let started = ContinuousClock.now
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl",
            "snapshot": snapshot.id,
            "wait_for": 5000,
        ]))

        #expect(started.duration(to: .now) < .seconds(1))
        #expect(Self.responseText(response).contains("exact window"))
        #expect(automation.targetedClickCalls.isEmpty)
    }

    @Test
    func `ocr semantic evidence is refused without waiting`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        let snapshot = await context.uiSnapshots.createSnapshot()
        await snapshot.setUIElements([
            UIElement(
                id: "ocr_late",
                elementId: "ocr_late",
                role: "AXStaticText",
                title: "LateControl",
                label: "LateControl",
                description: "ocr",
                frame: CGRect(x: 0, y: 0, width: 40, height: 20),
                isActionable: false),
        ])
        let started = ContinuousClock.now
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl",
            "snapshot": snapshot.id,
            "wait_for": 5000,
        ]))

        #expect(started.duration(to: .now) < .seconds(1))
        #expect(response.isError)
        #expect(Self.responseText(response).contains("semantic evidence"))
        #expect(automation.targetedClickCalls.isEmpty)
    }

    @Test
    func `public query wait dispatches fresh match with the original observation receipt`() async throws {
        let fixture = try await ClickQueryWaitFixture.make(steps: [.miss, .match])

        let response = try await fixture.execute()

        #expect(!response.isError)
        #expect(fixture.automation.requests.count == 2)
        let observations = fixture.automation.producedObservations
        #expect(observations.count == 2)
        let missed = try #require(observations.first)
        let matched = try #require(observations.last)
        #expect(missed.elementID != matched.elementID)
        #expect(fixture.automation.targetedClickCalls.count == 1)
        let call = try #require(fixture.automation.targetedClickCalls.first)
        let matchedSnapshotID = try #require(fixture.snapshots.storeDetectionResultCalls.first)
        #expect(matchedSnapshotID != fixture.initialSnapshotID)
        #expect(call.snapshotId == matchedSnapshotID)
        if case let .elementId(identifier) = call.target {
            #expect(identifier == matched.elementID)
        } else {
            Issue.record("Query wait must dispatch the freshly observed opaque element ID")
        }
        #expect(call.targetProcessIdentifier == fixture.target.processIdentity.processIdentifier)
        #expect(call.expectedProcessIdentity == fixture.target.processIdentity)
        #expect(call.targetWindowID == fixture.target.window.windowID)
        for request in fixture.automation.requests {
            #expect(request.windowMutationIdentity == fixture.target.windowIdentity)
            #expect(request.applicationProcessId == fixture.target.processIdentity.processIdentifier)
            #expect(request.applicationProcessStartIdentity == fixture.target.processIdentity.processStartIdentity)
            #expect(request.windowID == fixture.target.window.windowID)
            #expect(request.windowBounds == fixture.target.window.bounds)
            #expect(request.requiresFreshAccessibilityTree == true)
            #expect(request.shouldFocusWebContent == false)
            #expect(request.includeMenuBarElements == false)
            #expect(request.allowApplicationScopedAccessibilityFallback == false)
            let remaining = try #require(request.accessibilityTimeoutSeconds)
            #expect(remaining > 0 && remaining <= 5)
        }
        let firstBudget = try #require(fixture.automation.requests.first?.accessibilityTimeoutSeconds)
        let lastBudget = try #require(fixture.automation.requests.last?.accessibilityTimeoutSeconds)
        #expect(lastBudget < firstBudget)
        try await Self.expectMatchedSnapshotDiscarded(fixture)
        #expect(response.meta?.objectValue?["invalidated_snapshot"] == .string(fixture.initialSnapshotID))
        #expect(await fixture.context.uiSnapshots.getSnapshot(id: nil) == nil)
        #expect(await fixture.snapshots.getMostRecentSnapshot() == nil)
        try await Self.expectSourceRetained(fixture)
        Self.expectNoCapture(fixture)
    }

    @Test
    func `nonempty incomplete exact-window match retains inspect UI semantics`() async throws {
        let fixture = try await ClickQueryWaitFixture.make(steps: [.matchFromIncompleteTree])

        let response = try await fixture.execute()

        #expect(!response.isError)
        #expect(fixture.automation.targetedClickCalls.count == 1)
        #expect(fixture.snapshots.storeDetectionResultCalls.count == 1)
        try await Self.expectMatchedSnapshotDiscarded(fixture)
        try await Self.expectSourceRetained(fixture)
        Self.expectNoCapture(fixture)
    }

    @Test
    func `unsupported exact-window host discards the matched internal snapshot before refusal`() async throws {
        let fixture = try await ClickQueryWaitFixture.make(steps: [.match])
        fixture.automation.supportsExactWindowTargetedClicks = false

        let response = try await fixture.execute()

        #expect(response.isError)
        #expect(Self.responseText(response).contains("does not support exact-window background clicks"))
        try await Self.expectMatchedSnapshotDiscarded(fixture)
        try await Self.expectSourceRetained(fixture)
        #expect(fixture.automation.targetedClickCalls.isEmpty)
        #expect(fixture.automation.clickCalls.isEmpty)
        Self.expectNotDispatched(response)
        Self.expectNoCapture(fixture)
    }

    @Test
    func `unsupported modifier host discards the matched internal snapshot before refusal`() async throws {
        let fixture = try await ClickQueryWaitFixture.make(steps: [.match], executionPolicy: .unrestricted)
        fixture.automation.supportsForegroundModifierClick = false

        let response = try await fixture.execute(modifiers: ["cmd"])

        #expect(response.isError)
        #expect(Self.responseText(response).contains("does not support host-leased foreground modifier-click"))
        try await Self.expectMatchedSnapshotDiscarded(fixture)
        try await Self.expectSourceRetained(fixture)
        #expect(fixture.automation.foregroundModifierClickRequests.isEmpty)
        #expect(fixture.automation.targetedClickCalls.isEmpty)
        #expect(fixture.automation.clickCalls.isEmpty)
        Self.expectNotDispatched(response)
        Self.expectNoCapture(fixture)
    }

    @Test(arguments: [false, true])
    func `hard deadline returns before an uncooperative backend and rejects its late result`(
        modifierClick: Bool) async throws
    {
        let gate = ClickQueryWaitObservationGate()
        let fixture = try await ClickQueryWaitFixture.make(
            steps: [.matchAfterGate(gate)],
            executionPolicy: modifierClick ? .unrestricted : .backgroundOnly)
        let finished = AsyncTestLatch()
        let execution = fixture.startExecution(
            waitFor: 100,
            modifiers: modifierClick ? ["cmd"] : [],
            finished: finished)

        #expect(await gate.entered.opensWithin(.seconds(1)))
        #expect(await finished.opensWithin(.seconds(1)))
        #expect(await gate.release.isOpen == false)
        #expect(fixture.automation.producedObservations.isEmpty)
        #expect(fixture.snapshots.createCalls.isEmpty)
        #expect(fixture.snapshots.storeDetectionResultCalls.isEmpty)
        #expect(fixture.automation.targetedClickCalls.isEmpty)
        #expect(fixture.automation.foregroundModifierClickRequests.isEmpty)

        // Release even on assertion failure, so a regressed caller cannot leave this test hung.
        await gate.release.open()
        #expect(await gate.returned.opensWithin(.seconds(1)))
        let completedAfterRelease = await finished.opensWithin(.seconds(1))
        #expect(completedAfterRelease)
        guard completedAfterRelease else {
            execution.cancel()
            return
        }
        let response = try await execution.value

        #expect(response.isError)
        #expect(Self.responseText(response).contains("expired"))
        #expect(fixture.automation.producedObservations.count == 1)
        try await Self.expectSourceRetained(fixture)
        #expect(fixture.snapshots.createCalls.isEmpty)
        #expect(fixture.snapshots.storeDetectionResultCalls.isEmpty)
        #expect(fixture.automation.foregroundModifierClickRequests.isEmpty)
        #expect(fixture.automation.targetedClickCalls.isEmpty)
        #expect(fixture.automation.clickCalls.isEmpty)
        Self.expectNotDispatched(response)
        Self.expectNoCapture(fixture)
    }

    @Test
    func `polling at the UI snapshot cap does not evict the oldest caller snapshot`() async throws {
        let fixture = try await ClickQueryWaitFixture.make(steps: [.miss, .match])
        var retainedSnapshotIDs = [fixture.initialSnapshotID]
        for _ in 0..<24 {
            let snapshot = await fixture.context.uiSnapshots.createSnapshot()
            let snapshotID = await snapshot.id
            retainedSnapshotIDs.append(snapshotID)
        }
        #expect(retainedSnapshotIDs.count == 25)

        let response = try await fixture.execute()

        #expect(!response.isError)
        #expect(fixture.automation.requests.count == 2)
        for snapshotID in retainedSnapshotIDs {
            #expect(await fixture.context.uiSnapshots.getSnapshot(id: snapshotID) != nil)
        }
        try await Self.expectMatchedSnapshotDiscarded(fixture)
        try await Self.expectSourceRetained(fixture)
        Self.expectNoCapture(fixture)
    }

    @Test
    func `caller cancellation returns before an uncooperative backend and rejects its late result`() async throws {
        let gate = ClickQueryWaitObservationGate()
        let fixture = try await ClickQueryWaitFixture.make(steps: [.matchAfterGate(gate)])
        let finished = AsyncTestLatch()
        let execution = fixture.startExecution(finished: finished)

        #expect(await gate.entered.opensWithin(.seconds(1)))
        execution.cancel()
        #expect(await finished.opensWithin(.seconds(1)))
        #expect(await gate.release.isOpen == false)
        #expect(fixture.automation.producedObservations.isEmpty)
        #expect(fixture.snapshots.createCalls.isEmpty)
        #expect(fixture.snapshots.storeDetectionResultCalls.isEmpty)

        await gate.release.open()
        #expect(await gate.returned.opensWithin(.seconds(1)))
        let completedAfterRelease = await finished.opensWithin(.seconds(1))
        #expect(completedAfterRelease)
        guard completedAfterRelease else { return }
        await #expect(throws: CancellationError.self) { _ = try await execution.value }

        #expect(fixture.automation.targetedClickCalls.isEmpty)
        #expect(fixture.automation.producedObservations.count == 1)
        #expect(fixture.snapshots.createCalls.isEmpty)
        #expect(fixture.snapshots.storeDetectionResultCalls.isEmpty)
        try await Self.expectSourceRetained(fixture)
        Self.expectNoCapture(fixture)
    }

    @Test
    func `observation cancellation propagates without creating a snapshot`() async throws {
        let fixture = try await ClickQueryWaitFixture.make(steps: [.throwCancellation])

        await #expect(throws: CancellationError.self) { _ = try await fixture.execute() }

        #expect(fixture.automation.requests.count == 1)
        #expect(fixture.automation.producedObservations.isEmpty)
        #expect(fixture.automation.targetedClickCalls.isEmpty)
        #expect(fixture.snapshots.createCalls.isEmpty)
        #expect(fixture.snapshots.storeDetectionResultCalls.isEmpty)
        try await Self.expectSourceRetained(fixture)
        Self.expectNoCapture(fixture)
    }

    @Test(arguments: ClickQueryWaitAutomationService.InvalidEvidence.allCases)
    func `changed or application-scoped inspection is refused before snapshot publication`(
        evidence: ClickQueryWaitAutomationService.InvalidEvidence) async throws
    {
        let fixture = try await ClickQueryWaitFixture.make(steps: [.invalid(evidence), .match])

        let response = try await fixture.execute()

        #expect(response.isError)
        #expect(fixture.automation.requests.count == 1)
        #expect(fixture.automation.requests.first?.windowMutationIdentity == fixture.target.windowIdentity)
        #expect(fixture.automation.producedObservations.count == 1)
        #expect(fixture.snapshots.createCalls.isEmpty)
        #expect(fixture.snapshots.storeDetectionResultCalls.isEmpty)
        #expect(fixture.automation.targetedClickCalls.isEmpty)
        #expect(try await fixture.snapshots.listSnapshots().map(\.id) == [fixture.initialSnapshotID])
        Self.expectNotDispatched(response)
        Self.expectNoCapture(fixture)
    }

    @Test
    func `waited modifier click retains screenshot lease with the fresh AX point`() async throws {
        let fixture = try await ClickQueryWaitFixture.make(steps: [.miss, .match], executionPolicy: .unrestricted)

        let response = try await fixture.execute(modifiers: ["cmd", "shift"])

        #expect(!response.isError)
        #expect(fixture.automation.requests.count == 2)
        let matched = try #require(fixture.automation.producedObservations.last)
        #expect(fixture.automation.foregroundModifierClickRequests.count == 1)
        let request = try #require(fixture.automation.foregroundModifierClickRequests.first)
        #expect(request.snapshotID == fixture.initialSnapshotID)
        #expect(request.point == matched.center)
        #expect(request.windowIdentity == fixture.target.windowIdentity)
        #expect(request.windowBounds == fixture.target.window.bounds)
        #expect(request.modifiers == [.command, .shift])
        #expect(fixture.automation.targetedClickCalls.isEmpty)
        #expect(fixture.automation.clickCalls.isEmpty)
        #expect(fixture.snapshots.beginCalls.isEmpty)
        #expect(fixture.snapshots.finishCalls.isEmpty)
        try await Self.expectMatchedSnapshotDiscarded(fixture)
        try await Self.expectSourceRetained(fixture)
        Self.expectNoCapture(fixture)
    }

    private static func expectMatchedSnapshotDiscarded(_ fixture: ClickQueryWaitFixture) async throws {
        #expect(fixture.snapshots.createCalls.count == 1)
        #expect(fixture.snapshots.storeDetectionResultCalls.count == 1)
        let snapshotID = try #require(fixture.snapshots.storeDetectionResultCalls.first)
        #expect(snapshotID != fixture.initialSnapshotID)
        #expect(await fixture.context.uiSnapshots.getSnapshot(id: snapshotID) == nil)
        #expect(try await fixture.snapshots.getUIAutomationSnapshot(snapshotId: snapshotID) == nil)
    }

    private static func expectNoCapture(_ fixture: ClickQueryWaitFixture) {
        #expect(fixture.screenCapture.captureAttemptCount == 0)
        #expect(fixture.desktopObservation.callCount == 0)
    }

    private static func expectSourceRetained(_ fixture: ClickQueryWaitFixture) async throws {
        #expect(await fixture.context.uiSnapshots.getSnapshot(id: fixture.initialSnapshotID) != nil)
        #expect(try await fixture.snapshots.getUIAutomationSnapshot(snapshotId: fixture.initialSnapshotID) != nil)
        #expect(try await fixture.snapshots.listSnapshots().map(\.id) == [fixture.initialSnapshotID])
    }

    private static func expectNotDispatched(_ response: ToolResponse) {
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        #expect(response.meta?.objectValue?["retry_safe"] == .bool(true))
    }

    private static func responseText(_ response: ToolResponse) -> String {
        response.content.compactMap { item -> String? in
            guard case let .text(text, _, _) = item else { return nil }
            return text
        }.joined()
    }
}
