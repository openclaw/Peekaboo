import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

#if !PEEKABOO_SKIP_AUTOMATION
@Suite(.serialized, .tags(.safe))
@MainActor
struct GlobalPointerActionResultCommandTests {
    @Test(arguments: [nil, "source", "destination"] as [String?])
    func `background drag leases its snapshot and rejects missing IDs or replay without global input`(
        missingElement: String?
    ) async throws {
        let automation = ExactDragStubAutomationService()
        let context = TestServicesFactory.makeAutomationTestContext(automation: automation)
        let snapshotID = try await context.snapshots.createSnapshot()
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 71, ownerProcessIdentifier: 42, ownerProcessStartIdentity: 9001, capturedBounds: bounds
        )
        try await context.snapshots.storeDetectionResult(snapshotId: snapshotID, result: .init(
            snapshotId: snapshotID,
            screenshotPath: "/tmp/synthetic-drag.png",
            elements: DetectedElements(),
            metadata: .init(detectionTime: 0, elementCount: 0, method: "synthetic", windowContext: .init(
                applicationProcessId: identity.ownerProcessIdentifier,
                applicationProcessStartIdentity: identity.ownerProcessStartIdentity,
                windowID: identity.windowID,
                windowBounds: bounds,
                windowMutationIdentity: identity
            ))
        ))
        let arguments = [
            "drag", "--from", missingElement == "source" ? "missing-source" : "10,20",
            "--to", missingElement == "destination" ? "missing-destination" : "30,40",
            "--snapshot", snapshotID, "--json", "--no-remote",
        ]
        let first = try await InProcessCommandRunner.run(arguments, services: context.services)
        #expect(automation.waitForElementCalls.isEmpty)
        if let missingElement {
            let firstJSON = try Self.jsonObject(first.stdout)
            let error = try #require(firstJSON["error"] as? [String: Any])
            let outcome = try #require(firstJSON["outcome"] as? [String: Any])
            #expect(first.exitStatus != 0)
            #expect(error["code"] as? String == "ELEMENT_NOT_FOUND")
            #expect((error["message"] as? String)?.contains("missing-\(missingElement)") == true)
            #expect(outcome["state"] as? String == DesktopActionOutcome.State.refused.rawValue)
            #expect(outcome["refusal_reason"] as? String == DesktopActionOutcome.RefusalReason.targetUnavailable
                .rawValue)
            #expect(outcome["dispatch_state"] as? String == "none")
            #expect(outcome["mutation_dispatched"] as? Bool == false)
            #expect(outcome["retry_safe"] as? Bool == true)
            #expect(firstJSON["target_receipt"] == nil)
            #expect(automation.exactDragCalls.isEmpty)
            #expect(automation.dragCalls.isEmpty)
            #expect(automation.moveMouseCalls.isEmpty)
            return
        }
        let firstJSON = try Self.jsonObject(first.stdout)
        #expect(first.exitStatus == 0)
        #expect((firstJSON["outcome"] as? [String: Any])?["dispatched_unit_count"] as? Int == 23)
        #expect(firstJSON["target_receipt"] != nil)
        let second = try await InProcessCommandRunner.run(arguments, services: context.services)
        let secondJSON = try Self.jsonObject(second.stdout)
        #expect(second.exitStatus != 0)
        #expect((secondJSON["outcome"] as? [String: Any])?["mutation_dispatched"] as? Bool == false)
        #expect(automation.exactDragCalls.count == 1)
        #expect(automation.dragCalls.isEmpty)
        #expect(automation.moveMouseCalls.isEmpty)
    }

    @Test(arguments: [GlobalPointerCommand.drag, .move])
    func `verified global pointer commands publish one canonical global result`(
        command: GlobalPointerCommand
    ) async throws {
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = Self.pointerOutcome
        let context = TestServicesFactory.makeAutomationTestContext(automation: automation)

        let result = try await InProcessCommandRunner.run(
            command.arguments + ["--foreground", "--json", "--no-remote"],
            services: context.services
        )
        let object = try Self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])

        #expect(result.exitStatus == 0)
        #expect(object["effect"] as? String == DesktopActionOutcome.Effect.unverifiable.rawValue)
        #expect(outcome["state"] as? String == DesktopActionOutcome.State.dispatchedUnverified.rawValue)
        #expect(outcome["delivery_mechanism"] as? String == "global_events")
        #expect(outcome["delivery_mode"] as? String == "foreground")
        #expect(outcome["dispatched_unit_count"] as? Int == 1)
        #expect(outcome["retry_safe"] as? Bool == false)
        #expect(object["target_identity"] == nil)
        #expect(object["target_receipt"] == nil)

        switch command {
        case .drag:
            #expect(automation.dragCalls.count == 1)
        case .move:
            #expect(automation.moveMouseCalls.count == 1)
        }
    }

    @Test(arguments: [GlobalPointerCommand.drag, .move])
    func `legacy global pointer providers retain success with a conservative fallback result`(
        command: GlobalPointerCommand
    ) async throws {
        let automation = StubAutomationService()
        let context = TestServicesFactory.makeAutomationTestContext(automation: automation)

        let result = try await InProcessCommandRunner.run(
            command.arguments + ["--foreground", "--json", "--no-remote"],
            services: context.services
        )
        let object = try Self.jsonObject(result.stdout)

        #expect(result.exitStatus == 0)
        let outcome = try #require(object["outcome"] as? [String: Any])
        #expect(outcome["state"] as? String == DesktopActionOutcome.State.dispatchedUnverified.rawValue)
        #expect(outcome["delivery_mechanism"] as? String == "global_events")
        #expect(outcome["delivery_mode"] as? String == "foreground")
        #expect(outcome["dispatched_unit_count"] as? Int == 1)
        #expect(object["target_identity"] == nil)
        #expect(object["target_receipt"] == nil)
    }

    @Test(arguments: [GlobalPointerCommand.drag, .move])
    func `targeted global pointer commands require exact confirmed focus before pointer dispatch`(
        command: GlobalPointerCommand
    ) async throws {
        let invalidFocuses: [(DesktopActionOutcome, processOnlyTarget: Bool)] = [
            (
                .refused(route: .bridge, reason: .permissionDenied),
                false
            ),
            (
                .dispatchedUnverified(
                    route: .bridge,
                    delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: .one
                ),
                false
            ),
            (
                .confirmedChange(
                    route: .bridge,
                    delivery: .init(mechanism: .accessibilityAction, mode: .background),
                    unitCount: .one
                ),
                false
            ),
            (InputFocusFixtures.focusOutcome, true),
        ]

        for (focusOutcome, processOnlyTarget) in invalidFocuses {
            let automation = OutcomeStubAutomationService()
            automation.actionOutcome = Self.pointerOutcome
            let windows = InputFocusWindowService(focusOutcome: focusOutcome)
            if processOnlyTarget {
                windows.returnedTargetIdentity = try DesktopTargetIdentity(
                    processIdentity: InputFocusFixtures.identity().processIdentity
                )
            }
            let base = TestServicesFactory.makePeekabooServices(
                windows: windows,
                automation: automation
            )
            let services = InputExecutionHostServices(host: .remote, base: base)

            let result = try await InProcessCommandRunner.run(
                command.arguments + [
                    "--window-id", String(InputFocusFixtures.windowID),
                    "--foreground", "--json",
                ],
                services: services
            )

            #expect(result.exitStatus != 0)
            #expect(windows.pinnedFocusCalls.count == 1)
            switch command {
            case .drag:
                #expect(automation.dragCalls.isEmpty)
            case .move:
                #expect(automation.moveMouseCalls.isEmpty)
            }
        }
    }

    @Test(arguments: [GlobalPointerCommand.drag, .move])
    func `targeted global pointer commands dispatch after exact confirmed focus`(
        command: GlobalPointerCommand
    ) async throws {
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = Self.bridgePointerOutcome
        let windows = InputFocusWindowService(focusOutcome: InputFocusFixtures.focusOutcome)
        let base = TestServicesFactory.makePeekabooServices(
            windows: windows,
            automation: automation
        )
        let services = InputExecutionHostServices(host: .remote, base: base)

        let result = try await InProcessCommandRunner.run(
            command.arguments + [
                "--window-id", String(InputFocusFixtures.windowID),
                "--foreground", "--json",
            ],
            services: services
        )
        let object = try Self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])

        #expect(result.exitStatus == 0)
        #expect(windows.pinnedFocusCalls.count == 1)
        #expect(outcome["delivery_mechanism"] as? String == "composite")
        #expect(outcome["delivery_mode"] as? String == "foreground")
        #expect(outcome["dispatched_unit_count"] as? Int == 2)
        #expect(object["target_identity"] == nil)
        #expect(object["target_receipt"] == nil)
        switch command {
        case .drag:
            #expect(automation.dragCalls.count == 1)
        case .move:
            #expect(automation.moveMouseCalls.count == 1)
        }
    }

    @Test
    func `drag cancellation after its result preserves retry unsafe canonical metadata`() async throws {
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = Self.pointerOutcome
        let context = TestServicesFactory.makeAutomationTestContext(automation: automation)

        let command = Task { @MainActor in
            try await InProcessCommandRunner.run(
                GlobalPointerCommand.drag.arguments + ["--foreground", "--json", "--no-remote"],
                services: context.services
            )
        }
        while automation.dragCalls.isEmpty {
            await Task.yield()
        }
        command.cancel()
        let result = try await command.value
        let object = try Self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(outcome["state"] as? String == DesktopActionOutcome.State.dispatchedUnverified.rawValue)
        #expect(outcome["delivery_mechanism"] as? String == "global_events")
        #expect(outcome["delivery_mode"] as? String == "foreground")
        #expect(outcome["dispatched_unit_count"] as? Int == 1)
        #expect(outcome["retry_safe"] as? Bool == false)
        #expect(error["retry_safe"] as? Bool == false)
        #expect(error["mutation_dispatched"] as? Bool == true)
        #expect(object["target_identity"] == nil)
        #expect(object["target_receipt"] == nil)
        #expect(automation.dragCalls.count == 1)
    }

    @Test
    func `exact setup focus cannot replace the global pointer target`() throws {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9001,
            capturedBounds: bounds
        )
        let exactTarget = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds
        ))
        let focus = UIAutomationActionResult(
            payload: (),
            outcome: .confirmedChange(
                delivery: .init(mechanism: .composite, mode: .foreground),
                unitCount: .one
            ),
            targetIdentity: exactTarget
        )
        let pointer = UIAutomationActionResult(payload: (), outcome: Self.pointerOutcome)

        let result = try AutomationServiceBridge.composeGlobalPointerResult(
            setupFocus: focus,
            pointerAction: pointer,
            operation: "Cursor move",
            route: .local
        )

        #expect(result.targetIdentity == nil)
        #expect(result.outcome?.state == .dispatchedUnverified)
        #expect(result.outcome?.delivery == .init(mechanism: .composite, mode: .foreground))
        #expect(result.outcome?.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(2))
    }

    private static let pointerOutcome = DesktopActionOutcome.dispatchedUnverified(
        delivery: .init(mechanism: .globalEvents, mode: .foreground),
        evidence: .deliveryAccepted,
        unitCount: .one
    )

    private static let bridgePointerOutcome = DesktopActionOutcome.dispatchedUnverified(
        route: .bridge,
        delivery: .init(mechanism: .globalEvents, mode: .foreground),
        evidence: .deliveryAccepted,
        unitCount: .one
    )

    private static func jsonObject(_ output: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
}

enum GlobalPointerCommand: String, CaseIterable, Sendable {
    case drag
    case move

    var arguments: [String] {
        switch self {
        case .drag:
            ["drag", "--from", "10,20", "--to", "30,40"]
        case .move:
            ["move", "--at", "30,40"]
        }
    }
}

@MainActor
private final class ExactDragStubAutomationService: StubAutomationService, ExactWindowDragServiceProtocol {
    let supportsExactWindowDrag = true
    private(set) var exactDragCalls: [ExactWindowDragRequest] = []

    func dragExactWindow(
        _ request: ExactWindowDragRequest,
        boundTo _: ApplicationProcessIdentity?
    ) async throws -> UIAutomationActionResult<Void> {
        try request.validate()
        self.exactDragCalls.append(request)
        return UIAutomationActionResult(
            payload: (),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .init(request.dispatchedUnitCount)
            ),
            targetIdentity: DesktopTargetIdentity(exactWindow: request.target)
        )
    }
}
#endif
