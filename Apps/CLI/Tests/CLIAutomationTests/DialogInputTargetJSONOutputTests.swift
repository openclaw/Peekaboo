import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.unit))
struct DialogInputTargetJSONOutputTests {
    @Test
    func `targeted dialog list emits exact target identity and receipt`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 300)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9001,
            capturedBounds: bounds
        )
        let exactTarget = try UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
        let elements = try DialogElements(
            dialogInfo: .init(title: "Alert", role: "AXSheet", bounds: bounds),
            buttons: [.init(title: "OK")],
            resolvedTarget: ResolvedDialogTargetEvidence(
                target: exactTarget,
                application: .init(
                    processIdentifier: 42,
                    processStartIdentity: 9001,
                    bundleIdentifier: "com.example.DialogFixture",
                    name: "Dialog Fixture"
                ),
                window: .init(
                    windowID: 73,
                    title: "Alert",
                    bounds: bounds,
                    mutationIdentity: identity
                )
            )
        )
        let services = TestServicesFactory.makePeekabooServices(dialogs: StubDialogService(elements: elements))

        let result = try await InProcessCommandRunner.run(
            ["dialog", "list", "--pid", "42", "--window-id", "73", "--json"],
            services: services
        )
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let target = try #require(
            object["target_identity"] as? [String: Any],
            "Expected target identity in: \(result.stdout)"
        )
        let receipt = try #require(object["target_receipt"] as? [String: Any])

        #expect(result.exitStatus == 0)
        #expect(target["kind"] as? String == "window")
        #expect(target["window_id"] as? Int == 73)
        #expect(receipt["window_id"] as? Int == 73)
    }

    @Test
    func `targeted dialog list rejects resolved target mismatch`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 300)
        let identity = WindowMutationIdentity(
            windowID: 74,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9001,
            capturedBounds: bounds
        )
        let exactTarget = try UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
        let elements = try DialogElements(
            dialogInfo: .init(title: "Alert", role: "AXSheet", bounds: bounds),
            resolvedTarget: ResolvedDialogTargetEvidence(
                target: exactTarget,
                application: .init(
                    processIdentifier: 42,
                    processStartIdentity: 9001,
                    bundleIdentifier: "com.example.DialogFixture",
                    name: "Dialog Fixture"
                ),
                window: .init(
                    windowID: 74,
                    title: "Alert",
                    bounds: bounds,
                    mutationIdentity: identity
                )
            )
        )
        let services = TestServicesFactory.makePeekabooServices(dialogs: StubDialogService(elements: elements))

        let result = try await InProcessCommandRunner.run(
            ["dialog", "list", "--pid", "42", "--window-id", "73", "--json"],
            services: services
        )

        #expect(result.exitStatus == 1)
    }

    @Test
    func `dialog input rejects receipt backed target that mismatches exact selector`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 300)
        let identity = WindowMutationIdentity(
            windowID: 74,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9001,
            capturedBounds: bounds
        )
        let dialogService = StubDialogService(elements: DialogElements(
            dialogInfo: DialogInfo(
                title: "Alert",
                role: "AXSheet",
                bounds: bounds
            ),
            textFields: [DialogTextField(index: 0)]
        ))
        dialogService.enterTextResult = DialogActionResult(
            success: true,
            action: .enterText,
            details: ["field": "Name", "text_length": "5"],
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one
            ),
            targetReceipt: DesktopActionTargetReceipt(
                processIdentifier: identity.ownerProcessIdentifier,
                processStartIdentity: identity.ownerProcessStartIdentity,
                windowID: identity.windowID
            ),
            targetWindowIdentity: identity,
            targetWindowBounds: bounds,
            focusedElement: nil
        )
        let setupIdentity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9001,
            capturedBounds: bounds
        )
        let windows = OutcomeStubWindowService(windowsByApp: [
            "Dialog Fixture": [ServiceWindowInfo(
                windowID: 73,
                title: "Alert",
                bounds: bounds,
                mutationIdentity: setupIdentity
            )],
        ])
        windows.actionOutcome = .confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            unitCount: .one
        )
        let services = InputExecutionHostServices(
            host: .remote,
            base: TestServicesFactory.makePeekabooServices(windows: windows, dialogs: dialogService)
        )

        let result = try await InProcessCommandRunner.run(
            [
                "dialog", "input", "--text", "hello", "--field", "Name", "--foreground",
                "--pid", "42", "--window-id", "73", "--json",
            ],
            services: services
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let outcome = try #require(object["outcome"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(dialogService.foregroundExactInputRequests.count == 1)
        #expect(object["target_identity"] == nil)
        #expect(object["target_receipt"] == nil)
        #expect(outcome["state"] as? String == "indeterminate")
        #expect(outcome["retry_safe"] as? Bool == false)
    }
}
