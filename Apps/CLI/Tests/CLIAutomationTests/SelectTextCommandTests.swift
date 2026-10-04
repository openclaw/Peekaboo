import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
@Suite(.serialized)
struct SelectTextCommandTests {
    @Test
    func `selection parses literal context and emits typed ranges`() async throws {
        let automation = SelectionAutomation()
        let snapshots = StubSnapshotManager()
        let snapshot = try await ActionOutcomeCommandTests.storeExactWindowElementSnapshot(in: snapshots)
        let services = TestServicesFactory.makePeekabooServices(snapshots: snapshots, automation: automation)
        let result = try await InProcessCommandRunner.run([
            "select-text", "needle", "--on", "elem_3", "--snapshot", snapshot,
            "--prefix", "a ", "--suffix", " b", "--selection-type", "cursor_after", "--json", "--no-remote",
        ], services: services)
        #expect(result.exitStatus == 0)
        #expect(result.stdout.contains("cursor_after"))
        #expect(result.stdout.contains("textSelection"))
        #expect(automation.requests == [.init(text: "needle", prefix: "a ", suffix: " b", selectionType: .cursorAfter)])
        #expect(automation.setValueCalls.isEmpty && automation.performActionCalls.isEmpty)
    }

    @Test
    func `missing snapshots invalid modes and foreground flags cannot dispatch`() async throws {
        for arguments in [
            ["select-text", "needle", "--on", "elem_3"],
            ["select-text", "needle", "--on", "elem_3", "--selection-type", "invalid"],
            ["select-text", "needle", "--on", "elem_3", "--foreground"],
        ] {
            let automation = SelectionAutomation()
            let services = TestServicesFactory.makePeekabooServices(automation: automation)
            let result = try await InProcessCommandRunner.run(arguments + ["--json", "--no-remote"], services: services)
            #expect(result.exitStatus != 0)
            #expect(automation.requests.isEmpty)
        }
    }

    @Test
    func `process-only snapshots require an exact-window capture without dispatch`() async throws {
        try await Self.assertExactWindowRequired(
            windowContext: WindowContext(
                applicationProcessId: 12345,
                applicationProcessStartIdentity: 7
            )
        )
    }

    @Test
    func `screen snapshots require an exact-window capture without dispatch`() async throws {
        try await Self.assertExactWindowRequired(windowContext: nil)
    }

