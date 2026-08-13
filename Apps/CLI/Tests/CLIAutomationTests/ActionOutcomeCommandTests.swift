import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
@Suite(.serialized)
struct ActionOutcomeCommandTests {
    @Test
    func `service bridge preserves every canonical fixture without inference`() async throws {
        let automation = OutcomeStubAutomationService()

        for expected in AutomationTestFixtures.canonicalActionOutcomes {
            automation.actionOutcome = expected
            let result = try await AutomationServiceBridge.hotkey(
                automation: automation,
                keys: "cmd+a",
                holdDuration: 50
            )

            #expect(result.outcome == expected)
        }
    }

    @Test
    func `outcome backed command families publish their canonical carrier`() async throws {
        let foregroundEvents = DesktopActionOutcome.Delivery(mechanism: .globalEvents, mode: .foreground)
        let cases: [(arguments: [String], delivery: DesktopActionOutcome.Delivery)] = [
            (["click", "--at", "10,20", "--foreground"], foregroundEvents),
            (["type", "hello", "--foreground"], foregroundEvents),
            (["scroll", "--direction", "down", "--amount", "1", "--foreground"], foregroundEvents),
            (["press", "cmd+a", "--foreground"], foregroundEvents),
            (
                ["action", "AXPress", "--on", "B1"],
                .init(mechanism: .accessibilityAction, mode: .background)
            ),
            (
                ["set-value", "updated", "--on", "B1"],
                .init(mechanism: .accessibilityValue, mode: .background)
            ),
        ]

        for testCase in cases {
            let context = Self.makeContext()
            let snapshotID = try await Self.storeElementSnapshot(in: context.snapshots)
            let outcome = DesktopActionOutcome.confirmedChange(delivery: testCase.delivery)
            context.automation.actionOutcome = outcome
            var arguments = testCase.arguments
            if ["action", "set-value"].contains(arguments[0]) {
                arguments += ["--snapshot", snapshotID]
            }

            let result = try await InProcessCommandRunner.run(
                arguments + ["--json", "--no-remote"],
                services: context.services
            )
            let object = try Self.jsonObject(result.stdout)
            let projection = try #require(object["outcome"] as? [String: Any])

            #expect(result.exitStatus == 0, "Unexpected failure for \(arguments[0]): \(result.combinedOutput)")
            #expect(object["effect"] as? String == "confirmed")
            #expect(projection["state"] as? String == "confirmed_change")
            #expect(projection["effect"] as? String == "confirmed")
            #expect(projection["mutation_dispatched"] as? Bool == true)
            #expect(projection["retry_safe"] as? Bool == false)
            #expect(projection["requires_fresh_observation"] as? Bool == false)
        }
    }

