import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

@MainActor
@Suite(.serialized, .tags(.safe))
struct CLIActionResultConsumerTests {
    @Test
    func `application launch JSON exposes authoritative decimal process receipts`() async throws {
        let launchGeneration = UInt64.max - 1
        let relaunchGeneration = UInt64.max - 2
        let originalGeneration = UInt64.max - 3
        let original = ServiceApplicationInfo(
            processIdentifier: 41,
            processStartIdentity: originalGeneration,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "Fixture"
        )
        let applications = OutcomeStubApplicationService(applications: [original])
        applications.launchResults["Fixture"] = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: launchGeneration,
            bundleIdentifier: original.bundleIdentifier,
            name: original.name
        )
        applications.launchResults["dev.peekaboo.fixture"] = ServiceApplicationInfo(
            processIdentifier: 43,
            processStartIdentity: relaunchGeneration,
            bundleIdentifier: original.bundleIdentifier,
            name: original.name
        )
        let services = TestServicesFactory.makePeekabooServices(applications: applications)

        let launch = try await InProcessCommandRunner.run(
            ["app", "launch", "Fixture", "--foreground", "--json", "--no-remote"],
            services: services
        )
        let launchData = try Self.jsonData(launch.stdout)
        #expect((launchData["process_start_identity"] as? NSNumber)?.uint64Value == launchGeneration)
        #expect(launchData["process_start_identity_decimal"] as? String == String(launchGeneration))

