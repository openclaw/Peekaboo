import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooCore
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooCLI

@MainActor
@Suite(.serialized)
struct ActionOutcomeCommandTests {
    enum LeaseFinalizationFailure: CaseIterable, Sendable {
        case bridgeTimeout
        case unreadableReceipt
        case consumeWriteFailure

        var error: any Error {
            switch self {
            case .bridgeTimeout:
                PeekabooError.timeout("Bridge mutation finalization timed out")
            case .unreadableReceipt:
                SnapshotError.corruptedData
            case .consumeWriteFailure:
                SnapshotError.storageError("Could not consume the mutation receipt")
            }
        }
    }

    @Test
    func `service bridges preserve canonical fixtures across their validation boundaries`() async throws {
        let automation = OutcomeStubAutomationService()
        let application = AutomationTestFixtures.application(
            processIdentifier: 42,
            processStartIdentity: 7,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture"
        )
        let applications = OutcomeStubApplicationService(applications: [application])
        let windowIdentity = WindowMutationIdentity(
            windowID: 101,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 7,
            capturedBounds: CGRect(x: 10, y: 20, width: 640, height: 480)
        )
        let window = ServiceWindowInfo(
            windowID: 101,
            title: "Fixture",
            bounds: CGRect(x: 10, y: 20, width: 640, height: 480),
            mutationIdentity: windowIdentity
        )
        let windows = OutcomeStubWindowService(windowsByApp: ["Fixture": [window]])

        for expected in DesktopActionOutcomeFixtures.canonicalOutcomes {
            automation.actionOutcome = expected
            applications.actionOutcome = expected
            windows.actionOutcome = expected
            let automationResult = try await AutomationServiceBridge.hotkey(
                automation: automation,
                keys: "cmd+a",
                holdDuration: 50
            )
            #expect(automationResult.outcome == expected)
            do {
                let result = try await ApplicationServiceBridge.launchApplication(
                    applications: applications,
                    request: ApplicationLaunchRequest(applicationIdentifier: "Fixture")
                )
                #expect(expected.isAccepted(by: .confirmedOrDispatched))
                #expect(result.outcome == expected)
            } catch let failure as DesktopActionFailure {
                #expect(!expected.isAccepted(by: .confirmedOrDispatched))
                #expect(failure.outcome == expected)
            }
            do {
                let result = try await WindowServiceBridge.setWindowBounds(
                    windows: windows,
                    target: .windowId(101),
                    expectedIdentity: windowIdentity,
                    bounds: CGRect(x: 30, y: 40, width: 640, height: 480)
                )
                #expect(expected.isAccepted(by: .confirmedOrDispatched))
                #expect(result.outcome == expected)
            } catch let failure as DesktopActionFailure {
                #expect(!expected.isAccepted(by: .confirmedOrDispatched))
                #expect(failure.outcome == expected)
            }
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
                ["action", "AXIncrement", "--on", "B1"],
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
            let envelope = try ActionEnvelopeTestProbe.decode(result.stdout)
            let object = try Self.jsonObject(result.stdout)
            let projection = try #require(object["outcome"] as? [String: Any])

            #expect(result.exitStatus == 0, "Unexpected failure for \(arguments[0]): \(result.combinedOutput)")
            ActionEnvelopeTestAssertions.expectCanonicalOutcome(outcome, in: envelope)
            #expect(object["effect"] as? String == "confirmed")
            #expect(projection["state"] as? String == "confirmed_change")
            #expect(projection["effect"] as? String == "confirmed")
            #expect(projection["mutation_dispatched"] as? Bool == true)
            #expect(projection["retry_safe"] as? Bool == false)
            #expect(projection["requires_fresh_observation"] as? Bool == false)
        }
    }

