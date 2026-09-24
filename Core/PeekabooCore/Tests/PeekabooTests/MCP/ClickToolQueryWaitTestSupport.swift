import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct ClickQueryWaitFixture {
    let context: MCPToolContext
    let automation: ClickQueryWaitAutomationService
    let screenCapture: MockScreenCaptureService
    let desktopObservation: ClickQueryWaitUnexpectedObservationService
    let snapshots: SnapshotMutationRecordingManager
    let initialSnapshotID: String
    let target: LinkedDesktopTargetFixture

    static func make(
        steps: [ClickQueryWaitAutomationService.Step],
        executionPolicy: MCPToolExecutionPolicy = .backgroundOnly) async throws -> Self
    {
        let linked = AutomationTestFixtures.linkedSnapshotTarget(snapshotID: SnapshotReference.generate().rawValue)
        let graph = try LinkedApplicationInventoryGraph(linkedTargets: [linked.desktopTarget])
        let memorySnapshots = try await InMemorySnapshotManager.containing(linked.detectionResult)
        let snapshots = SnapshotMutationRecordingManager(wrapping: memorySnapshots)
        let automation = ClickQueryWaitAutomationService(
            target: linked.desktopTarget,
            steps: steps)
        let screenCapture = MockScreenCaptureService(screenRecordingGranted: false)
        let desktopObservation = ClickQueryWaitUnexpectedObservationService()
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            screenCapture: screenCapture,
            applications: ScriptedApplicationInventoryService(graph: graph),
            windows: ScriptedWindowInventoryService(graph: graph),
            snapshots: snapshots,
            desktopObservation: desktopObservation,
            executionPolicy: executionPolicy)
        let initial = await context.uiSnapshots.createSnapshot(id: linked.snapshotID)
        await initial.setScreenshot(
            path: linked.detectionResult.screenshotPath,
            metadata: CaptureMetadata(
                size: linked.desktopTarget.window.bounds.size,
                mode: .window,
                applicationInfo: linked.desktopTarget.application,
                windowInfo: linked.desktopTarget.window),
            context: linked.desktopTarget.windowContext)
        return Self(
            context: context,
            automation: automation,
            screenCapture: screenCapture,
            desktopObservation: desktopObservation,
            snapshots: snapshots,
            initialSnapshotID: linked.snapshotID,
            target: linked.desktopTarget)
    }

    func execute(waitFor: Int = 5000, modifiers: [String] = []) async throws -> ToolResponse {
        var arguments: [String: Any] = [
            "query": "LateControl",
            "snapshot": self.initialSnapshotID,
            "wait_for": waitFor,
        ]
        if !modifiers.isEmpty {
            arguments["foreground"] = true
            arguments["modifiers"] = modifiers
        }
        return try await self.context.execute(
            tool: ClickTool(context: self.context),
            arguments: ToolArguments(raw: arguments))
    }

    func startExecution(
        waitFor: Int = 5000,
        modifiers: [String] = [],
        finished: AsyncTestLatch) -> Task<ToolResponse, any Error>
    {
        Task { @MainActor in
            do {
                let response = try await self.execute(waitFor: waitFor, modifiers: modifiers)
                await finished.open()
                return response
            } catch {
                await finished.open()
                throw error
            }
        }
    }
}

@MainActor
final class ClickQueryWaitAutomationService: MockAutomationService, ScriptedUIAutomationActionOutcomeProviding {
    enum Step {
        case miss
        case match
        case matchAfterGate(ClickQueryWaitObservationGate)
        case matchFromIncompleteTree
        case throwCancellation
        case refused(DesktopActionOutcome.RefusalReason)
        case nativeError(PeekabooError)
        case invalid(InvalidEvidence)
    }

    enum InvalidEvidence: CaseIterable, Equatable, Sendable {
        case windowID
        case processID
        case generation
        case bounds
        case applicationScope
    }

    struct ProducedObservation {
        let elementID: String
        let center: CGPoint
    }

    let uiAutomationOutcomeScript = UIAutomationOutcomeScript(defaultResponse: .outcome(.confirmedChange(
        delivery: .init(mechanism: .accessibilityAction, mode: .background),
        unitCount: .one)))
    private(set) var requests: [WindowContext] = []
    private(set) var producedObservations: [ProducedObservation] = []
    private let target: LinkedDesktopTargetFixture
    private var steps: [Step]