        let relaunch = try await InProcessCommandRunner.run(
            ["app", "relaunch", "Fixture", "--wait", "0", "--foreground", "--json", "--no-remote"],
            services: services
        )
        let relaunchData = try Self.jsonData(relaunch.stdout)
        #expect(
            relaunchData["previous_process_start_identity_decimal"] as? String == String(originalGeneration)
        )
        #expect((relaunchData["new_process_start_identity"] as? NSNumber)?.uint64Value == relaunchGeneration)
        #expect(relaunchData["new_process_start_identity_decimal"] as? String == String(relaunchGeneration))
    }

    @Test
    func `application quit JSON preserves each planned process generation`() async throws {
        let firstGeneration = UInt64.max - 5
        let secondGeneration = UInt64.max - 6
        let applications = OutcomeStubApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 41,
                processStartIdentity: firstGeneration,
                bundleIdentifier: "dev.peekaboo.first",
                name: "First",
                activationPolicy: .regular
            ),
        ])
        let services = TestServicesFactory.makePeekabooServices(applications: applications)

        let single = try await InProcessCommandRunner.run(
            [
                "app", "quit", "--pid", "41",
                "--expected-process-start-identity", String(firstGeneration),
                "--json", "--no-remote",
            ],
            services: services
        )
        let singleData = try Self.jsonData(single.stdout)
        let singleResults = try #require(singleData["results"] as? [[String: Any]])
        #expect(singleResults.first?["process_start_identity_decimal"] as? String == String(firstGeneration))

        applications.applications = [
            applications.applications[0],
            ServiceApplicationInfo(
                processIdentifier: 42,
                processStartIdentity: secondGeneration,
                bundleIdentifier: "dev.peekaboo.second",
                name: "Second",
                activationPolicy: .regular
            ),
        ]
        let all = try await InProcessCommandRunner.run(
            ["app", "quit", "--all", "--json", "--no-remote"],
            services: services
        )
        let allData = try Self.jsonData(all.stdout)
        let allResults = try #require(allData["results"] as? [[String: Any]])
        let receipts: [Int: String] = Dictionary(uniqueKeysWithValues: allResults.compactMap { result in
            guard let pid = result["pid"] as? Int,
                  let receipt = result["process_start_identity_decimal"] as? String
            else { return nil }
            return (pid, receipt)
        })
        #expect(receipts[41] == String(firstGeneration))
        #expect(receipts[42] == String(secondGeneration))
    }

    @Test
    func `single quit false payload with confirmed outcome is target-attributed indeterminate`() async throws {
        let generation = UInt64.max - 7
        let applications = OutcomeStubApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 41,
                processStartIdentity: generation,
                bundleIdentifier: "dev.peekaboo.fixture",
                name: "Fixture",
                activationPolicy: .regular
            ),
        ])
        applications.quitActionSteps = [.result(
            payload: false,
            outcome: .confirmedChange(
                route: .bridge,
                delivery: .init(mechanism: .nativeFramework, mode: .background),
                unitCount: .one
            )
        )]
        let services = TestServicesFactory.makePeekabooServices(applications: applications)

        let result = try await InProcessCommandRunner.run(
            [
                "app", "quit", "--pid", "41",
                "--expected-process-start-identity", String(generation),
                "--json", "--no-remote",
            ],
            services: services
        )
        let object = try Self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])
        let receipt = try #require(object["target_receipt"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(object["success"] as? Bool == false)
        #expect(outcome["state"] as? String == "indeterminate")
        #expect(outcome["route"] as? String == "bridge")
        #expect(outcome["dispatched_unit_count"] as? Int == 1)
        #expect(receipt["pid"] as? Int == 41)
        #expect(receipt["process_start_identity_decimal"] as? String == String(generation))
    }

    @Test
    func `application lifecycle bridge rejects non-success result payloads`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 77,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "Fixture"
        )
        let applications = OutcomeStubApplicationService(applications: [app])
        let outcomes: [DesktopActionOutcome] = [
            .refused(reason: .targetUnavailable),
            .partial(
                delivery: .init(mechanism: .nativeFramework, mode: .background),
                unitCount: .one
            ),
            .suspectedNoop(
                delivery: .init(mechanism: .nativeFramework, mode: .background),
                unitCount: .one
            ),
            .indeterminate(evidence: .completionUnknown),
        ]

        for outcome in outcomes {
            applications.actionOutcome = outcome
            await #expect(throws: DesktopActionFailure.self) {
                _ = try await ApplicationServiceBridge.launchApplication(
                    applications: applications,
                    request: .init(applicationIdentifier: "Fixture", activates: true)
                )
            }
            await #expect(throws: DesktopActionFailure.self) {
                _ = try await ApplicationServiceBridge.relaunchApplication(
                    applications: applications,
                    request: .init(
                        targetIdentifier: "PID:42",
                        expectedTargetIdentity: app.processIdentity,
                        launchRequest: .init(applicationIdentifier: "Fixture", activates: true)
                    )
                )
            }
            await #expect(throws: DesktopActionFailure.self) {
                _ = try await ApplicationServiceBridge.activateApplication(
                    applications: applications,
                    request: .init(identifier: "PID:42", expectedIdentity: app.processIdentity)
                )
            }
        }

        applications.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        _ = try await ApplicationServiceBridge.launchApplication(
            applications: applications,
            request: .init(applicationIdentifier: "Fixture", activates: true)
        )
    }

    @Test
    func `application quit bridge refuses missing identity before service dispatch`() async throws {
        let applications = OutcomeStubApplicationService(applications: [])

        do {
            _ = try await ApplicationServiceBridge.quitApplication(
                applications: applications,
                request: .init(identifier: "Fixture")
            )
            Issue.record("Expected exact quit without a process-generation identity to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.outcome.refusalReason == .invalidRequest)
        }

        #expect(applications.quitActionResultCallCount == 0)
    }

    @Test
    func `generation-pinned activation stub rejects identity borrowed from another app`() async throws {
        let first = ServiceApplicationInfo(
            processIdentifier: 41,
            processStartIdentity: 4100,
            bundleIdentifier: "dev.peekaboo.first",
            name: "First"
        )
        let second = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 4200,
            bundleIdentifier: "dev.peekaboo.second",
            name: "Second"
        )
        let applications = OutcomeStubApplicationService(applications: [first, second])

        await #expect(throws: PeekabooError.self) {
            _ = try await ApplicationServiceBridge.activateApplication(
                applications: applications,
                request: .init(identifier: "PID:41", expectedIdentity: second.processIdentity)
            )
        }

        #expect(applications.activateCalls.isEmpty)
    }

    @Test
    func `application cycle rejects a returned non-success result`() async throws {
        let automation = OutcomeStubAutomationService()
        let outcome = DesktopActionOutcome.indeterminate(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one
        )
        automation.actionOutcome = outcome
        let services = TestServicesFactory.makePeekabooServices(automation: automation)

        let result = try await InProcessCommandRunner.run(
            ["app", "switch", "--cycle", "--foreground", "--json", "--no-remote"],
            services: services
        )
        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(object["success"] as? Bool == false)
        #expect(projection["state"] as? String == outcome.state.rawValue)
        #expect(!result.stdout.contains("Cycled to next application"))
    }

    @Test
    func `application switch refuses missing generation before activation`() async throws {
        let applications = OutcomeStubApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 42,
                bundleIdentifier: "dev.peekaboo.fixture",
                name: "Fixture"
            ),
        ])
        let services = TestServicesFactory.makePeekabooServices(applications: applications)

        let result = try await InProcessCommandRunner.run(
            ["app", "switch", "--to", "Fixture", "--foreground", "--json", "--no-remote"],
            services: services
        )

        #expect(result.exitStatus == 1)
        #expect(applications.activateCalls.isEmpty)
    }

    @Test
    func `application switch post-dispatch verification failure preserves target receipt`() async throws {
        let generation: UInt64 = 9_007_199_254_740_993
        let applications = OutcomeStubApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 40,
                processStartIdentity: 400,
                bundleIdentifier: "dev.peekaboo.other",
                name: "Other"
            ),
            ServiceApplicationInfo(
                processIdentifier: 42,
                processStartIdentity: generation,
                bundleIdentifier: "dev.peekaboo.fixture",
                name: "Fixture"
            ),
        ])
        applications.actionOutcome = .dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        let services = TestServicesFactory.makePeekabooServices(applications: applications)

        let result = try await InProcessCommandRunner.run(
            ["app", "switch", "--to", "Fixture", "--verify", "--foreground", "--json", "--no-remote"],
            services: services
        )
        let object = try Self.jsonObject(result.stdout)
        let receipt = try #require(object["target_receipt"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(applications.activateCalls == ["PID:42"])
        #expect(receipt["pid"] as? Int == 42)
        #expect(receipt["process_start_identity_decimal"] as? String == String(generation))
    }

    @Test
    func `menu click publishes the service outcome without promoting it`() async throws {
        let fixture = Self.menuFixture()
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        let menu = OutcomeStubMenuService(menusByApp: [fixture.application.name: fixture.structure])
        menu.actionOutcome = outcome
        menu.actionTargetIdentity = try Self.processTarget()
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [fixture.application]),
            menu: menu
        )

        let result = try await InProcessCommandRunner.run(
            ["menu", "click", "--app", fixture.application.name, "--item", "Open", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        #expect(result.exitStatus == 0)
        #expect(object["effect"] as? String == "unverifiable")
        #expect(projection["state"] as? String == "dispatched_unverified")
        #expect(projection["route"] as? String == "bridge")
        #expect(projection["delivery_mode"] as? String == "background")
        #expect(projection["dispatched_unit_count"] as? Int == 1)
        try Self.expectProcessTarget(in: object)
        #expect(menu.clickItemCalls.map(\.item) == ["Open"])
    }

    @Test
    func `menu click refuses a fuzzy application selector before dispatch`() async throws {
        let fixture = Self.menuFixture()
        let menu = OutcomeStubMenuService(menusByApp: [fixture.application.name: fixture.structure])
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [fixture.application]),
            menu: menu
        )

        let result = try await InProcessCommandRunner.run(
            ["menu", "click", "--app", "Fixt", "--item", "Open", "--json", "--no-remote"],
            services: services
        )

        #expect(result.exitStatus == 1)
        #expect(result.combinedOutput.contains("not allowed for mutation"))
        #expect(menu.clickItemCalls.isEmpty)
        #expect(menu.clickPathCalls.isEmpty)
    }

    @Test
    func `incomplete application inventory is rendered as a retry-safe menu refusal`() async throws {
        let fixture = Self.menuFixture()
        let applications = StubApplicationService(applications: [fixture.application])
        applications.inventoryCompleteness = .partial
        applications.inventoryWarnings = ["Fixture application metadata was incomplete."]
        let menu = OutcomeStubMenuService(menusByApp: [fixture.application.name: fixture.structure])
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            menu: menu
        )

        let result = try await InProcessCommandRunner.run(
            ["menu", "click", "--app", "Fixt", "--item", "Open", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(result.exitStatus == 1)
        #expect(object["effect"] as? String == "refused")
        #expect(outcome["state"] as? String == "refused")
        #expect(outcome["dispatch_state"] as? String == "none")
        #expect(error["retry_safe"] as? Bool == true)
        #expect(error["mutation_dispatched"] as? Bool == false)
        #expect(result.combinedOutput.contains("inventory was incomplete"))
        #expect(menu.clickItemCalls.isEmpty)
        #expect(menu.clickPathCalls.isEmpty)
    }

    @Test
    func `named menu bar click publishes its AX process target`() async throws {
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        let menu = OutcomeStubMenuService(menusByApp: [:])
        menu.actionOutcome = outcome
        menu.actionTargetIdentity = try Self.processTarget()
        menu.menuBarItems = [MenuBarItemInfo(title: "Wi-Fi", index: 0)]
        menu.menuBarClickResult = PeekabooCore.ClickResult(
            elementDescription: "Wi-Fi",
            location: CGPoint(x: 100, y: 10)
        )
        let services = TestServicesFactory.makePeekabooServices(menu: menu)

        let result = try await InProcessCommandRunner.run(
            ["menubar", "click", "Wi-Fi", "--foreground", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        #expect(result.exitStatus == 0)
        #expect(object["effect"] as? String == "unverifiable")
        #expect(projection["state"] as? String == "dispatched_unverified")
        #expect(projection["route"] as? String == "bridge")
        try Self.expectProcessTarget(in: object)
        #expect(menu.menuBarNameClickCalls == ["Wi-Fi"])
    }

    @Test
    func `indexed menu bar click publishes its exact routed window receipt`() async throws {
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(3)
        )
        let menu = OutcomeStubMenuService(menusByApp: [:])
        menu.actionOutcome = outcome
        menu.actionTargetIdentity = try Self.windowTarget()
        menu.menuBarItems = [MenuBarItemInfo(title: "Wi-Fi", index: 0)]
        menu.menuBarClickResult = PeekabooCore.ClickResult(
            elementDescription: "Wi-Fi",
            location: CGPoint(x: 100, y: 10)
        )
        let services = TestServicesFactory.makePeekabooServices(menu: menu)

        let result = try await InProcessCommandRunner.run(
            ["menubar", "click", "--index", "0", "--foreground", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        #expect(result.exitStatus == 0)
        #expect(projection["state"] as? String == "dispatched_unverified")
        #expect(projection["delivery_mechanism"] as? String == "window_targeted_events")
        #expect(projection["delivery_mode"] as? String == "background")
        #expect(projection["dispatched_unit_count"] as? Int == 3)
        try Self.expectWindowTarget(in: object)
        #expect(menu.menuBarIndexClickCalls == [0])
    }

    @Test
    func `Dock commands publish their distinct canonical result carriers`() async throws {
        let dock = OutcomeStubDockService(
            items: [DockItem(index: 0, title: "Fixture", itemType: .application)]
        )
        dock.actionTargetIdentity = try Self.processTarget()
        let services = TestServicesFactory.makePeekabooServices(dock: dock)
        let cases: [(command: [String], outcome: DesktopActionOutcome, expectsTarget: Bool)] = [
            (
                ["dock", "launch", "Fixture", "--foreground", "--json", "--no-remote"],
                .dispatchedUnverified(
                    route: .bridge,
                    delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: .one
                ),
                true
            ),
            (
                ["dock", "right-click", "--app", "Fixture", "--foreground", "--json", "--no-remote"],
                .dispatchedUnverified(
                    route: .bridge,
                    delivery: .init(mechanism: .globalEvents, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: .one
                ),
                true
            ),
            (
                ["dock", "hide", "--foreground", "--json", "--no-remote"],
                .confirmedChange(
                    route: .bridge,
                    delivery: .init(mechanism: .nativeFramework, mode: .background),
                    unitCount: DesktopActionOutcome.DispatchUnitCount(2)
                ),
                false
            ),
            (
                ["dock", "show", "--foreground", "--json", "--no-remote"],
                .confirmedChange(
                    route: .bridge,
                    delivery: .init(mechanism: .nativeFramework, mode: .background),
                    unitCount: DesktopActionOutcome.DispatchUnitCount(2)
                ),
                false
            ),
        ]

        for testCase in cases {
            dock.actionOutcome = testCase.outcome
            let result = try await InProcessCommandRunner.run(testCase.command, services: services)
            let object = try Self.jsonObject(result.stdout)
            let projection = try #require(object["outcome"] as? [String: Any])
            #expect(result.exitStatus == 0, "Unexpected command failure: \(result.combinedOutput)")
            #expect(projection["state"] as? String == testCase.outcome.state.rawValue)
            #expect(projection["route"] as? String == "bridge")
            if testCase.expectsTarget {
                try Self.expectProcessTarget(in: object)
            } else {
                #expect(object["target_identity"] == nil)
                #expect(object["target_receipt"] == nil)
            }
        }

        #expect(dock.launchCalls == ["Fixture"])
        #expect(dock.rightClickCalls.count == 1)
        #expect(dock.hideCallCount == 1)
        #expect(dock.showCallCount == 1)
    }

    @Test
    func `Dock launch item disappearance preserves dispatched outcome and exact target`() async throws {
        let dock = OutcomeStubDockService(items: [
            DockItem(index: 0, title: "Fixture", itemType: .application),
        ])
        dock.actionOutcome = Self.dockLaunchOutcome
        dock.actionTargetIdentity = try Self.processTarget()
        dock.removeItemsAfterLaunch = true
        let services = TestServicesFactory.makePeekabooServices(dock: dock)

        let result = try await InProcessCommandRunner.run(
            ["dock", "launch", "Fixture", "--foreground", "--json", "--no-remote"],
            services: services
        )

        try Self.expectPostDispatchDockLaunchFailure(result, cause: "Fixture")
        #expect(dock.launchCalls == ["Fixture"])
    }

    @Test
    func `Dock launch verification failure preserves dispatched outcome and exact target`() async throws {
        let dock = OutcomeStubDockService(items: [
            DockItem(
                index: 0,
                title: "Fixture",
                itemType: .application,
                bundleIdentifier: "com.example.fixture"
            ),
        ])
        dock.actionOutcome = Self.dockLaunchOutcome
        dock.actionTargetIdentity = try Self.processTarget()
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: []),
            dock: dock
        )

        let result = try await InProcessCommandRunner.run(
            ["dock", "launch", "Fixture", "--foreground", "--verify", "--json", "--no-remote"],
            services: services
        )

        try Self.expectPostDispatchDockLaunchFailure(result, cause: "verification failed")
        #expect(dock.launchCalls == ["Fixture"])
    }

    @Test
    func `menu non-success outcomes exit nonzero with their target identity`() async throws {
        let fixture = Self.menuFixture()
        let menu = OutcomeStubMenuService(menusByApp: [fixture.application.name: fixture.structure])
        menu.actionTargetIdentity = try Self.processTarget()
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [fixture.application]),
            menu: menu
        )
        let outcomes: [DesktopActionOutcome] = [
            .refused(route: .bridge, reason: .targetUnavailable),
            .partial(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                unitCount: .one
            ),
            .suspectedNoop(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                unitCount: .one
            ),
            .indeterminate(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one
            ),
        ]

        for outcome in outcomes {
            menu.actionOutcome = outcome
            let result = try await InProcessCommandRunner.run(
                ["menu", "click", "--app", fixture.application.name, "--item", "Open", "--json", "--no-remote"],
                services: services
            )
            let object = try Self.jsonObject(result.stdout)
            let projection = try #require(object["outcome"] as? [String: Any])
            let error = try #require(object["error"] as? [String: Any])

            #expect(result.exitStatus == 1)
            #expect(object["success"] as? Bool == false)
            #expect(projection["state"] as? String == outcome.state.rawValue)
            #expect(error["retry_safe"] as? Bool == (outcome.retrySafety == .safe))
            #expect(error["mutation_dispatched"] as? Bool == outcome.dispatchState.mutationDispatched)
            try Self.expectProcessTarget(in: object)
        }
    }

    @Test
    func `Dock visibility suspected no-op exits nonzero`() async throws {
        let dock = OutcomeStubDockService()
        let outcome = DesktopActionOutcome.suspectedNoop(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: DesktopActionOutcome.DispatchUnitCount(2)
        )
        dock.actionOutcome = outcome
        let services = TestServicesFactory.makePeekabooServices(dock: dock)

        let result = try await InProcessCommandRunner.run(
            ["dock", "hide", "--foreground", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        #expect(result.exitStatus == 1)
        #expect(object["success"] as? Bool == false)
        #expect(projection["state"] as? String == "suspected_noop")
        #expect(projection["dispatched_unit_count"] as? Int == 2)
        #expect(object["target_identity"] == nil)
        #expect(object["target_receipt"] == nil)
    }

    @Test
    func `receipt-capable menu result without a target fails conservatively`() async throws {
        let fixture = Self.menuFixture()
        let menu = OutcomeStubMenuService(menusByApp: [fixture.application.name: fixture.structure])
        menu.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [fixture.application]),
            menu: menu
        )

        let result = try await InProcessCommandRunner.run(
            ["menu", "click", "--app", fixture.application.name, "--item", "Open", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        #expect(result.exitStatus == 1)
        #expect(projection["state"] as? String == "indeterminate")
        #expect(projection["route"] as? String == "local")
        #expect(projection["evidence"] as? String == "completion_unknown")
        #expect(projection["dispatched_unit_count"] as? Int == 1)
        #expect(object["target_identity"] == nil)
        try Self.expectProcessReceipt(in: object)
    }

    @Test
    func `receiptless Bridge result from a target-providing client fails conservatively`() async throws {
        let fixture = Self.menuFixture()
        let menu = OutcomeStubMenuService(menusByApp: [fixture.application.name: fixture.structure])
        menu.actionOutcome = .dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [fixture.application]),
            menu: menu
        )

        let result = try await InProcessCommandRunner.run(
            ["menu", "click", "--app", fixture.application.name, "--item", "Open", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        #expect(result.exitStatus == 1)
        #expect(projection["state"] as? String == "indeterminate")
        #expect(projection["route"] as? String == "bridge")
        #expect(projection["evidence"] as? String == "completion_unknown")
        #expect(object["target_identity"] == nil)
        try Self.expectProcessReceipt(in: object)
    }

    @Test
    func `required target validation rejects a targetless result with no outcome`() throws {
        let result = UIAutomationActionResult<Void>(
            payload: (),
            outcome: nil,
            targetIdentity: nil
        )

        do {
            _ = try validatedActionResultTargetIdentity(
                result,
                operation: "Targeted action",
                requiresTarget: true
            )
            Issue.record("Expected missing target validation failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.route == .local)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
    }

    @Test
    func `required target validation admits an explicit no-dispatch refusal`() throws {
        let result = UIAutomationActionResult<Void>(
            payload: (),
            outcome: .refused(route: .bridge, reason: .targetUnavailable),
            targetIdentity: nil
        )

        let target = try validatedActionResultTargetIdentity(
            result,
            operation: "Targeted action",
            requiresTarget: true
        )

        #expect(target == nil)
    }

    @Test
    func `successful result validation rejects a missing canonical outcome`() throws {
        let target = try DesktopTargetIdentity(processIdentity: ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 420
        ))
        let result = UIAutomationActionResult<Void>(
            payload: (),
            outcome: nil,
            targetIdentity: target
        )

        do {
            _ = try validatedSuccessfulActionResult(
                result,
                operation: "Result-aware mutation",
                requiresTarget: true
            )
            Issue.record("Expected missing outcome validation failure")
        } catch {
            let metadata = actionErrorEnvelopeMetadata(for: error, isActionCommand: true)
            #expect(metadata.outcome?.state == .indeterminate)
            #expect(metadata.outcome?.evidence == .completionUnknown)
            #expect(metadata.outcome?.retrySafety == .unsafe)
            #expect(metadata.targetIdentity == target)
            #expect(metadata.failure?.targetReceipt == target.actionTargetReceipt)
        }
    }

    @Test
    func `successful untargeted result validation rejects a missing canonical outcome`() throws {
        do {
            try validateSuccessfulActionOutcome(
                nil,
                targetIdentity: nil,
                operation: "Dock visibility"
            )
            Issue.record("Expected missing outcome validation failure")
        } catch {
            let metadata = actionErrorEnvelopeMetadata(for: error, isActionCommand: true)
            #expect(metadata.outcome?.state == .indeterminate)
            #expect(metadata.outcome?.evidence == .completionUnknown)
            #expect(metadata.outcome?.dispatchState == .mayHaveDispatched(unitCount: nil))
            #expect(metadata.outcome?.retrySafety == .unsafe)
            #expect(metadata.targetIdentity == nil)
        }
    }

    @Test
    func `successful result validation preserves rejected canonical outcome`() throws {
        let target = try DesktopTargetIdentity(processIdentity: ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 420
        ))
        let outcome = DesktopActionOutcome.partial(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            unitCount: .one
        )

        do {
            try validateSuccessfulActionOutcome(
                outcome,
                targetIdentity: target,
                operation: "Result-aware mutation"
            )
            Issue.record("Expected rejected outcome validation failure")
        } catch {
            let metadata = actionErrorEnvelopeMetadata(for: error, isActionCommand: true)
            #expect(metadata.outcome == outcome)
            #expect(metadata.effect == outcome.effect)
            #expect(metadata.retrySafe == false)
            #expect(metadata.mutationDispatched == true)
            #expect(metadata.targetIdentity == target)
            #expect(metadata.failure?.message == "Result-aware mutation did not return a successful outcome.")
            #expect(metadata.failure?.targetReceipt == target.actionTargetReceipt)
        }
    }

    @Test
    func `menu Quit keeps its completed result after the application disappears`() async throws {
        let fixture = Self.menuFixture()
        let applications = StubApplicationService(applications: [fixture.application])
        let menu = OutcomeStubMenuService(menusByApp: [fixture.application.name: fixture.structure])
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        menu.actionOutcome = outcome
        menu.actionTargetIdentity = try Self.processTarget()
        menu.actionCompleted = { applications.applications = [] }
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            menu: menu
        )

        let result = try await InProcessCommandRunner.run(
            ["menu", "click", "--app", fixture.application.name, "--item", "Quit", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        let data = try #require(object["data"] as? [String: Any])
        #expect(result.exitStatus == 0)
        #expect(object["success"] as? Bool == true)
        #expect(projection["state"] as? String == outcome.state.rawValue)
        #expect(data["app"] as? String == fixture.application.name)
        #expect(data["clicked_item"] as? String == "Quit")
        #expect(applications.applications.isEmpty)
        try Self.expectProcessTarget(in: object)
    }

    @Test
    func `post-dispatch output failure preserves canonical outcome and exact target`() throws {
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        let target = try Self.windowTarget()
        let result = UIAutomationActionResult<Void>(
            payload: (),
            outcome: outcome,
            targetIdentity: target
        )

        do {
            try withPreservedActionResultOnFailure(
                result,
                targetIdentity: target,
                operation: "Menu click"
            ) {
                throw PostDispatchOutputTestError.failed
            }
            Issue.record("Expected output-preparation failure")
        } catch {
            let envelope = try #require(error as? any ResultEnvelopeError)
            let failure = try #require(envelope.envelopeActionFailure)
            #expect(failure.outcome == outcome)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.targetReceipt?.windowID == 73)
            #expect(envelope.envelopeTargetIdentity == target)
            #expect(envelope.envelopeRetrySafe == false)
            #expect(envelope.envelopeMutationDispatched == true)
        }
    }

    @Test
    func `Menu post-processing failure preserves confirmed change target and count`() throws {
        let count = try #require(DesktopActionOutcome.DispatchUnitCount(3))
        let outcome = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            unitCount: count
        )
        let target = try Self.windowTarget()
        let result = UIAutomationActionResult<Void>(
            payload: (),
            outcome: outcome,
            targetIdentity: target
        )

        do {
            try withPreservedActionResultOnFailure(
                result,
                targetIdentity: target,
                operation: "Menu click"
            ) {
                throw PostDispatchOutputTestError.failed
            }
            Issue.record("Expected output-preparation failure")
        } catch {
            let envelope = try #require(error as? any ResultEnvelopeError)
            #expect(envelope.envelopeActionFailure == nil)
            #expect(envelope.envelopeActionOutcome == outcome)
            #expect(envelope.envelopeTargetIdentity == target)
            #expect(envelope.envelopeRetrySafe == false)
            #expect(envelope.envelopeMutationDispatched == true)

            let metadata = actionErrorEnvelopeMetadata(for: error, isActionCommand: true)
            let response = makeErrorEnvelope(
                message: error.localizedDescription,
                code: .INTERACTION_FAILED,
                retrySafe: metadata.retrySafe,
                mutationDispatched: metadata.mutationDispatched,
                actionOutcome: metadata.outcome,
                targetIdentity: metadata.targetIdentity
            )
            #expect(response.success == false)
            #expect(response.outcome?.outcome == outcome)
            #expect(response.outcome?.dispatchedUnitCount == count)
            #expect(response.error?.retry_safe == false)
            #expect(response.error?.mutation_dispatched == true)
            #expect(response.target_receipt?.windowID == 73)
        }
    }

    @Test
    func `Dock post-processing failure preserves confirmed no-change as retry safe`() throws {
        let outcome = DesktopActionOutcome.confirmedNoChange(route: .bridge)
        let result = UIAutomationActionResult<Void>(
            payload: (),
            outcome: outcome,
            targetIdentity: nil
        )

        do {
            try withPreservedActionResultOnFailure(
                result,
                targetIdentity: nil,
                operation: "Dock launch"
            ) {
                throw PostDispatchOutputTestError.failed
            }
            Issue.record("Expected output-preparation failure")
        } catch {
            let envelope = try #require(error as? any ResultEnvelopeError)
            #expect(envelope.envelopeActionFailure == nil)
            #expect(envelope.envelopeActionOutcome == outcome)
            #expect(envelope.envelopeRetrySafe == true)
            #expect(envelope.envelopeMutationDispatched == false)

            let metadata = actionErrorEnvelopeMetadata(for: error, isActionCommand: true)
            let response = makeErrorEnvelope(
                message: error.localizedDescription,
                code: .INTERACTION_FAILED,
                retrySafe: metadata.retrySafe,
                mutationDispatched: metadata.mutationDispatched,
                actionOutcome: metadata.outcome,
                targetIdentity: metadata.targetIdentity
            )
            #expect(response.success == false)
            #expect(response.outcome?.outcome == outcome)
            #expect(response.error?.retry_safe == true)
            #expect(response.error?.mutation_dispatched == false)
            #expect(response.target_identity == nil)
            #expect(response.target_receipt == nil)
        }
    }

    @Test
    func `foreground named menu click uses the pinned request without focus`() async throws {
        let fixture = Self.menuFixture()
        let menu = OutcomeStubMenuService(menusByApp: [fixture.application.name: fixture.structure])
        menu.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        menu.actionTargetIdentity = try Self.processTarget()
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [fixture.application]),
            menu: menu
        )

        let result = try await InProcessCommandRunner.run(
            [
                "menu", "click", "--app", fixture.application.name, "--item", "Open",
                "--foreground", "--no-auto-focus", "--json", "--no-remote",
            ],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        let request = try #require(menu.namedMenuItemRequests.first)
        #expect(result.exitStatus == 0)
        #expect(projection["state"] as? String == "dispatched_unverified")
        #expect(projection["delivery_mechanism"] as? String == "accessibility_action")
        #expect(projection["delivery_mode"] as? String == "foreground")
        #expect(request.appIdentifier == "PID:\(fixture.application.processIdentifier)")
        #expect(request.expectedIdentity == fixture.application.processIdentity)
        #expect(request.deliveryMode == .foreground)
        try Self.expectProcessTarget(in: object)
    }

    @Test
    func `generic CLI failure rendering preserves exact action metadata`() async throws {
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: 42,
            processStartIdentity: 9_007_199_254_740_993,
            windowID: 73
        )
        let failure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .responseLost,
            unitCount: .one,
            message: "Dock response was lost",
            hint: "Observe Dock state before retrying.",
            causeDescription: "connection reset"
        ).attributed(to: receipt)
        let dock = OutcomeStubDockService()
        dock.actionError = failure
        let services = TestServicesFactory.makePeekabooServices(dock: dock)

        let result = try await InProcessCommandRunner.run(
            ["dock", "hide", "--foreground", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        let target = try #require(object["target_receipt"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(result.exitStatus == 1)
        #expect(projection["state"] as? String == "indeterminate")
        #expect(projection["route"] as? String == "bridge")
        #expect(projection["evidence"] as? String == "response_lost")
        #expect(projection["dispatched_unit_count"] as? Int == 1)
        #expect(target["pid"] as? Int == 42)
        #expect(target["process_start_identity_decimal"] as? String == "9007199254740993")
        #expect(target["window_id"] as? Int == 73)
        #expect(error["hint"] as? String == "Observe Dock state before retrying.")
        #expect(error["details"] as? String == "connection reset")
        #expect(error["retry_safe"] as? Bool == false)
        #expect(error["mutation_dispatched"] as? Bool == true)
    }

    @Test
    func `window focus bridge preserves the service outcome`() async throws {
        let window = ServiceWindowInfo(
            windowID: 101,
            title: "Fixture",
            bounds: CGRect(x: 10, y: 20, width: 640, height: 480)
        )
        let windows = OutcomeStubWindowService(windowsByApp: ["Fixture": [window]])
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        windows.actionOutcome = outcome

        let result = try await WindowServiceBridge.focusWindow(
            windows: windows,
            target: .windowId(101)
        )

        #expect(result.outcome == outcome)
        #expect(windows.focusCalls.count == 1)
        let focusTarget = try #require(windows.focusCalls.first)
        guard case let .windowId(windowID) = focusTarget else {
            Issue.record("Expected an exact window focus target")
            return
        }
        #expect(windowID == 101)
    }

    private static func menuFixture() -> (application: ServiceApplicationInfo, structure: MenuStructure) {
        let application = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 9_007_199_254_740_993,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            bundlePath: "/Applications/Fixture.app",
            isActive: true,
            isHidden: false,
            windowCount: 1
        )
        let structure = MenuStructure(
            application: application,
            menus: [Menu(
                title: "File",
                items: [MenuItem(title: "Open", path: "File > Open")]
            )]
        )
        return (application, structure)
    }

    private static func processTarget() throws -> DesktopTargetIdentity {
        try DesktopTargetIdentity(processIdentity: ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 9_007_199_254_740_993
        ))
    }

    private static var dockLaunchOutcome: DesktopActionOutcome {
        .dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
    }

    private static func expectPostDispatchDockLaunchFailure(
        _ result: CommandRunResult,
        cause: String
    ) throws {
        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(object["success"] as? Bool == false)
        #expect(projection["state"] as? String == "dispatched_unverified")
        #expect(projection["route"] as? String == "bridge")
        #expect(projection["delivery_mechanism"] as? String == "accessibility_action")
        #expect(projection["delivery_mode"] as? String == "foreground")
        #expect(projection["dispatched_unit_count"] as? Int == 1)
        #expect(error["code"] as? String == "INTERACTION_FAILED")
        #expect(error["retry_safe"] as? Bool == false)
        #expect(error["mutation_dispatched"] as? Bool == true)
        #expect((error["details"] as? String)?.localizedCaseInsensitiveContains(cause) == true)
        try Self.expectProcessTarget(in: object)
    }

    private static func windowTarget() throws -> DesktopTargetIdentity {
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9_007_199_254_740_993,
            capturedBounds: bounds
        )
        return try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds
        ))
    }

    private static func expectProcessTarget(in object: [String: Any]) throws {
        let target = try #require(object["target_identity"] as? [String: Any])
        #expect(target["kind"] as? String == "process")
        #expect(target["pid"] as? Int == 42)
        #expect(target["process_start_identity_decimal"] as? String == "9007199254740993")
        #expect(target["window_id"] == nil)
        let receipt = try #require(object["target_receipt"] as? [String: Any])
        #expect(receipt["pid"] as? Int == 42)
        #expect(receipt["process_start_identity_decimal"] as? String == "9007199254740993")
        #expect(receipt["window_id"] == nil)
    }

    private static func expectProcessReceipt(in object: [String: Any]) throws {
        let receipt = try #require(object["target_receipt"] as? [String: Any])
        #expect(receipt["pid"] as? Int == 42)
        #expect(receipt["process_start_identity_decimal"] as? String == "9007199254740993")
        #expect(receipt["window_id"] == nil)
    }

    private static func expectWindowTarget(in object: [String: Any]) throws {
        let target = try #require(object["target_identity"] as? [String: Any])
        #expect(target["kind"] as? String == "window")
        #expect(target["pid"] as? Int == 42)
        #expect(target["process_start_identity_decimal"] as? String == "9007199254740993")
        #expect(target["window_id"] as? Int == 73)
        let receipt = try #require(object["target_receipt"] as? [String: Any])
        #expect(receipt["pid"] as? Int == 42)
        #expect(receipt["process_start_identity_decimal"] as? String == "9007199254740993")
        #expect(receipt["window_id"] as? Int == 73)
    }

    private static func jsonObject(_ output: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    private static func jsonData(_ output: String) throws -> [String: Any] {
        let object = try self.jsonObject(output)
        return try #require(object["data"] as? [String: Any])
    }
}