    @Test
    func `window and application commands publish the service carrier`() async throws {
        let outcome = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one
        )
        let application = AutomationTestFixtures.application(
            processIdentifier: 42,
            processStartIdentity: 7,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture"
        )
        let applications = OutcomeStubApplicationService(applications: [application])
        applications.actionOutcome = outcome
        let window = ServiceWindowInfo(
            windowID: 101,
            title: "Fixture",
            bounds: CGRect(x: 10, y: 20, width: 640, height: 480),
            mutationIdentity: WindowMutationIdentity(
                windowID: 101,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 7,
                capturedBounds: CGRect(x: 10, y: 20, width: 640, height: 480)
            )
        )
        let windows = OutcomeStubWindowService(windowsByApp: ["Fixture": [window]])
        windows.actionOutcome = outcome
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: windows
        )

        let results = try await [
            InProcessCommandRunner.run(
                ["app", "launch", "Fixture", "--json", "--no-remote"],
                services: services
            ),
            InProcessCommandRunner.run(
                [
                    "window", "set-bounds", "--pid", "42", "--window-id", "101",
                    "--x", "30", "--y", "40", "--width", "640", "--height", "480",
                    "--json", "--no-remote",
                ],
                services: services
            ),
        ]

        for result in results {
            #expect(result.exitStatus == 0, "Unexpected command failure: \(result.combinedOutput)")
            let object = try Self.jsonObject(result.stdout)
            #expect(object["effect"] as? String == outcome.effect.rawValue)
            let projection = try #require(object["outcome"] as? [String: Any])
            #expect(projection["state"] as? String == outcome.state.rawValue)
            #expect(projection["mutation_dispatched"] as? Bool == true)
        }
    }

    @Test
    func `confirmed no-change launch does not claim a launch was dispatched`() async throws {
        let application = AutomationTestFixtures.application(
            processIdentifier: 42,
            processStartIdentity: 7,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture"
        )
        let applications = OutcomeStubApplicationService(applications: [application])
        applications.actionOutcome = .confirmedNoChange()
        let services = TestServicesFactory.makePeekabooServices(applications: applications)

        let result = try await InProcessCommandRunner.run(
            ["app", "launch", "Fixture", "--no-remote"],
            services: services
        )

        #expect(result.exitStatus == 0)
        #expect(result.stdout.contains("Already running: Fixture"))
        #expect(result.stdout.contains("no launch dispatched"))
        #expect(!result.stdout.contains("✓ Launched"))
    }

    @Test
    func `legacy background launch keeps truthful no-op wording without inventing an outcome`() async throws {
        let application = AutomationTestFixtures.application(
            processIdentifier: 42,
            processStartIdentity: 7,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture"
        )
        let applications = OutcomeStubApplicationService(applications: [application])
        applications.actionOutcome = nil
        let services = TestServicesFactory.makePeekabooServices(applications: applications)

        let humanResult = try await InProcessCommandRunner.run(
            ["app", "launch", "Fixture", "--no-remote"],
            services: services
        )
        let jsonResult = try await InProcessCommandRunner.run(
            ["app", "launch", "Fixture", "--no-remote", "--json"],
            services: services
        )
        let object = try Self.jsonObject(jsonResult.stdout)

        #expect(humanResult.exitStatus == 0)
        #expect(humanResult.stdout.contains("Already running: Fixture"))
        #expect(humanResult.stdout.contains("no launch dispatched"))
        #expect(!humanResult.stdout.contains("✓ Launched"))
        #expect(jsonResult.exitStatus == 0)
        #expect(object["effect"] as? String == "confirmed")
        #expect(object["outcome"] == nil)
    }

    @Test
    func `single app quit preserves a suspected no-op receipt`() async throws {
        let application = AutomationTestFixtures.application(
            processIdentifier: 42,
            processStartIdentity: 7,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture"
        )
        let applications = OutcomeStubApplicationService(applications: [application])
        applications.quitShouldSucceed = false
        let outcome = DesktopActionOutcome.suspectedNoop(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one
        )
        applications.actionOutcome = outcome
        let services = TestServicesFactory.makePeekabooServices(applications: applications)

        let result = try await InProcessCommandRunner.run(
            [
                "app", "quit", "--pid", "42", "--expected-process-start-identity", "7",
                "--json", "--no-remote",
            ],
            services: services
        )
        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(object["effect"] as? String == "suspected_noop")
        #expect(projection["state"] as? String == "suspected_noop")
        #expect(projection["retry_safe"] as? Bool == true)
        #expect(error["retry_safe"] as? Bool == true)
        #expect(error["mutation_dispatched"] as? Bool == true)
        #expect(error["hint"] as? String == "Try --force to force quit.")
    }

    @Test
    func `bridge target refusal refreshes inventory instead of suggesting force`() async throws {
        let application = AutomationTestFixtures.application(
            processIdentifier: 42,
            processStartIdentity: 7,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture"
        )
        let applications = OutcomeStubApplicationService(applications: [application])
        applications.quitShouldSucceed = false
        applications.actionOutcome = .refused(route: .bridge, reason: .targetUnavailable)
        let services = TestServicesFactory.makePeekabooServices(applications: applications)
        let arguments = [
            "app", "quit", "--pid", "42", "--expected-process-start-identity", "7",
            "--no-remote",
        ]

        let jsonResult = try await InProcessCommandRunner.run(arguments + ["--json"], services: services)
        let object = try Self.jsonObject(jsonResult.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        let hint = try #require(error["hint"] as? String)

        #expect(jsonResult.exitStatus == 1)
        #expect(object["success"] as? Bool == false)
        #expect(object["effect"] as? String == "refused")
        #expect(projection["state"] as? String == "refused")
        #expect(projection["route"] as? String == "bridge")
        #expect(projection["refusal_reason"] as? String == "target_unavailable")
        #expect(projection["escalation"] as? String == "refresh_target")
        #expect(projection["retry_safe"] as? Bool == true)
        #expect(error["retry_safe"] as? Bool == true)
        #expect(error["mutation_dispatched"] as? Bool == false)
        #expect(hint.contains("Refresh the application inventory"))
        #expect(hint.contains("current target"))
        #expect(!hint.contains("--force"))

        let humanResult = try await InProcessCommandRunner.run(arguments, services: services)
        #expect(humanResult.exitStatus == 1)
        #expect(humanResult.stdout.contains(hint))
        #expect(!humanResult.combinedOutput.contains("--force"))
    }

    @Test
    func `quit batch preserves compatible pre-dispatch refusals`() async throws {
        let applications = [
            AutomationTestFixtures.application(
                processIdentifier: 42,
                processStartIdentity: 7,
                bundleIdentifier: "com.example.first",
                name: "First Fixture",
                isHiddenKnown: true,
                activationPolicy: .regular
            ),
            AutomationTestFixtures.application(
                processIdentifier: 43,
                processStartIdentity: 8,
                bundleIdentifier: "com.example.second",
                name: "Second Fixture",
                isHiddenKnown: true,
                activationPolicy: .regular
            ),
        ]
        let refusal = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .targetUnavailable,
            message: "The pinned application target changed"
        )
        let service = ReceiptlessBatchQuitApplicationService(
            applications: applications,
            errors: [refusal, refusal]
        )
        let services = TestServicesFactory.makePeekabooServices(applications: service)

        let result = try await InProcessCommandRunner.run(
            ["app", "quit", "--all", "--json", "--no-remote"],
            services: services
        )
        let object = try Self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(object["effect"] as? String == "refused")
        #expect(outcome["state"] as? String == "refused")
        #expect(outcome["route"] as? String == "bridge")
        #expect(outcome["refusal_reason"] as? String == "target_unavailable")
        #expect(outcome["mutation_dispatched"] as? Bool == false)
        #expect(outcome["retry_safe"] as? Bool == true)
        #expect(error["mutation_dispatched"] as? Bool == false)
        #expect(error["retry_safe"] as? Bool == true)
        #expect((error["hint"] as? String)?.contains("Refresh the application inventory") == true)
    }

    @Test
    func `single app quit preserves an indeterminate failure receipt and legacy data`() async throws {
        let application = AutomationTestFixtures.application(
            processIdentifier: 42,
            processStartIdentity: 7,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture"
        )
        let applications = OutcomeStubApplicationService(applications: [application])
        applications.quitError = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .responseLost,
            unitCount: .one,
            message: "Quit response was lost",
            hint: "Observe the process before retrying."
        )
        let services = TestServicesFactory.makePeekabooServices(applications: applications)

        let result = try await InProcessCommandRunner.run(
            [
                "app", "quit", "--pid", "42", "--expected-process-start-identity", "7",
                "--json", "--no-remote",
            ],
            services: services
        )
        let object = try Self.jsonObject(result.stdout)
        let data = try #require(object["data"] as? [String: Any])
        let results = try #require(data["results"] as? [[String: Any]])
        let projection = try #require(object["outcome"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(object["success"] as? Bool == false)
        #expect(object["effect"] as? String == "unverifiable")
        #expect(data["action"] as? String == "quit")
        #expect(data["force"] as? Bool == false)
        #expect(results.count == 1)
        #expect(results.first?["app_name"] as? String == "PID 42")
        #expect(results.first?["pid"] as? Int == 42)
        #expect(results.first?["success"] as? Bool == false)
        #expect(projection["state"] as? String == "indeterminate")
        #expect(projection["route"] as? String == "bridge")
        #expect(projection["evidence"] as? String == "response_lost")
        #expect(projection["retry_safe"] as? Bool == false)
        #expect(projection["mutation_dispatched"] as? Bool == true)
        #expect(error["code"] as? String == "INTERACTION_FAILED")
        #expect(error["retry_safe"] as? Bool == false)
        #expect(error["mutation_dispatched"] as? Bool == true)
        #expect(error["hint"] as? String == "Observe the process before retrying.")
        #expect((error["hint"] as? String)?.contains("--force") == false)

        let humanResult = try await InProcessCommandRunner.run(
            [
                "app", "quit", "--pid", "42", "--expected-process-start-identity", "7",
                "--no-remote",
            ],
            services: services
        )
        #expect(humanResult.exitStatus == 1)
        #expect(humanResult.stdout.contains("Observe the process before retrying."))
        #expect(!humanResult.combinedOutput.contains("--force"))
    }

    @Test
    func `unsafe quit receipt requires fresh observation instead of force`() async throws {
        let application = AutomationTestFixtures.application(
            processIdentifier: 42,
            processStartIdentity: 7,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture"
        )
        let applications = OutcomeStubApplicationService(applications: [application])
        applications.quitShouldSucceed = false
        applications.actionOutcome = .partial(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one
        )
        let services = TestServicesFactory.makePeekabooServices(applications: applications)
        let arguments = [
            "app", "quit", "--pid", "42", "--expected-process-start-identity", "7",
            "--no-remote",
        ]

        let jsonResult = try await InProcessCommandRunner.run(arguments + ["--json"], services: services)
        let object = try Self.jsonObject(jsonResult.stdout)
        let error = try #require(object["error"] as? [String: Any])
        let hint = try #require(error["hint"] as? String)
        #expect(jsonResult.exitStatus == 1)
        #expect(hint.contains("fresh observation"))
        #expect(!hint.contains("--force"))

        let humanResult = try await InProcessCommandRunner.run(arguments, services: services)
        #expect(humanResult.exitStatus == 1)
        #expect(humanResult.stdout.contains(hint))
        #expect(!humanResult.combinedOutput.contains("--force"))
    }

    @Test
    func `quit batch keeps response loss unsafe when another attempt has no receipt`() async throws {
        let applications = [
            AutomationTestFixtures.application(
                processIdentifier: 42,
                processStartIdentity: 7,
                bundleIdentifier: "com.example.first",
                name: "First Fixture",
                isHiddenKnown: true,
                activationPolicy: .regular
            ),
            AutomationTestFixtures.application(
                processIdentifier: 43,
                processStartIdentity: 8,
                bundleIdentifier: "com.example.second",
                name: "Second Fixture",
                isHiddenKnown: true,
                activationPolicy: .regular
            ),
        ]
        let service = ReceiptlessBatchQuitApplicationService(
            applications: applications,
            errors: [
                DesktopActionFailure.indeterminate(
                    route: .bridge,
                    delivery: .init(mechanism: .nativeFramework, mode: .background),
                    evidence: .responseLost,
                    unitCount: .one,
                    message: "Quit response was lost"
                ),
                PeekabooError.commandFailed("Legacy quit failed without a canonical receipt"),
            ]
        )
        let services = TestServicesFactory.makePeekabooServices(applications: service)

        let result = try await InProcessCommandRunner.run(
            ["app", "quit", "--all", "--json", "--no-remote"],
            services: services
        )
        let object = try Self.jsonObject(result.stdout)
        let data = try #require(object["data"] as? [String: Any])
        let results = try #require(data["results"] as? [[String: Any]])
        let outcome = try #require(object["outcome"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(object["success"] as? Bool == false)
        #expect(object["effect"] as? String == "unverifiable")
        #expect(data["action"] as? String == "quit")
        #expect(results.count == 2)
        #expect(results.map { $0["app_name"] as? String } == ["First Fixture", "Second Fixture"])
        #expect(results.allSatisfy { $0["success"] as? Bool == false })
        #expect(outcome["state"] as? String == "indeterminate")
        #expect(outcome["route"] as? String == "bridge")
        #expect(outcome["evidence"] as? String == "response_lost")
        #expect(outcome["dispatch_state"] as? String == "may_have_dispatched")
        #expect(outcome["dispatched_unit_count"] as? Int == 2)
        #expect(outcome["retry_safe"] as? Bool == false)
        #expect(outcome["requires_fresh_observation"] as? Bool == true)
        #expect(error["retry_safe"] as? Bool == false)
        #expect(error["mutation_dispatched"] as? Bool == true)
        #expect((error["hint"] as? String)?.contains("fresh observation") == true)
    }

    @Test
    func `legacy quit batch keeps receiptless failure effect and payload`() async throws {
        let applications = [
            AutomationTestFixtures.application(
                processIdentifier: 42,
                processStartIdentity: 7,
                bundleIdentifier: "com.example.first",
                name: "First Fixture",
                isHiddenKnown: true,
                activationPolicy: .regular
            ),
            AutomationTestFixtures.application(
                processIdentifier: 43,
                processStartIdentity: 8,
                bundleIdentifier: "com.example.second",
                name: "Second Fixture",
                isHiddenKnown: true,
                activationPolicy: .regular
            ),
        ]
        let service = ReceiptlessBatchQuitApplicationService(
            applications: applications,
            errors: [
                PeekabooError.commandFailed("First legacy quit failed"),
                PeekabooError.commandFailed("Second legacy quit failed"),
            ]
        )
        let services = TestServicesFactory.makePeekabooServices(applications: service)

        let result = try await InProcessCommandRunner.run(
            ["app", "quit", "--all", "--json", "--no-remote"],
            services: services
        )
        let object = try Self.jsonObject(result.stdout)
        let data = try #require(object["data"] as? [String: Any])
        let results = try #require(data["results"] as? [[String: Any]])
        let error = try #require(object["error"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(object["success"] as? Bool == false)
        #expect(object["effect"] as? String == "suspected_noop")
        #expect(object["outcome"] == nil)
        #expect(data["action"] as? String == "quit")
        #expect(data["force"] as? Bool == false)
        #expect(results.map { $0["app_name"] as? String } == ["First Fixture", "Second Fixture"])
        #expect(results.allSatisfy { $0["success"] as? Bool == false })
        #expect(error["retry_safe"] == nil)
        #expect(error["mutation_dispatched"] == nil)
    }

    @Test
    func `quit batch preserves possible dispatch when its first legacy attempt cancels`() async throws {
        let applications = [
            AutomationTestFixtures.application(
                processIdentifier: 42,
                processStartIdentity: 7,
                bundleIdentifier: "com.example.first",
                name: "First Fixture",
                isHiddenKnown: true,
                activationPolicy: .regular
            ),
            AutomationTestFixtures.application(
                processIdentifier: 43,
                processStartIdentity: 8,
                bundleIdentifier: "com.example.second",
                name: "Second Fixture",
                isHiddenKnown: true,
                activationPolicy: .regular
            ),
        ]
        let service = ReceiptlessBatchQuitApplicationService(
            applications: applications,
            errors: [CancellationError(), PeekabooError.commandFailed("must not run")]
        )
        let services = TestServicesFactory.makePeekabooServices(applications: service)

        let result = try await InProcessCommandRunner.run(
            ["app", "quit", "--all", "--json", "--no-remote"],
            services: services
        )
        let object = try Self.jsonObject(result.stdout)
        let data = try #require(object["data"] as? [String: Any])
        let results = try #require(data["results"] as? [[String: Any]])
        let outcome = try #require(object["outcome"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(service.quitCallCount == 1)
        #expect(results.isEmpty)
        #expect(object["effect"] as? String == "unverifiable")
        #expect(outcome["state"] as? String == "indeterminate")
        #expect(outcome["dispatch_state"] as? String == "may_have_dispatched")
        #expect(outcome["dispatched_unit_count"] as? Int == 1)
        #expect(outcome["retry_safe"] as? Bool == false)
        #expect(outcome["requires_fresh_observation"] as? Bool == true)
        #expect(error["retry_safe"] as? Bool == false)
        #expect(error["mutation_dispatched"] as? Bool == true)
    }

    @Test
    func `quit batch fails closed when a receiptless prefix precedes cancellation`() async throws {
        let applications = [
            AutomationTestFixtures.application(
                processIdentifier: 42,
                processStartIdentity: 7,
                bundleIdentifier: "com.example.first",
                name: "First Fixture",
                isHiddenKnown: true,
                activationPolicy: .regular
            ),
            AutomationTestFixtures.application(
                processIdentifier: 43,
                processStartIdentity: 8,
                bundleIdentifier: "com.example.second",
                name: "Second Fixture",
                isHiddenKnown: true,
                activationPolicy: .regular
            ),
        ]
        let service = ReceiptlessBatchQuitApplicationService(
            applications: applications,
            errors: [CancellationError()],
            successfulCallsBeforeErrors: 1
        )
        let services = TestServicesFactory.makePeekabooServices(applications: service)

        let result = try await InProcessCommandRunner.run(
            ["app", "quit", "--all", "--json", "--no-remote"],
            services: services
        )
        let object = try Self.jsonObject(result.stdout)
        let data = try #require(object["data"] as? [String: Any])
        let results = try #require(data["results"] as? [[String: Any]])
        let error = try #require(object["error"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(service.quitCallCount == 2)
        #expect(results.count == 1)
        #expect(results.first?["success"] as? Bool == false)
        #expect(object["effect"] as? String == "unverifiable")
        let outcome = try #require(object["outcome"] as? [String: Any])
        #expect(outcome["state"] as? String == "indeterminate")
        #expect(outcome["dispatch_state"] as? String == "may_have_dispatched")
        #expect(outcome["dispatched_unit_count"] == nil)
        #expect(outcome["retry_safe"] as? Bool == false)
        #expect(outcome["requires_fresh_observation"] as? Bool == true)
        #expect(error["retry_safe"] as? Bool == false)
        #expect(error["mutation_dispatched"] as? Bool == true)
        #expect((error["message"] as? String)?.contains("cancelled after 1 of 2") == true)
    }

    @Test
    func `quit batch cancellation cannot confirm only its completed canonical prefix`() async throws {
        let applications = [
            AutomationTestFixtures.application(
                processIdentifier: 42,
                processStartIdentity: 7,
                bundleIdentifier: "com.example.first",
                name: "First Fixture",
                isHiddenKnown: true,
                activationPolicy: .regular
            ),
            AutomationTestFixtures.application(
                processIdentifier: 43,
                processStartIdentity: 8,
                bundleIdentifier: "com.example.second",
                name: "Second Fixture",
                isHiddenKnown: true,
                activationPolicy: .regular
            ),
        ]
        let service = OutcomeStubApplicationService(applications: applications)
        service.quitActionSteps = [
            .result(
                payload: true,
                outcome: .confirmedChange(
                    route: .bridge,
                    delivery: .init(mechanism: .nativeFramework, mode: .background),
                    unitCount: .one
                )
            ),
            .failure(CancellationError()),
        ]
        let services = TestServicesFactory.makePeekabooServices(applications: service)

        let result = try await InProcessCommandRunner.run(
            ["app", "quit", "--all", "--json", "--no-remote"],
            services: services
        )
        let object = try Self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(service.quitActionResultCallCount == 2)
        #expect(object["success"] as? Bool == false)
        #expect(object["effect"] as? String == "unverifiable")
        #expect(outcome["state"] as? String == "indeterminate")
        #expect(outcome["route"] as? String == "bridge")
        #expect(outcome["dispatch_state"] as? String == "may_have_dispatched")
        #expect(outcome["dispatched_unit_count"] as? Int == 2)
        #expect(outcome["retry_safe"] as? Bool == false)
        #expect(outcome["requires_fresh_observation"] as? Bool == true)
        #expect(error["retry_safe"] as? Bool == false)
        #expect(error["mutation_dispatched"] as? Bool == true)
    }

    @Test
    func `quit batch cancellation between targets preserves a pre-dispatch refusal`() async throws {
        let applications = [
            AutomationTestFixtures.application(
                processIdentifier: 42,
                processStartIdentity: 7,
                bundleIdentifier: "com.example.first",
                name: "First Fixture",
                isHiddenKnown: true,
                activationPolicy: .regular
            ),
            AutomationTestFixtures.application(
                processIdentifier: 43,
                processStartIdentity: 8,
                bundleIdentifier: "com.example.second",
                name: "Second Fixture",
                isHiddenKnown: true,
                activationPolicy: .regular
            ),
        ]
        let refusal = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .targetUnavailable,
            message: "Target unavailable"
        )
        let service = OutcomeStubApplicationService(applications: applications)
        service.quitActionSteps = [.failureAndCancel(refusal)]
        let services = TestServicesFactory.makePeekabooServices(applications: service)

        let result = try await Task {
            try await InProcessCommandRunner.run(
                ["app", "quit", "--all", "--json", "--no-remote"],
                services: services
            )
        }.value
        let object = try Self.jsonObject(result.stdout)
        let data = try #require(object["data"] as? [String: Any])
        let results = try #require(data["results"] as? [[String: Any]])
        let outcome = try #require(object["outcome"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(service.quitActionResultCallCount == 1)
        #expect(results.count == 1)
        #expect(results.first?["success"] as? Bool == false)
        #expect(object["effect"] as? String == "refused")
        #expect(outcome["state"] as? String == "refused")
        #expect(outcome["refusal_reason"] as? String == "target_unavailable")
        #expect(outcome["dispatch_state"] as? String == "none")
        #expect(outcome["retry_safe"] as? Bool == true)
        #expect(error["retry_safe"] as? Bool == true)
        #expect(error["mutation_dispatched"] as? Bool == false)
    }

    @Test
    func `explicit snapshot refuses a second mutation after observe before retry outcome`() async throws {
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted
        )
        let snapshots = StubSnapshotManager()
        let application = AutomationTestFixtures.application(
            processIdentifier: 12345,
            processStartIdentity: 7,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            activationPolicy: .regular
        )
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [application]),
            snapshots: snapshots,
            automation: automation
        )
        let snapshotID = try await Self.storeExactWindowElementSnapshot(in: snapshots)
        let arguments = [
            "click", "--on", "elem_3", "--snapshot", snapshotID,
            "--no-remote", "--json",
        ]

        let first = try await InProcessCommandRunner.run(arguments, services: services)
        let firstObject = try Self.jsonObject(first.stdout)
        let firstOutcome = try #require(firstObject["outcome"] as? [String: Any])
        #expect(first.exitStatus == 0)
        #expect(firstOutcome["requires_fresh_observation"] as? Bool == true)
        #expect(firstOutcome["retry_safe"] as? Bool == false)
        #expect(automation.targetedClickCalls.count == 1)

        let second = try await InProcessCommandRunner.run(arguments, services: services)
        let secondObject = try Self.jsonObject(second.stdout)
        let secondOutcome = try #require(secondObject["outcome"] as? [String: Any])
        let secondError = try #require(secondObject["error"] as? [String: Any])
        #expect(second.exitStatus == 1)
        #expect(secondError["code"] as? String == ErrorCode.SNAPSHOT_STALE.rawValue)
        #expect(secondOutcome["state"] as? String == "refused")
        #expect(secondOutcome["mutation_dispatched"] as? Bool == false)
        #expect(automation.targetedClickCalls.count == 1)
        #expect(second.combinedOutput.contains("fresh observation"))

        // The snapshot remains evidence: only another mutation is refused.
        #expect(try await snapshots.getDetectionResult(snapshotId: snapshotID) != nil)
    }

    @Test
    func `missing canonical outcome conservatively consumes snapshot for mutation`() async throws {
        let snapshots = StubSnapshotManager()
        let snapshotID = try await Self.storeElementSnapshot(in: snapshots)
        var dispatchCount = 0

        _ = try await SnapshotMutationCoordinator.perform(
            snapshotId: snapshotID,
            snapshots: snapshots,
            operation: {
                dispatchCount += 1
                return ()
            },
            outcome: { _ in nil }
        )

        await #expect(throws: PreDispatchActionError.self) {
            _ = try await SnapshotMutationCoordinator.perform(
                snapshotId: snapshotID,
                snapshots: snapshots,
                operation: {
                    dispatchCount += 1
                    return ()
                },
                outcome: { _ in nil }
            )
        }
        #expect(dispatchCount == 1)
        #expect(try await snapshots.getDetectionResult(snapshotId: snapshotID) != nil)
    }

    @Test(arguments: LeaseFinalizationFailure.allCases)
    func `successful mutation becomes indeterminate when lease finalization fails`(
        failureFixture: LeaseFinalizationFailure
    ) async throws {
        let snapshots = StubSnapshotManager()
        let snapshotID = try await Self.storeElementSnapshot(in: snapshots)
        let finalizationError = failureFixture.error
        snapshots.mutationFinishError = finalizationError
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: .accessibilityAction,
            mode: .background
        )
        let expectedOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: delivery,
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2)
        )
        var dispatchCount = 0

        let failure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await SnapshotMutationCoordinator.perform(
                snapshotId: snapshotID,
                snapshots: snapshots,
                operation: {
                    dispatchCount += 1
                    return "delivered"
                },
                outcome: { _ in expectedOutcome }
            )
        }

        let projection = try #require(failure?.outcome.projection)
        #expect(projection.state == .indeterminate)
        #expect(projection.route == .bridge)
        #expect(projection.deliveryMechanism == delivery.mechanism)
        #expect(projection.deliveryMode == delivery.mode)
        #expect(projection.evidence == .completionUnknown)
        #expect(projection.dispatchState == .mayHaveDispatched(unitCount: DesktopActionOutcome.DispatchUnitCount(2)))
        #expect(projection.dispatchedUnitCount?.rawValue == 2)
        #expect(projection.mutationDispatched)
        #expect(projection.retrySafety == .unsafe)
        #expect(!projection.retrySafe)
        #expect(projection.escalation == .observeBeforeRetry)
        #expect(projection.requiresFreshObservation)
        #expect(failure?.message.contains("could not finalize") == true)
        #expect(failure?.hint?.contains("do not reuse this snapshot") == true)
        #expect(failure?.causeDescription == finalizationError.localizedDescription)
        #expect(dispatchCount == 1)
        await #expect(throws: PreDispatchActionError.self) {
            _ = try await SnapshotMutationCoordinator.perform(
                snapshotId: snapshotID,
                snapshots: snapshots,
                operation: {
                    dispatchCount += 1
                    return "duplicate"
                },
                outcome: { _ in expectedOutcome }
            )
        }
        #expect(dispatchCount == 1)
        #expect(try await snapshots.getDetectionResult(snapshotId: snapshotID) != nil)
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
    func `successful multi press publishes one canonical aggregate`() async throws {
        let context = Self.makeContext()
        context.automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground)
        )

        let result = try await InProcessCommandRunner.run(
            ["press", "cmd+a", "cmd+c", "--foreground", "--json", "--no-remote"],
            services: context.services
        )
        let object = try Self.jsonObject(result.stdout)

        #expect(result.exitStatus == 0)
        let projection = try #require(object["outcome"] as? [String: Any])
        #expect(object["effect"] as? String == "confirmed")
        #expect(projection["state"] as? String == "confirmed_change")
        #expect(projection["dispatched_unit_count"] as? Int == 2)
        #expect(context.automation.hotkeyCalls.count == 2)
    }

    @Test
    func `mid sequence partial failure publishes cumulative canonical projection`() async throws {
        let context = Self.makeContext()
        context.automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground)
        )
        let leafFailure = DesktopActionFailure.partial(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "Second chord partially dispatched",
            hint: "Recover the partial chord."
        )
        context.automation.failHotkey(leafFailure, onCall: 2)

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
        context.automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground)
        )
        let leafFailure = DesktopActionFailure.partial(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            message: "Second chord partially dispatched with unknown count"
        )
        context.automation.failHotkey(leafFailure, onCall: 2)

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
        context.automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground)
        )
        let leafFailure = InputDeliveryIndeterminateError(
            operation: .hotkey,
            emittedUnitCount: 2,
            causeDescription: "Second chord completion is unknown"
        )
        context.automation.failHotkey(leafFailure, onCall: 2)

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
    func `first indeterminate failure publishes canonical retry guidance`() async throws {
        let context = Self.makeContext()
        let leafFailure = InputDeliveryIndeterminateError(
            operation: .hotkey,
            emittedUnitCount: nil,
            causeDescription: "First chord completion is unknown"
        )
        context.automation.failHotkey(leafFailure, onCall: 1)

        let result = try await InProcessCommandRunner.run(
            ["press", "cmd+a", "--foreground", "--json", "--no-remote"],
            services: context.services
        )
        let object = try Self.jsonObject(result.stdout)
        let error = try #require(object["error"] as? [String: Any])
        let projection = try #require(object["outcome"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(object["effect"] as? String == "unverifiable")
        #expect(projection["state"] as? String == "indeterminate")
        #expect(projection["dispatched_unit_count"] == nil)
        #expect(error["mutation_dispatched"] as? Bool == true)
        #expect(error["retry_safe"] as? Bool == false)
    }

    @Test
    func `returned dispatched press failure invalidates prior observations`() async throws {
        let context = Self.makeContext()
        context.automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted
        )
        _ = try await context.snapshots.createSnapshot()

        let result = try await InProcessCommandRunner.run(
            ["press", "cmd+a", "--foreground", "--json", "--no-remote"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        #expect(context.snapshots.invalidationCutoffs.count == 1)
        #expect(await context.snapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `later indeterminate failure keeps aggregate count unknown when leaf count is unknown`() async throws {
        let context = Self.makeContext()
        context.automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground)
        )
        let leafFailure = InputDeliveryIndeterminateError(
            operation: .hotkey,
            emittedUnitCount: nil,
            causeDescription: "Second chord dispatch count is unknown"
        )
        context.automation.failHotkey(leafFailure, onCall: 2)

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
    func `between call failure projection preserves exact completed count`() throws {
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.dispatched(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            unitCount: DesktopActionOutcome.DispatchUnitCount(1)
        ))
        let failure = try #require(sequence.cancellationFailure(
            fallbackRoute: .local,
            message: "Key sequence outcome is indeterminate after 1 completed press",
            hint: "Observe the target before retrying this key sequence.",
            causeDescription: "Cancelled between chords"
        ))
        let projection = failure.outcome.projection

        #expect(projection.state == .indeterminate)
        #expect(projection.route == .bridge)
        #expect(projection.dispatchedUnitCount?.rawValue == 1)
        #expect(projection.mutationDispatched)
        #expect(projection.requiresFreshObservation)
    }

    @Test
    func `sequence composition preserves canonical response loss evidence and route`() {
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.dispatched(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            unitCount: DesktopActionOutcome.DispatchUnitCount(1)
        ))
        let leafFailure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .responseLost,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "Bridge response was lost"
        )
        let failure = sequence.failure(
            combining: leafFailure,
            message: "Key sequence stopped after 1 completed press",
            hint: "Observe before retrying"
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

    static func storeExactWindowElementSnapshot(in snapshots: StubSnapshotManager) async throws -> String {
        let snapshotID = try await snapshots.createSnapshot()
        let bounds = CGRect(x: 100, y: 100, width: 500, height: 400)
        let processIdentity = AutomationTestFixtures.processIdentity(
            processIdentifier: 12345,
            processStartIdentity: 7
        )
        let application = AutomationTestFixtures.application(
            processIdentifier: processIdentity.processIdentifier,
            processStartIdentity: processIdentity.processStartIdentity,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            activationPolicy: .regular
        )
        let window = AutomationTestFixtures.window(
            windowID: 42,
            title: "Fixture Window",
            bounds: bounds,
            processIdentity: processIdentity
        )
        let element = AutomationTestFixtures.detectedElement(
            id: "elem_3",
            type: .button,
            label: "Fixture",
            bounds: CGRect(x: 120, y: 140, width: 100, height: 40),
            isEnabled: true,
            attributes: ["role": "AXButton"]
        )
        try await snapshots.storeDetectionResult(
            snapshotId: snapshotID,
            result: AutomationTestFixtures.detectionResult(
                snapshotID: snapshotID,
                screenshotPath: "/tmp/fixture.png",
                elements: DetectedElements(buttons: [element]),
                windowContext: AutomationTestFixtures.windowContext(
                    application: application,
                    window: window
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

@MainActor
private final class ReceiptlessBatchQuitApplicationService: StubApplicationService {
    private var errors: [any Error]
    private(set) var quitCallCount = 0
    private let successfulCallsBeforeErrors: Int

    init(
        applications: [ServiceApplicationInfo],
        errors: [any Error],
        successfulCallsBeforeErrors: Int = 0
    ) {
        self.errors = errors
        self.successfulCallsBeforeErrors = successfulCallsBeforeErrors
        super.init(applications: applications)
    }

    override func quitApplication(request _: ApplicationQuitRequest) async throws -> Bool {
        self.quitCallCount += 1
        if self.quitCallCount <= self.successfulCallsBeforeErrors {
            return true
        }
        guard !self.errors.isEmpty else {
            Issue.record("Received more quit attempts than scripted errors")
            return false
        }
        throw self.errors.removeFirst()
    }
}
