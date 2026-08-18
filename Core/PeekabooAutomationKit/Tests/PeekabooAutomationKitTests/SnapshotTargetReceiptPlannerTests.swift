import PeekabooAutomationKitTestSupport
import Testing
@testable import PeekabooAutomationKit

struct SnapshotTargetReceiptPlannerTests {
    @Test
    func `evidence adapters preserve linked process and exact-window identity`() {
        let focusedElement = AutomationTestFixtures.focusedElement()
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(focusedElement: focusedElement)
        let snapshotEvidence = DesktopTargetEvidenceAdapter.evidence(snapshot: fixture.automationSnapshot)
        let contextEvidence = DesktopTargetEvidenceAdapter.evidence(context: fixture.desktopTarget.windowContext)
        let rawEvidence = DesktopTargetEvidenceAdapter.evidence(
            processIdentifier: fixture.desktopTarget.processIdentity.processIdentifier,
            processStartIdentity: fixture.desktopTarget.processIdentity.processStartIdentity,
            windowID: fixture.desktopTarget.windowIdentity.windowID,
            windowIdentity: fixture.desktopTarget.windowIdentity,
            windowBounds: fixture.desktopTarget.window.bounds,
            focusedElement: focusedElement)
        let applicationEvidence = DesktopTargetEvidenceAdapter.evidence(
            application: fixture.desktopTarget.application)
        let windowEvidence = DesktopTargetEvidenceAdapter.evidence(window: fixture.desktopTarget.window)

        #expect(snapshotEvidence == contextEvidence)
        #expect(snapshotEvidence == rawEvidence)
        #expect(snapshotEvidence.focusedElement == focusedElement)
        for evidence in [snapshotEvidence, contextEvidence, rawEvidence, windowEvidence] {
            #expect(evidence.processIdentifier == fixture.desktopTarget.processIdentity.processIdentifier)
            #expect(evidence.processIdentity == fixture.desktopTarget.processIdentity)
            #expect(evidence.windowID == fixture.desktopTarget.windowIdentity.windowID)
            #expect(evidence.windowIdentity == fixture.desktopTarget.windowIdentity)
            #expect(evidence.windowBounds == fixture.desktopTarget.window.bounds)
        }
        #expect(applicationEvidence.processIdentifier == fixture.desktopTarget.processIdentity.processIdentifier)
        #expect(applicationEvidence.processIdentity == fixture.desktopTarget.processIdentity)
        #expect(applicationEvidence.windowID == nil)
    }

    @Test
    func `planner merges linked sources and preserves coordinate authority`() throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()

        let plan = try SnapshotTargetReceiptPlanner.assemble(
            snapshotID: fixture.snapshotID,
            automationSnapshot: fixture.automationSnapshot,
            detectionResult: fixture.detectionResult)
        let identity = try plan.receipt.requireIdentity()
        let authority = try plan.receipt.requireCoordinateAuthority()