    @Test
    func `confirmed single press human output does not contradict its receipt`() async throws {
        let context = Self.makeContext()
        context.automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground)
        )

        let result = try await InProcessCommandRunner.run(
            ["press", "cmd+a", "--foreground", "--no-remote"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        #expect(result.stdout.contains("✅ Key press confirmed"))
        #expect(!result.stdout.contains("Effect: unverifiable"))
    }

    @Test
    func `successful multi press keeps legacy effect and omits singular outcome`() async throws {
        let context = Self.makeContext()
        context.automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted
        )

        let result = try await InProcessCommandRunner.run(
            ["press", "cmd+a", "cmd+c", "--foreground", "--json", "--no-remote"],
            services: context.services
        )
        let object = try Self.jsonObject(result.stdout)

        #expect(result.exitStatus == 0)
        #expect(object["effect"] as? String == "unverifiable")
        #expect(object["outcome"] == nil)
        #expect(context.automation.hotkeyCalls.count == 2)
    }

    @Test
    func `mid sequence partial failure publishes cumulative canonical projection`() async throws {
        let context = Self.makeContext()
        context.automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted
        )
        let leafFailure = DesktopActionFailure.partial(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "Second chord partially dispatched",
            hint: "Recover the partial chord."
        )
        context.automation.hotkeyOutcomeErrorProvider = { call in call == 2 ? leafFailure : nil }

        let result = try await InProcessCommandRunner.run(
            ["press", "cmd+a", "cmd+c", "--foreground", "--json", "--no-remote"],
            services: context.services
        )
        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(object["effect"] as? String == "partial")
        #expect(projection["state"] as? String == "partial")
        #expect(projection["dispatched_unit_count"] as? Int == 3)
        #expect(projection["mutation_dispatched"] as? Bool == true)
        #expect(projection["retry_safe"] as? Bool == false)
        #expect(error["mutation_dispatched"] as? Bool == true)
        #expect(error["retry_safe"] as? Bool == false)
    }

    @Test
    func `mid sequence partial failure preserves unknown leaf unit count`() async throws {
        let context = Self.makeContext()
        context.automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted
        )
        let leafFailure = DesktopActionFailure.partial(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            message: "Second chord partially dispatched with unknown count"
        )
        context.automation.hotkeyOutcomeErrorProvider = { call in call == 2 ? leafFailure : nil }

        let result = try await InProcessCommandRunner.run(
            ["press", "cmd+a", "cmd+c", "--foreground", "--json", "--no-remote"],
            services: context.services
        )
        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(projection["state"] as? String == "partial")
        #expect(projection["dispatched_unit_count"] == nil)
        #expect(projection["mutation_dispatched"] as? Bool == true)
    }

    @Test
    func `mid sequence indeterminate failure adds completed and leaf units`() async throws {
        let context = Self.makeContext()
        context.automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted
        )
        let leafFailure = InputDeliveryIndeterminateError(
            operation: .hotkey,
            emittedUnitCount: 2,
            causeDescription: "Second chord completion is unknown"
        )
        context.automation.hotkeyOutcomeErrorProvider = { call in call == 2 ? leafFailure : nil }

        let result = try await InProcessCommandRunner.run(
            ["press", "cmd+a", "cmd+c", "--foreground", "--json", "--no-remote"],
            services: context.services
        )
        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(object["effect"] as? String == "unverifiable")
        #expect(projection["state"] as? String == "indeterminate")
        #expect(projection["dispatched_unit_count"] as? Int == 3)
        #expect(projection["requires_fresh_observation"] as? Bool == true)
    }

    @Test
    func `first unbacked indeterminate failure preserves legacy omission`() async throws {
        let context = Self.makeContext()
        let leafFailure = InputDeliveryIndeterminateError(
            operation: .hotkey,
            emittedUnitCount: nil,
            causeDescription: "First chord completion is unknown"
        )
        context.automation.hotkeyOutcomeErrorProvider = { _ in leafFailure }

        let result = try await InProcessCommandRunner.run(
            ["press", "cmd+a", "--foreground", "--json", "--no-remote"],
            services: context.services
        )
        let object = try Self.jsonObject(result.stdout)
        let error = try #require(object["error"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(object["effect"] as? String == "unverifiable")
        #expect(object["outcome"] == nil)
        #expect(error["mutation_dispatched"] == nil)
        #expect(error["retry_safe"] == nil)
    }

    @Test
    func `later indeterminate failure keeps aggregate count unknown when leaf count is unknown`() async throws {
        let context = Self.makeContext()
        context.automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted
        )
        let leafFailure = InputDeliveryIndeterminateError(
            operation: .hotkey,
            emittedUnitCount: nil,
            causeDescription: "Second chord dispatch count is unknown"
        )
        context.automation.hotkeyOutcomeErrorProvider = { call in call == 2 ? leafFailure : nil }

        let result = try await InProcessCommandRunner.run(
            ["press", "cmd+a", "cmd+c", "--foreground", "--json", "--no-remote"],
            services: context.services
        )
        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(projection["state"] as? String == "indeterminate")
        #expect(projection["dispatched_unit_count"] == nil)
        #expect(projection["mutation_dispatched"] as? Bool == true)
    }

    @Test
    func `between call failure projection preserves exact completed count`() {
        let failure = ActionSequenceFailureComposer.indeterminate(
            knownDispatchedUnitCount: 1,
            context: .init(
                route: .bridge,
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                message: "Key sequence outcome is indeterminate after 1 completed press",
                hint: "Observe the target before retrying this key sequence.",
                causeDescription: "Cancelled between chords"
            )
        )
        let projection = failure.outcome.projection

        #expect(projection.state == .indeterminate)
        #expect(projection.route == .bridge)
        #expect(projection.dispatchedUnitCount?.rawValue == 1)
        #expect(projection.mutationDispatched)
        #expect(projection.requiresFreshObservation)
    }

    @Test
    func `sequence composition preserves canonical response loss evidence and route`() {
        let leafFailure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .responseLost,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "Bridge response was lost"
        )
        let failure = ActionSequenceFailureComposer.combining(
            completedUnitCount: 1,
            leafFailure: leafFailure,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            message: "Key sequence stopped after 1 completed press",
            indeterminateHint: "Observe before retrying"
        )
        let projection = failure.outcome.projection

        #expect(projection.state == .indeterminate)
        #expect(projection.route == .bridge)
        #expect(projection.evidence == .responseLost)
        #expect(projection.dispatchedUnitCount?.rawValue == 3)
        #expect(projection.requiresFreshObservation)
    }

    @Test
    func `callers can explicitly discard canonical hotkey results`() async throws {
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted
        )

        _ = try await AutomationServiceBridge.hotkey(
            automation: automation,
            keys: "cmd,v",
            holdDuration: 50
        )
        let identity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 7)
        _ = try await AutomationServiceBridge.hotkey(
            automation: automation,
            keys: "cmd,v",
            holdDuration: 50,
            expectedProcessIdentity: identity
        )

        #expect(automation.hotkeyCalls.count == 1)
        #expect(automation.targetedHotkeyCalls.count == 1)
        #expect(automation.targetedHotkeyCalls.first?.expectedProcessIdentity == identity)
        #expect(automation.outcomeHotkeyCallCount == 2)
    }

    private static func storeElementSnapshot(in snapshots: StubSnapshotManager) async throws -> String {
        let snapshotID = try await snapshots.createSnapshot()
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Fixture",
            value: "before",
            bounds: CGRect(x: 10, y: 10, width: 100, height: 40),
            isEnabled: true,
            isSelected: nil,
            attributes: [:]
        )
        try await snapshots.storeDetectionResult(
            snapshotId: snapshotID,
            result: ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: "/tmp/fixture.png",
                elements: DetectedElements(buttons: [element]),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 1,
                    method: "fixture"
                )
            )
        )
        return snapshotID
    }

    private static func jsonObject(_ output: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    private static func makeContext() -> OutcomeContext {
        let automation = OutcomeStubAutomationService()
        let snapshots = StubSnapshotManager()
        let services = TestServicesFactory.makePeekabooServices(
            snapshots: snapshots,
            automation: automation
        )
        return OutcomeContext(services: services, automation: automation, snapshots: snapshots)
    }

    private struct OutcomeContext {
        let services: PeekabooServices
        let automation: OutcomeStubAutomationService
        let snapshots: StubSnapshotManager
    }
}