    @Test
    func `malformed receipts retain stale process-generation diagnostics without dispatch`() async throws {
        let bounds = CGRect(x: 100, y: 100, width: 500, height: 400)
        let malformedContexts = [
            WindowContext(applicationProcessId: 12345),
            WindowContext(
                applicationProcessId: 12345,
                applicationProcessStartIdentity: 7,
                windowID: 42,
                windowBounds: bounds,
                windowMutationIdentity: WindowMutationIdentity(
                    windowID: 42,
                    ownerProcessIdentifier: 54321,
                    ownerProcessStartIdentity: 7,
                    capturedBounds: bounds
                )
            ),
        ]
        for context in malformedContexts {
            let snapshots = StubSnapshotManager()
            let snapshot = try await Self.storeElementSnapshot(in: snapshots, windowContext: context)
            let automation = SelectionAutomation()
            let applications = StubApplicationService(applications: [])
            let windows = StubWindowService(windowsByApp: [:])
            let services = TestServicesFactory.makePeekabooServices(
                applications: applications,
                windows: windows,
                snapshots: snapshots,
                automation: automation
            )
            let result = try await InProcessCommandRunner.run([
                "select-text", "needle", "--on", "elem_3", "--snapshot", snapshot, "--json", "--no-remote",
            ], services: services)
            let object = try Self.jsonObject(result.stdout)
            let error = try #require(object["error"] as? [String: Any])
            let outcome = try #require(object["outcome"] as? [String: Any])

            #expect(result.exitStatus == 1)
            #expect(error["code"] as? String == ErrorCode.SNAPSHOT_STALE.rawValue)
            #expect(
                error["message"] as? String ==
                    "Snapshot '\(snapshot)' has no consistent process-generation receipt."
            )
            #expect(error["retry_safe"] as? Bool == true)
            #expect(error["mutation_dispatched"] as? Bool == false)
            #expect(outcome["state"] as? String == "refused")
            #expect(outcome["dispatch_state"] as? String == "none")
            #expect(outcome["refusal_reason"] as? String == "target_unavailable")
            #expect(outcome["mutation_dispatched"] as? Bool == false)
            #expect(outcome["retry_safe"] as? Bool == true)
            #expect(outcome["requires_fresh_observation"] as? Bool == false)
            Self.assertNoDispatch(automation: automation, applications: applications, windows: windows)

            let lease = try await snapshots.beginSnapshotMutation(snapshotId: snapshot)
            try await snapshots.finishSnapshotMutation(lease, requiresFreshObservation: false)
        }
    }

    @Test
    func `accepted unverified selection consumes the snapshot and blocks replay`() async throws {
        let automation = SelectionAutomation()
        automation.failure = .indeterminate(
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Selection accepted but readback unavailable",
            hint: "Observe again"
        )
        let snapshots = StubSnapshotManager()
        let snapshot = try await ActionOutcomeCommandTests.storeExactWindowElementSnapshot(in: snapshots)
        let services = TestServicesFactory.makePeekabooServices(snapshots: snapshots, automation: automation)
        let arguments = ["select-text", "needle", "--on", "elem_3", "--snapshot", snapshot, "--json", "--no-remote"]
        let first = try await InProcessCommandRunner.run(arguments, services: services)
        #expect(first.exitStatus == 1 && first.stdout.contains("indeterminate"))
        let second = try await InProcessCommandRunner.run(arguments, services: services)
        #expect(second.exitStatus == 1)
        #expect(automation.requests.count == 1)
    }

    private static func assertExactWindowRequired(windowContext: WindowContext?) async throws {
        let snapshots = StubSnapshotManager()
        let snapshot = try await Self.storeElementSnapshot(in: snapshots, windowContext: windowContext)
        let plan = try await SnapshotTargetReceiptPlanner(snapshots: snapshots).plan(snapshotID: snapshot)
        if let windowContext {
            let identity = try plan.receipt.requireIdentity()
            #expect(identity.processIdentity.processIdentifier == windowContext.applicationProcessId)
            #expect(identity.processIdentity.processStartIdentity == windowContext.applicationProcessStartIdentity)
            #expect(identity.exactWindow == nil)
        } else {
            #expect(plan.receipt.targetEvidence == .missing)
            #expect(!plan.hasProcessIdentifierEvidence)
        }
        let automation = SelectionAutomation()
        let applications = StubApplicationService(applications: [])
        let windows = StubWindowService(windowsByApp: [:])
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: windows,
            snapshots: snapshots,
            automation: automation
        )
        let arguments = ["select-text", "needle", "--on", "elem_3", "--snapshot", snapshot, "--no-remote"]
        let result = try await InProcessCommandRunner.run(arguments + ["--json"], services: services)
        let object = try Self.jsonObject(result.stdout)
        let error = try #require(object["error"] as? [String: Any])
        let outcome = try #require(object["outcome"] as? [String: Any])
        let message = "Text selection requires a fresh exact-window snapshot."
        let hint = "Run 'peekaboo see --window-id <id>' and retry with its fresh snapshot."

        #expect(result.exitStatus == 1)
        #expect(error["code"] as? String == ErrorCode.INVALID_INPUT.rawValue)
        #expect(error["message"] as? String == message)
        #expect(error["hint"] as? String == hint)
        #expect(error["retry_safe"] as? Bool == true)
        #expect(error["mutation_dispatched"] as? Bool == false)
        #expect(outcome["state"] as? String == "refused")
        #expect(outcome["dispatch_state"] as? String == "none")
        #expect(outcome["refusal_reason"] as? String == "invalid_request")
        #expect(outcome["mutation_dispatched"] as? Bool == false)
        #expect(outcome["retry_safe"] as? Bool == true)
        #expect(outcome["requires_fresh_observation"] as? Bool == false)

        let humanResult = try await InProcessCommandRunner.run(arguments, services: services)
        #expect(humanResult.exitStatus == 1)
        #expect(humanResult.combinedOutput.contains(message))
        #expect(humanResult.combinedOutput.contains(hint))
        #expect(!humanResult.combinedOutput.contains("process-generation"))
        #expect(!humanResult.combinedOutput.contains("already drove a mutation"))
        Self.assertNoDispatch(automation: automation, applications: applications, windows: windows)

        let lease = try await snapshots.beginSnapshotMutation(snapshotId: snapshot)
        try await snapshots.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    private static func storeElementSnapshot(
        in snapshots: StubSnapshotManager,
        windowContext: WindowContext?
    ) async throws -> String {
        let snapshot = try await snapshots.createSnapshot()
        let element = AutomationTestFixtures.detectedElement(
            id: "elem_3",
            type: .textField,
            label: "Fixture",
            bounds: CGRect(x: 120, y: 140, width: 200, height: 30),
            isEnabled: true,
            attributes: ["role": "AXTextField"]
        )
        try await snapshots.storeDetectionResult(
            snapshotId: snapshot,
            result: AutomationTestFixtures.detectionResult(
                snapshotID: snapshot,
                screenshotPath: "/tmp/selection-scope.png",
                elements: DetectedElements(textFields: [element]),
                windowContext: windowContext
            )
        )
        return snapshot
    }

    private static func assertNoDispatch(
        automation: SelectionAutomation,
        applications: StubApplicationService,
        windows: StubWindowService
    ) {
        #expect(automation.requests.isEmpty)
        #expect(automation.setValueCalls.isEmpty && automation.performActionCalls.isEmpty)
        #expect(automation.clickCalls.isEmpty && automation.targetedClickCalls.isEmpty)
        #expect(automation.typeTextCalls.isEmpty && automation.typeActionsCalls.isEmpty)
        #expect(automation.targetedTypeActionsCalls.isEmpty)
        #expect(automation.hotkeyCalls.isEmpty && automation.targetedHotkeyCalls.isEmpty)
        #expect(automation.scrollCalls.isEmpty && automation.swipeCalls.isEmpty)
        #expect(automation.dragCalls.isEmpty && automation.moveMouseCalls.isEmpty)
        #expect(applications.activateCalls.isEmpty && windows.focusCalls.isEmpty)
    }

    private static func jsonObject(_ output: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
}

@MainActor
private final class SelectionAutomation: StubAutomationService {
    override var supportsTextSelection: Bool {
        true
    }

    var requests: [TextSelectionRequest] = []
    var failure: DesktopActionFailure?

    override func selectText(
        target: String,
        request: TextSelectionRequest,
        snapshotId: String?
    ) async throws -> UIAutomationActionResult<ElementActionResult> {
        self.requests.append(request)
        if let failure {
            throw failure
        }
        let identity = try UIAutomationTarget.ExactWindow(
            identity: .init(
                windowID: 42,
                ownerProcessIdentifier: 12345,
                ownerProcessStartIdentity: 7,
                capturedBounds: CGRect(x: 100, y: 100, width: 500, height: 400),
                isMinimized: false
            ),
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400)
        )
        return try UIAutomationActionResult(
            payload: .init(
                target: target,
                actionName: "AXSelectedTextRange",
                anchorPoint: nil,
                textSelection: request.resolve(in: "a needle b")
            ),
            outcome: .confirmedChange(
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                unitCount: .one
            ),
            targetIdentity: DesktopTargetIdentity(exactWindow: identity)
        )
    }
}