        #expect(plan.sourceEvidence.count == 2)
        #expect(plan.hasProcessIdentifierEvidence)
        #expect(identity.exactWindow?.identity == fixture.desktopTarget.windowIdentity)
        #expect(plan.receipt.applicationBundleIdentifier == fixture.desktopTarget.application.bundleIdentifier)
        #expect(plan.receipt.applicationName == fixture.desktopTarget.application.name)
        #expect(authority.snapshotID == fixture.snapshotID)
        #expect(authority.target.identity == fixture.desktopTarget.windowIdentity)
        #expect(authority.sourceBounds == fixture.desktopTarget.window.bounds)
        #expect(authority.context == fixture.coordinateContext)
    }

    @Test
    func `planner fails closed when snapshot sources identify different process generations`() {
        let snapshotFixture = AutomationTestFixtures.linkedSnapshotTarget()
        let detectionFixture = AutomationTestFixtures.linkedSnapshotTarget(
            processIdentity: AutomationTestFixtures.processIdentity(
                processIdentifier: snapshotFixture.desktopTarget.processIdentity.processIdentifier,
                processStartIdentity: snapshotFixture.desktopTarget.processIdentity.processStartIdentity + 1))

        #expect(throws: DesktopTargetIdentityError.contradictoryProcessGeneration) {
            _ = try SnapshotTargetReceiptPlanner.assemble(
                snapshotID: snapshotFixture.snapshotID,
                automationSnapshot: snapshotFixture.automationSnapshot,
                detectionResult: detectionFixture.detectionResult)
        }
    }

    @Test
    func `planner rejects detection evidence from another snapshot`() {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(snapshotID: "snapshot-1")

        #expect(throws: DesktopTargetIdentityError.snapshotSourceMismatch) {
            _ = try SnapshotTargetReceiptPlanner.assemble(
                snapshotID: "snapshot-2",
                detectionResult: fixture.detectionResult)
        }
    }

    @Test
    func `best-effort loading omits an unavailable source without weakening the receipt`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let planner = SnapshotTargetReceiptPlanner(
            automationSnapshotProvider: { _ in throw SnapshotPlannerTestError.unavailable },
            detectionResultProvider: { _ in fixture.detectionResult },
            sourceFailurePolicy: .omitUnavailableSources)

        let plan = try await planner.plan(snapshotID: fixture.snapshotID)

        #expect(plan.sourceEvidence.count == 1)
        #expect(try plan.receipt.requireIdentity().exactWindow?.identity == fixture.desktopTarget.windowIdentity)
        #expect(try plan.receipt.requireCoordinateAuthority().context == fixture.coordinateContext)
    }

    @Test
    func `process identity planning defers incomplete exact-window evidence to mutation planning`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let incompleteIdentity = WindowMutationIdentity(
            windowID: fixture.desktopTarget.windowIdentity.windowID,
            ownerProcessIdentifier: fixture.desktopTarget.processIdentity.processIdentifier,
            ownerProcessStartIdentity: fixture.desktopTarget.processIdentity.processStartIdentity)
        let detection = AutomationTestFixtures.detectionResult(
            snapshotID: fixture.snapshotID,
            windowContext: WindowContext(
                applicationProcessId: fixture.desktopTarget.processIdentity.processIdentifier,
                windowID: incompleteIdentity.windowID,
                windowBounds: fixture.desktopTarget.window.bounds,
                windowMutationIdentity: incompleteIdentity))
        let planner = SnapshotTargetReceiptPlanner(
            automationSnapshotProvider: { _ in nil },
            detectionResultProvider: { _ in detection })

        await #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try await planner.plan(snapshotID: fixture.snapshotID)
        }
        let processPlan = try await planner.planProcessIdentity(snapshotID: fixture.snapshotID)
        let identity = try processPlan.receipt.requireIdentity()
        #expect(identity.processIdentity == fixture.desktopTarget.processIdentity)
        #expect(identity.exactWindow == nil)
    }

    @Test
    func `best-effort loading still propagates cancellation`() async {
        let snapshotCancellation = SnapshotTargetReceiptPlanner(
            automationSnapshotProvider: { _ in throw CancellationError() },
            detectionResultProvider: { _ in nil },
            sourceFailurePolicy: .omitUnavailableSources)
        let detectionCancellation = SnapshotTargetReceiptPlanner(
            automationSnapshotProvider: { _ in nil },
            detectionResultProvider: { _ in throw CancellationError() },
            sourceFailurePolicy: .omitUnavailableSources)

        await #expect(throws: CancellationError.self) {
            _ = try await snapshotCancellation.plan(snapshotID: "snapshot-1")
        }
        await #expect(throws: CancellationError.self) {
            _ = try await detectionCancellation.plan(snapshotID: "snapshot-1")
        }
    }

    @Test
    func `planner observes cancellation even when a source returns normally`() async {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let sourceStarted = AsyncTestLatch()
        let sourceRelease = AsyncTestLatch()
        let planner = SnapshotTargetReceiptPlanner(
            automationSnapshotProvider: { _ in
                await sourceStarted.open()
                await sourceRelease.wait()
                return fixture.automationSnapshot
            },
            detectionResultProvider: { _ in fixture.detectionResult },
            sourceFailurePolicy: .omitUnavailableSources)
        let task = Task {
            try await planner.plan(snapshotID: fixture.snapshotID)
        }

        #expect(await sourceStarted.opensWithin(.seconds(1)))
        task.cancel()
        await sourceRelease.open()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}

private enum SnapshotPlannerTestError: Error {
    case unavailable
}