extension CLIActionResultConsumerTests {
    @Test
    func `foreground menu click refuses a fuzzy app before focus or menu lookup`() async throws {
        let fixture = Self.menuFixture()
        let menu = OutcomeStubMenuService(menusByApp: [fixture.application.name: fixture.structure])
        let windows = OutcomeStubWindowService(windowsByApp: [:])
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [fixture.application]),
            windows: windows,
            menu: menu
        )

        let result = try await InProcessCommandRunner.run(
            [
                "menu", "click", "--app", "Fixt", "--item", "Open",
                "--foreground", "--json", "--no-remote",
            ],
            services: services
        )

        #expect(result.exitStatus == 1)
        #expect(result.combinedOutput.contains("not allowed for mutation"))
        #expect(windows.focusCalls.isEmpty)
        #expect(menu.listMenusRequests.isEmpty)
        #expect(menu.clickItemCalls.isEmpty)
        #expect(menu.clickPathCalls.isEmpty)
    }

    @Test
    func `foreground menu path dispatch stays pinned without a separate menu lookup`() async throws {
        let fixture = Self.menuFixture()
        let pinnedIdentifier = "PID:\(fixture.application.processIdentifier)"
        let replacement = ServiceApplicationInfo(
            processIdentifier: 84,
            processStartIdentity: 84000,
            bundleIdentifier: "dev.peekaboo.replacement",
            name: fixture.application.name
        )
        let replacementMenus = MenuStructure(
            application: replacement,
            menus: [Menu(
                title: "File",
                items: [MenuItem(title: "Open", path: "File > Open")]
            )]
        )
        let menu = OutcomeStubMenuService(menusByApp: [
            fixture.application.name: replacementMenus,
            pinnedIdentifier: fixture.structure,
        ])
        menu.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        menu.actionTargetIdentity = try DesktopTargetIdentity(
            processIdentity: #require(fixture.application.processIdentity)
        )
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [fixture.application]),
            menu: menu
        )

        let result = try await InProcessCommandRunner.run(
            [
                "menu", "click", "--app", fixture.application.name, "--path", "File > Open",
                "--foreground", "--no-auto-focus", "--json", "--no-remote",
            ],
            services: services
        )

        let request = try #require(menu.menuItemRequests.first)
        #expect(result.exitStatus == 0)
        #expect(menu.listMenusRequests.isEmpty)
        #expect(menu.menuItemRequests.count == 1)
        #expect(menu.namedMenuItemRequests.isEmpty)
        #expect(request.appIdentifier == pinnedIdentifier)
        #expect(request.expectedIdentity == fixture.application.processIdentity)
        #expect(request.deliveryMode == .foreground)
    }

    @Test
    func `foreground menu without a window uses exact process activation`() async throws {
        let fixture = Self.menuFixture()
        let applications = OutcomeStubApplicationService(applications: [fixture.application])
        applications.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one
        )
        let menu = OutcomeStubMenuService(menusByApp: [fixture.application.name: fixture.structure])
        menu.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        menu.actionTargetIdentity = try Self.processTarget()
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: OutcomeStubWindowService(windowsByApp: [:]),
            menu: menu
        )

        let result = try await InProcessCommandRunner.run(
            [
                "menu", "click", "--app", fixture.application.name, "--item", "Open",
                "--foreground", "--json", "--no-remote",
            ],
            services: services
        )

        #expect(result.exitStatus == 0)
        #expect(applications.activateCalls == ["PID:\(fixture.application.processIdentifier)"])
        #expect(menu.namedMenuItemRequests.first?.expectedIdentity == fixture.application.processIdentity)
    }

    @Test
    func `foreground menu refuses a recycled PID before default activation`() async throws {
        let fixture = Self.menuFixture()
        let replacement = ServiceApplicationInfo(
            processIdentifier: fixture.application.processIdentifier,
            processStartIdentity: 84000,
            bundleIdentifier: fixture.application.bundleIdentifier,
            name: fixture.application.name
        )
        let applications = OutcomeStubApplicationService(applications: [replacement])
        applications.applicationInventorySequence = [.complete([fixture.application])]
        let menu = OutcomeStubMenuService(menusByApp: [fixture.application.name: fixture.structure])
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: OutcomeStubWindowService(windowsByApp: [:]),
            menu: menu
        )

        let result = try await InProcessCommandRunner.run(
            [
                "menu", "click", "--app", fixture.application.name, "--item", "Open",
                "--foreground", "--json", "--no-remote",
            ],
            services: services
        )

        #expect(result.exitStatus == 1)
        #expect(result.combinedOutput.contains("changed process generation"))
        #expect(applications.activateCalls.isEmpty)
        #expect(menu.namedMenuItemRequests.isEmpty)
    }

    @Test
    func `foreground menu window index resolves through the planned process`() async throws {
        let fixture = Self.menuFixture()
        let expectedIdentity = try #require(fixture.application.processIdentity)
        let pinnedIdentifier = "PID:\(expectedIdentity.processIdentifier)"
        let originalBounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let originalWindow = ServiceWindowInfo(
            windowID: 101,
            title: "Original",
            bounds: originalBounds,
            index: 0,
            mutationIdentity: WindowMutationIdentity(
                windowID: 101,
                ownerProcessIdentifier: expectedIdentity.processIdentifier,
                ownerProcessStartIdentity: expectedIdentity.processStartIdentity,
                capturedBounds: originalBounds
            )
        )
        let replacementBounds = CGRect(x: 30, y: 40, width: 600, height: 440)
        let replacementWindow = ServiceWindowInfo(
            windowID: 202,
            title: "Replacement",
            bounds: replacementBounds,
            index: 0,
            mutationIdentity: WindowMutationIdentity(
                windowID: 202,
                ownerProcessIdentifier: 84,
                ownerProcessStartIdentity: 84000,
                capturedBounds: replacementBounds
            )
        )
        let windows = OutcomeStubWindowService(windowsByApp: [
            fixture.application.name: [replacementWindow],
            pinnedIdentifier: [originalWindow],
        ])
        let menu = OutcomeStubMenuService(menusByApp: [fixture.application.name: fixture.structure])
        menu.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        menu.actionTargetIdentity = try DesktopTargetIdentity(processIdentity: expectedIdentity)
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [fixture.application]),
            windows: windows,
            menu: menu
        )

        let result = try await InProcessCommandRunner.run(
            [
                "menu", "click", "--app", fixture.application.name, "--window-index", "0",
                "--item", "Open", "--foreground", "--json", "--no-remote",
            ],
            services: services
        )

        let focused = try #require(windows.focusCalls.first)
        let request = try #require(menu.namedMenuItemRequests.first)
        #expect(result.exitStatus == 0)
        #expect(windows.focusCalls.count == 1)
        guard case let .windowId(windowID) = focused else {
            Issue.record("Expected exact planned-process window focus")
            return
        }
        #expect(windowID == originalWindow.windowID)
        #expect(request.expectedIdentity == expectedIdentity)
        #expect(request.deliveryMode == .foreground)
    }

    @Test
    func `foreground menu rejects a window owned by another process before focus`() async throws {
        let fixture = Self.menuFixture()
        let replacementBounds = CGRect(x: 30, y: 40, width: 600, height: 440)
        let replacementWindow = ServiceWindowInfo(
            windowID: 202,
            title: "Replacement",
            bounds: replacementBounds,
            mutationIdentity: WindowMutationIdentity(
                windowID: 202,
                ownerProcessIdentifier: 84,
                ownerProcessStartIdentity: 84000,
                capturedBounds: replacementBounds
            )
        )
        let windows = OutcomeStubWindowService(windowsByApp: ["Replacement": [replacementWindow]])
        let menu = OutcomeStubMenuService(menusByApp: [fixture.application.name: fixture.structure])
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [fixture.application]),
            windows: windows,
            menu: menu
        )

        let result = try await InProcessCommandRunner.run(
            [
                "menu", "click", "--app", fixture.application.name, "--window-id", "202",
                "--item", "Open", "--foreground", "--json", "--no-remote",
            ],
            services: services
        )

        #expect(result.exitStatus == 1)
        #expect(result.combinedOutput.contains("not owned by selected application"))
        #expect(windows.focusCalls.isEmpty)
        #expect(menu.namedMenuItemRequests.isEmpty)
        #expect(menu.menuItemRequests.isEmpty)
    }

    @Test
    func `foreground menu rejects a recycled PID window before default focus`() async throws {
        let fixture = Self.menuFixture()
        let replacementBounds = CGRect(x: 30, y: 40, width: 600, height: 440)
        let replacementWindow = ServiceWindowInfo(
            windowID: 202,
            title: "Replacement",
            bounds: replacementBounds,
            mutationIdentity: WindowMutationIdentity(
                windowID: 202,
                ownerProcessIdentifier: fixture.application.processIdentifier,
                ownerProcessStartIdentity: 84000,
                capturedBounds: replacementBounds
            )
        )
        let pinnedIdentifier = "PID:\(fixture.application.processIdentifier)"
        let windows = OutcomeStubWindowService(windowsByApp: [pinnedIdentifier: [replacementWindow]])
        let menu = OutcomeStubMenuService(menusByApp: [fixture.application.name: fixture.structure])
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [fixture.application]),
            windows: windows,
            menu: menu
        )

        let result = try await InProcessCommandRunner.run(
            [
                "menu", "click", "--app", fixture.application.name, "--item", "Open",
                "--foreground", "--json", "--no-remote",
            ],
            services: services
        )

        #expect(result.exitStatus == 1)
        #expect(result.combinedOutput.contains("not owned by selected application"))
        #expect(windows.focusCalls.isEmpty)
        #expect(menu.namedMenuItemRequests.isEmpty)
    }
}

private enum PostDispatchOutputTestError: Error {
    case failed
}
