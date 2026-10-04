import Foundation
import PeekabooAutomationKit
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