    init(target: LinkedDesktopTargetFixture, steps: [Step]) {
        self.target = target
        self.steps = steps
        super.init(accessibilityGranted: true)
    }

    override func inspectAccessibilityTree(windowContext: WindowContext?) async throws -> ElementDetectionResult {
        let request = try #require(windowContext)
        self.requests.append(request)
        let step = try #require(self.steps.first, "Unexpected extra query-wait inspection")
        self.steps.removeFirst()
        if case .throwCancellation = step {
            throw CancellationError()
        }
        if case let .refused(reason) = step {
            throw DesktopActionFailure.preDispatchRefusal(reason: reason, message: "Synthetic AX refusal")
        }
        if case let .nativeError(error) = step {
            throw error
        }
        if case let .matchAfterGate(gate) = step {
            await gate.entered.open()
            // This latch deliberately ignores cancellation so the caller must enforce its own deadline.
            await gate.release.wait()
        }

        let elementID = "observed_\(self.requests.count)"
        let label = if case .miss = step {
            "Still waiting"
        } else {
            "LateControl"
        }
        let bounds = CGRect(x: CGFloat(20 + 10 * self.requests.count), y: 30, width: 40, height: 20)
        let evidence: InvalidEvidence? = if case let .invalid(evidence) = step {
            evidence
        } else {
            nil
        }
        let truncationInfo: DetectionTruncationInfo? = if case .matchFromIncompleteTree = step {
            DetectionTruncationInfo(incompleteAccessibilityRead: true)
        } else {
            nil
        }
        let detection = ElementDetectionResult(
            snapshotId: "backend-result-\(self.requests.count)",
            screenshotPath: "",
            elements: DetectedElements(buttons: [DetectedElement(
                id: elementID,
                type: .button,
                label: label,
                bounds: bounds,
                isEnabled: true)]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 1,
                method: "synthetic-query-wait-ax",
                warnings: evidence == .applicationScope
                    ? [DetectionMetadata.applicationScopedAccessibilityFallbackWarning] : [],
                windowContext: self.resultContext(invalidating: evidence),
                truncationInfo: truncationInfo))
        self.producedObservations.append(ProducedObservation(
            elementID: elementID,
            center: CGPoint(x: bounds.midX, y: bounds.midY)))
        if case let .matchAfterGate(gate) = step {
            await gate.returned.open()
        }
        return detection
    }

    private func resultContext(invalidating evidence: InvalidEvidence?) -> WindowContext {
        let windowID = self.target.window.windowID + (evidence == .windowID ? 1 : 0)
        let processID = self.target.processIdentity.processIdentifier + (evidence == .processID ? 1 : 0)
        let generation = self.target.processIdentity.processStartIdentity + (evidence == .generation ? 1 : 0)
        let bounds = evidence == .bounds
            ? self.target.window.bounds.offsetBy(dx: 1, dy: 0) : self.target.window.bounds
        return WindowContext(
            applicationName: self.target.application.name,
            applicationBundleId: self.target.application.bundleIdentifier,
            applicationProcessId: processID,
            applicationProcessStartIdentity: generation,
            windowTitle: self.target.window.title,
            windowID: evidence == .applicationScope ? nil : windowID,
            windowBounds: evidence == .applicationScope ? nil : bounds,
            windowMutationIdentity: evidence == .applicationScope ? nil : WindowMutationIdentity(
                windowID: windowID,
                ownerProcessIdentifier: processID,
                ownerProcessStartIdentity: generation,
                capturedBounds: bounds,
                isMinimized: self.target.windowIdentity.isMinimized),
            traversalBudget: nil)
    }
}

struct ClickQueryWaitObservationGate: Sendable {
    let entered = AsyncTestLatch()
    let release = AsyncTestLatch()
    let returned = AsyncTestLatch()
}

@MainActor
final class ClickQueryWaitUnexpectedObservationService: DesktopObservationServiceProtocol {
    private(set) var callCount = 0

    func observe(_: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.callCount += 1
        Issue.record("AX-only query wait must not request a desktop capture")
        throw PeekabooError.operationError(message: "Unexpected screenshot observation")
    }
}
