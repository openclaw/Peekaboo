import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

@MainActor
@Suite(.serialized, .tags(.safe))
struct CLIWindowMutationResultTests {
    @Test
    func `verified geometry commands classify idempotent and changed frames canonically`() async throws {
        let original = CGRect(x: 10, y: 20, width: 640, height: 480)
        let cases: [(arguments: [String], changed: CGRect)] = [
            (
                ["window", "move", "--window-id", "77", "--x", "10", "--y", "20"],
                CGRect(x: 30, y: 40, width: 640, height: 480)
            ),
            (
                ["window", "resize", "--window-id", "77", "--width", "640", "--height", "480"],
                CGRect(x: 10, y: 20, width: 800, height: 600)
            ),
            ([
                "window", "set-bounds", "--window-id", "77", "--x", "10", "--y", "20",
                "--width", "640", "--height", "480",
            ], CGRect(x: 30, y: 40, width: 800, height: 600)),
        ]

        for testCase in cases {
            #expect(try await self.geometryOutcomeState(
                arguments: testCase.arguments,
                originalBounds: original,
                verifiedBounds: original
            ) == "confirmed_no_change")

            var changedArguments = testCase.arguments
            switch changedArguments[1] {
            case "move":
                changedArguments[5] = "30"
                changedArguments[7] = "40"
            case "resize":
                changedArguments[5] = "800"
                changedArguments[7] = "600"
            case "set-bounds":
                changedArguments[5] = "30"
                changedArguments[7] = "40"
                changedArguments[9] = "800"
                changedArguments[11] = "600"
            default:
                Issue.record("Unexpected geometry action")
            }
            #expect(try await self.geometryOutcomeState(
                arguments: changedArguments,
                originalBounds: original,
                verifiedBounds: testCase.changed
            ) == "confirmed_change")
        }
    }

    @Test
    func `verified maximize frame change promotes dispatched outcome to confirmed change`() async throws {
        let state = try await self.geometryOutcomeState(
            arguments: ["window", "maximize", "--window-id", "77"],
            originalBounds: CGRect(x: 10, y: 20, width: 640, height: 480),
            verifiedBounds: CGRect(x: 0, y: 0, width: 1200, height: 800)
        )

        #expect(state == "confirmed_change")
    }

    @Test
    func `geometry readback failure preserves dispatched outcome and exact target`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let window = ServiceWindowInfo(
            windowID: 77,
            title: "Fixture",
            bounds: bounds,
            mutationIdentity: .init(
                windowID: 77,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 9001,
                capturedBounds: bounds
            )
        )
        let windows = OutcomeStubWindowService(windowsByApp: ["Fixture": [window]])
        windows.actionOutcome = .dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        windows.postActionReadbackError = CLIWindowMutationTestError.readbackFailed
        let services = TestServicesFactory.makePeekabooServices(windows: windows)

        let result = try await InProcessCommandRunner.run(
            ["window", "move", "--window-id", "77", "--x", "30", "--y", "40", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        let receipt = try #require(object["target_receipt"] as? [String: Any])
        #expect(result.exitStatus == 1)
        #expect(outcome["state"] as? String == "dispatched_unverified")
        #expect(outcome["route"] as? String == "bridge")
        #expect(error["retry_safe"] as? Bool == false)
        #expect(error["mutation_dispatched"] as? Bool == true)
        #expect(receipt["pid"] as? Int == 42)
        #expect(receipt["window_id"] as? Int == 77)
    }

    @Test
    func `same ID replacement after geometry dispatch preserves original unsafe receipt`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let window = ServiceWindowInfo(
            windowID: 77,
            title: "Original",
            bounds: bounds,
            mutationIdentity: .init(
                windowID: 77,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 9001,
                capturedBounds: bounds
            )
        )
        let replacementBounds = CGRect(x: 30, y: 40, width: 640, height: 480)
        let replacement = ServiceWindowInfo(
            windowID: 77,
            title: "Replacement",
            bounds: replacementBounds,
            mutationIdentity: .init(
                windowID: 77,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 9002,
                capturedBounds: replacementBounds
            )
        )
        let windows = OutcomeStubWindowService(windowsByApp: ["Fixture": [window]])
        windows.actionOutcome = .dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        windows.postActionReadbackWindow = replacement
        let services = TestServicesFactory.makePeekabooServices(windows: windows)

        let result = try await InProcessCommandRunner.run(
            ["window", "move", "--window-id", "77", "--x", "30", "--y", "40", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])
        let receipt = try #require(object["target_receipt"] as? [String: Any])
        #expect(result.exitStatus == 1)
        #expect(outcome["state"] as? String == "dispatched_unverified")
        #expect(outcome["requires_fresh_observation"] as? Bool == true)
        #expect(receipt["process_start_identity_decimal"] as? String == "9001")
        #expect(receipt["window_id"] as? Int == 77)
    }

    @Test
    func `bounds provenance drift after maximize preserves original unsafe receipt`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let window = ServiceWindowInfo(
            windowID: 77,
            title: "Original",
            bounds: bounds,
            mutationIdentity: .init(
                windowID: 77,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 9001,
                capturedBounds: bounds
            )
        )
        let reportedBounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let staleReceiptBounds = CGRect(x: 10, y: 20, width: 1200, height: 800)
        let drifted = ServiceWindowInfo(
            windowID: 77,
            title: "Drifted",
            bounds: reportedBounds,
            mutationIdentity: .init(
                windowID: 77,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 9001,
                capturedBounds: staleReceiptBounds
            )
        )
        let windows = OutcomeStubWindowService(windowsByApp: ["Fixture": [window]])
        windows.actionOutcome = .dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        windows.postActionReadbackWindow = drifted
        let services = TestServicesFactory.makePeekabooServices(windows: windows)

        let result = try await InProcessCommandRunner.run(
            ["window", "maximize", "--window-id", "77", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])
        let receipt = try #require(object["target_receipt"] as? [String: Any])
        #expect(result.exitStatus == 1)
        #expect(outcome["state"] as? String == "dispatched_unverified")
        #expect(outcome["requires_fresh_observation"] as? Bool == true)
        #expect(receipt["process_start_identity_decimal"] as? String == "9001")
        #expect(receipt["window_id"] as? Int == 77)
    }

    private static func jsonObject(_ output: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    private func geometryOutcomeState(
        arguments: [String],
        originalBounds: CGRect,
        verifiedBounds: CGRect
    ) async throws -> String {
        let original = Self.window(bounds: originalBounds)
        let windows = OutcomeStubWindowService(windowsByApp: ["Fixture": [original]])
        windows.actionOutcome = .dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        windows.postActionReadbackWindow = Self.window(bounds: verifiedBounds)
        let services = TestServicesFactory.makePeekabooServices(windows: windows)
        let result = try await InProcessCommandRunner.run(
            arguments + ["--json", "--no-remote"],
            services: services
        )

        #expect(result.exitStatus == 0)
        let object = try Self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])
        return try #require(outcome["state"] as? String)
    }

    private static func window(bounds: CGRect) -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: 77,
            title: "Fixture",
            bounds: bounds,
            mutationIdentity: .init(
                windowID: 77,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 9001,
                capturedBounds: bounds
            )
        )
    }
}

private enum CLIWindowMutationTestError: Error {
    case readbackFailed
}
