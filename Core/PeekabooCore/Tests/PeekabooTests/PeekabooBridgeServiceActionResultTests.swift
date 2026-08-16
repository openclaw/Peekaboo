import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

private func fixtureMenuLeaf(
    selector: String,
    matchKind: DesktopSelectedLeafEvidence.MatchKind,
    index: Int = 0) throws -> DesktopSelectedLeafEvidence
{
    try DesktopSelectedLeafEvidence(
        kind: .menuBarItem,
        normalizedSelector: DeterministicDesktopLeafSelector.normalized(selector),
        matchKind: matchKind,
        selectedProcessIdentity: .init(processIdentifier: 701, processStartIdentity: 9001),
        selectedIndex: index,
        selectedTitle: matchKind == .index ? "\(index)" : selector,
        selectedIdentifier: "fixture.menu.\(index)",
        selectedRole: "AXStatusItem",
        selectedFrame: CGRect(x: 10 + CGFloat(index * 30), y: 10, width: 20, height: 20),
        candidateSetSHA256: String(repeating: "d", count: 64),
        candidateCount: 3)
}

private func fixtureDockLeaves(appName: String, menuItem: String? = nil) throws
    -> [DesktopSelectedLeafEvidence]
{
    let identity = ApplicationProcessIdentity(processIdentifier: 702, processStartIdentity: 9002)
    var leaves = try [DesktopSelectedLeafEvidence(
        kind: .dockItem,
        normalizedSelector: DeterministicDesktopLeafSelector.normalized(appName),
        matchKind: .exact,
        selectedProcessIdentity: identity,
        selectedIndex: 0,
        selectedTitle: appName,
        selectedIdentifier: "fixture.dock.0",
        selectedRole: "AXDockItem",
        selectedFrame: CGRect(x: 10, y: 10, width: 20, height: 20),
        candidateSetSHA256: String(repeating: "e", count: 64),
        candidateCount: 1)]
    if let menuItem {
        try leaves.append(DesktopSelectedLeafEvidence(
            kind: .dockContextMenuItem,
            normalizedSelector: DeterministicDesktopLeafSelector.normalized(menuItem),
            matchKind: .exact,
            selectedProcessIdentity: identity,
            selectedIndex: 0,
            selectedTitle: menuItem,
            selectedIdentifier: "fixture.dock.menu.0",
            selectedRole: "AXMenuItem",
            selectedFrame: CGRect(x: 10, y: 40, width: 80, height: 20),
            candidateSetSHA256: String(repeating: "f", count: 64),
            candidateCount: 1))
    }
    return leaves
}

struct PeekabooBridgeServiceActionResultTests {
    @Test
    @MainActor
    func `application hide retains the resolved process and multi-app mutations stay global`() async throws {
        let applications = StubApplicationService()
        let server = Self.server(services: ServiceActionResultServices(applications: applications))

        let activate = try await Self.handleCurrent(
            .activateApplication(.init(identifier: "StubApp")),
            with: server)
        Self.expectHandlerTarget(activate, processIdentifier: 123, processStartIdentity: 456)
        #expect(activate.outcome == applications.actionOutcome)
        #expect(applications.targetedActivationResultCount == 1)

        let hideIdentity = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 456)
        let hide = try await Self.handleCurrent(
            .hideApplication(.init(
                identifier: "PID:123",
                expectedIdentity: hideIdentity)),
            with: server)
        guard case .requestPinned = hide.mutation?.target else {
            Issue.record("Expected request-pinned application hide")
            return
        }
        #expect(hide.outcome == applications.actionOutcome)
        #expect(applications.targetedHideResultCount == 1)
        #expect(try applications.targetedHideRequests == [ApplicationHideRequest(
            identifier: "PID:123",
            expectedIdentity: hideIdentity)])

        let hideOther = try await Self.handleCurrent(
            .hideOtherApplications(.init(identifier: "StubApp")),
            with: server)
        Self.expectGlobalTarget(hideOther)
        #expect(hideOther.outcome == applications.actionOutcome)

        let showAll = try await Self.handleCurrent(.showAllApplications, with: server)
        Self.expectGlobalTarget(showAll)
        #expect(showAll.outcome == applications.actionOutcome)
    }

    @Test
    @MainActor
    func `unattested application hide retains the legacy result provider path`() async throws {
        let applications = StubApplicationService()
        let server = Self.server(services: ServiceActionResultServices(applications: applications))

        let handled = try await server.handleAuthorized(
            .hideApplication(.init(identifier: "StubApp")),
            peer: nil,
            permissions: Self.permissions)

        guard case .ok = handled.response else {
            Issue.record("Expected the legacy application hide response")
            return
        }
        #expect(applications.hideResultCount == 1)
        #expect(applications.targetedHideResultCount == 0)
    }

    @Test
    @MainActor
    func `attested application lifecycle refusals never escape through success responses`() async {
        let applications = SafeNoOpRefusingApplicationService()
        let refusal = DesktopActionOutcome.refused(reason: .targetUnavailable)
        applications.actionOutcome = refusal
        let server = Self.server(services: ServiceActionResultServices(applications: applications))
        let identity = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 456)
        let requests: [PeekabooBridgeRequest] = [
            .launchApplication(.init(identifier: "StubApp")),
            .launchApplicationWithOptions(.init(applicationIdentifier: "StubApp", activates: true)),
            .launchApplicationWithOptions(.init(applicationIdentifier: "StubApp")),
            .relaunchApplicationWithOptions(.init(
                targetIdentifier: "PID:123",
                expectedTargetIdentity: .init(processIdentifier: 123, processStartIdentity: 455),
                launchRequest: .init(applicationIdentifier: "StubApp", activates: true))),
            .activateApplication(.init(identifier: "PID:123", expectedIdentity: identity)),
            .quitApplication(.init(identifier: "PID:123", force: false, expectedIdentity: identity)),
            .hideApplication(.init(identifier: "PID:123", expectedIdentity: identity)),
            .hideOtherApplications(.init(identifier: "StubApp")),
            .showAllApplications,
        ]

        for request in requests {
            await Self.expectTargetlessRefusal(request, with: server, equals: refusal)
        }
    }

    @Test
    @MainActor
    func `unattested application refusal preserves legacy response families`() async throws {
        let applications = SafeNoOpRefusingApplicationService()
        applications.actionOutcome = .refused(reason: .targetUnavailable)
        let server = Self.server(services: ServiceActionResultServices(applications: applications))
        let identity = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 456)

        let launched = try await server.handleAuthorized(
            .launchApplication(.init(identifier: "StubApp")),
            peer: nil,
            permissions: Self.permissions)
        let checked = try await server.handleAuthorized(
            .launchApplicationWithOptions(.init(applicationIdentifier: "StubApp")),
            peer: nil,
            permissions: Self.permissions)
        let quit = try await server.handleAuthorized(
            .quitApplication(.init(identifier: "PID:123", force: false, expectedIdentity: identity)),
            peer: nil,
            permissions: Self.permissions)
        let hidden = try await server.handleAuthorized(
            .hideOtherApplications(.init(identifier: "StubApp")),
            peer: nil,
            permissions: Self.permissions)

        guard case .application = launched.response else {
            Issue.record("Expected legacy application response")
            return
        }
        guard case .application = checked.response else {
            Issue.record("Expected legacy safe-check application response")
            return
        }
        guard case .bool(false) = quit.response else {
            Issue.record("Expected legacy Boolean response")
            return
        }
        guard case .ok = hidden.response else {
            Issue.record("Expected legacy OK response")
            return
        }
    }

    @Test
    @MainActor
    func `attested application hide rejects a contradictory PID before service dispatch`() async throws {
        let applications = StubApplicationService()
        let server = Self.server(services: ServiceActionResultServices(applications: applications))

        await #expect(throws: (any Error).self) {
            _ = try await Self.handleCurrent(
                .hideApplication(.init(
                    identifier: "PID:124",
                    expectedIdentity: .init(processIdentifier: 123, processStartIdentity: 456))),
                with: server)
        }

        #expect(applications.hideResultCount == 0)
        #expect(applications.targetedHideResultCount == 0)
        #expect(applications.targetedHideRequests.isEmpty)
    }

    @Test
    @MainActor
    func `unattested activation and relaunch retain their legacy result providers`() async throws {
        let applications = StubApplicationService()
        let server = Self.server(services: ServiceActionResultServices(applications: applications))
        let relaunchRequest = ApplicationRelaunchRequest(
            targetIdentifier: "StubApp",
            launchRequest: .init(applicationBundleIdentifier: "dev.stub", activates: true))

        let activated = try await server.handleAuthorized(
            .activateApplication(.init(identifier: "StubApp")),
            peer: nil,
            permissions: Self.permissions)
        guard case .ok = activated.response else {
            Issue.record("Expected the legacy activation response")
            return
        }
        #expect(applications.activationRequests == [.init(identifier: "StubApp")])
        #expect(applications.targetedActivationResultCount == 0)

        let relaunched = try await server.handleAuthorized(
            .relaunchApplicationWithOptions(relaunchRequest),
            peer: nil,
            permissions: Self.permissions)
        guard case let .application(application) = relaunched.response else {
            Issue.record("Expected the legacy relaunch response")
            return
        }
        #expect(application.processIdentity == .init(processIdentifier: 123, processStartIdentity: 456))
        #expect(applications.relaunchRequests == [relaunchRequest])
    }

    @Test
    @MainActor
    func `attested relaunch requires old generation and resolves a distinct new one`() async throws {
        let applications = StubApplicationService()
        let server = Self.server(services: ServiceActionResultServices(applications: applications))

        do {
            _ = try await Self.handleCurrent(
                .relaunchApplicationWithOptions(.init(
                    targetIdentifier: "StubApp",
                    launchRequest: .init(applicationBundleIdentifier: "dev.stub", activates: true))),
                with: server)
            Issue.record("Expected an unpinned relaunch to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.refusalReason == .invalidRequest)
        }
        #expect(applications.relaunchRequests.isEmpty)

        let oldIdentity = ApplicationProcessIdentity(
            processIdentifier: 123,
            processStartIdentity: 455)
        let request = ApplicationRelaunchRequest(
            targetIdentifier: "PID:123",
            expectedTargetIdentity: oldIdentity,
            launchRequest: .init(applicationBundleIdentifier: "dev.stub", activates: true))
        let handled = try await Self.handleCurrent(
            .relaunchApplicationWithOptions(request),
            with: server)

        #expect(applications.relaunchRequests == [request])
        guard case let .application(application) = handled.response else {
            Issue.record("Expected the relaunched application response")
            return
        }
        #expect(application.processIdentity == .init(processIdentifier: 123, processStartIdentity: 456))
        guard case .responseResolved = handled.mutation?.target else {
            Issue.record("Expected a response-resolved relaunch target")
            return
        }

        applications.actionOutcome = .confirmedNoChange()
        do {
            _ = try await Self.handleCurrent(
                .relaunchApplicationWithOptions(request),
                with: server)
            Issue.record("Expected relaunch to reject a no-change outcome for a new generation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
        applications.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one)

        let unchangedRequest = ApplicationRelaunchRequest(
            targetIdentifier: "PID:123",
            expectedTargetIdentity: application.processIdentity,
            launchRequest: .init(applicationBundleIdentifier: "dev.stub", activates: true))
        do {
            _ = try await Self.handleCurrent(
                .relaunchApplicationWithOptions(unchangedRequest),
                with: server)
            Issue.record("Expected relaunch to reject an unchanged process generation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.mutationDispatched)
        }
    }

    @Test
    @MainActor
    func `attested application result providers cannot omit outcomes`() async throws {
        let applications = StubApplicationService()
        applications.actionOutcome = nil
        let server = Self.server(services: ServiceActionResultServices(applications: applications))
        let identity = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 456)
        let oldIdentity = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 455)
        let requests: [PeekabooBridgeRequest] = [
            .launchApplication(.init(identifier: "StubApp")),
            .launchApplicationWithOptions(.init(applicationIdentifier: "StubApp", activates: true)),
            .relaunchApplicationWithOptions(.init(
                targetIdentifier: "PID:123",
                expectedTargetIdentity: oldIdentity,
                launchRequest: .init(applicationBundleIdentifier: "dev.stub", activates: true))),
            .activateApplication(.init(identifier: "PID:123", expectedIdentity: identity)),
            .quitApplication(.init(identifier: "PID:123", force: false, expectedIdentity: identity)),
            .hideApplication(.init(identifier: "PID:123", expectedIdentity: identity)),
            .hideOtherApplications(.init(identifier: "StubApp")),
            .showAllApplications,
        ]

        for request in requests {
            do {
                _ = try await Self.handleCurrent(request, with: server)
                Issue.record("Expected missing outcome failure for \(request.operation.rawValue)")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .indeterminate)
                #expect(failure.outcome.route == .bridge)
                #expect(failure.outcome.retrySafety == .unsafe)
            }
        }

        let safeNoOpApplications = SafeNoOpRefusingApplicationService()
        safeNoOpApplications.actionOutcome = nil
        let safeNoOpServer = Self.server(services: ServiceActionResultServices(
            applications: safeNoOpApplications))
        do {
            _ = try await Self.handleCurrent(
                .launchApplicationWithOptions(.init(applicationIdentifier: "StubApp")),
                with: safeNoOpServer)
            Issue.record("Expected safe background launch missing-outcome failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.route == .bridge)
        }
    }

    @Test
    @MainActor
    func `attested legacy application providers retain explicit compatibility synthesis`() async throws {
        let applications = LegacyApplicationService()
        let server = Self.server(services: ServiceActionResultServices(applications: applications))
        let identity = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 456)
        let oldIdentity = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 455)
        let requests: [PeekabooBridgeRequest] = [
            .launchApplication(.init(identifier: "StubApp")),
            .launchApplicationWithOptions(.init(applicationIdentifier: "StubApp", activates: true)),
            .relaunchApplicationWithOptions(.init(
                targetIdentifier: "PID:123",
                expectedTargetIdentity: oldIdentity,
                launchRequest: .init(applicationBundleIdentifier: "dev.legacy", activates: true))),
            .activateApplication(.init(identifier: "PID:123", expectedIdentity: identity)),
            .hideOtherApplications(.init(identifier: "StubApp")),
            .showAllApplications,
        ]

        for request in requests {
            let handled = try await Self.handleCurrent(request, with: server)
            #expect(handled.outcome?.state == .dispatchedUnverified)
        }
        do {
            _ = try await Self.handleCurrent(
                .quitApplication(.init(identifier: "PID:123", force: false, expectedIdentity: identity)),
                with: server)
            Issue.record("Expected exact legacy quit to require a canonical outcome")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.route == .bridge)
            #expect(failure.targetReceipt == .init(
                processIdentifier: identity.processIdentifier,
                processStartIdentity: identity.processStartIdentity))
        }
        let safeNoOp = try await Self.handleCurrent(
            .launchApplicationWithOptions(.init(applicationIdentifier: "StubApp")),
            with: server)
        #expect(safeNoOp.outcome == nil)
    }

    @Test
    @MainActor
    func `every menu mutation carries its exact owner and native outcome`() async throws {
        let menu = try ResultMenuService()
        let server = Self.server(services: ServiceActionResultServices(menu: menu))
        let requests: [PeekabooBridgeRequest] = try [
            .clickMenuItem(.init(
                appIdentifier: "PID:701",
                itemPath: "File > New",
                expectedIdentity: .init(processIdentifier: 701, processStartIdentity: 9001))),
            .clickMenuItemByName(.init(
                appIdentifier: "PID:701",
                itemName: "New",
                expectedIdentity: .init(processIdentifier: 701, processStartIdentity: 9001))),
            .clickMenuExtra(.init(name: "Clock")),
            .clickMenuBarItemNamed(.init(
                name: "Clock",
                expectedLeafEvidence: fixtureMenuLeaf(selector: "Clock", matchKind: .exact))),
            .clickMenuBarItemIndex(.init(
                index: 2,
                expectedLeafEvidence: fixtureMenuLeaf(selector: "2", matchKind: .index, index: 2))),
        ]

        for request in requests {
            let handled = try await Self.handleCurrent(request, with: server)
            switch request.operation {
            case .clickMenuItem, .clickMenuItemByName:
                guard case .requestPinned = handled.mutation?.target else {
                    Issue.record("Expected a request-pinned application-menu target")
                    continue
                }
            default:
                Self.expectHandlerTarget(handled, processIdentifier: 701, processStartIdentity: 9001)
            }
            let expectedOutcome = switch request.operation {
            case .clickMenuItem, .clickMenuItemByName:
                menu.applicationMenuOutcome()
            default:
                menu.outcome
            }
            #expect(handled.outcome == expectedOutcome, "Wrong outcome for \(request.operation.rawValue)")
        }
        #expect(menu.actionCount == requests.count)
        #expect(menu.pinnedDeliveryModes == [.background, .background])
    }

    @Test
    @MainActor
    func `attested menu request without explicit delivery mode refuses before dispatch`() async throws {
        let menu = try ResultMenuService()
        let server = Self.server(services: ServiceActionResultServices(menu: menu))
        let payload = PeekabooBridgeMenuClickRequest(
            appIdentifier: "PID:701",
            itemPath: "File > New",
            expectedIdentity: .init(processIdentifier: 701, processStartIdentity: 9001))
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        object.removeValue(forKey: "deliveryMode")
        let legacyShape = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PeekabooBridgeMenuClickRequest.self, from: legacyShape)

        do {
            _ = try await Self.handleCurrent(.clickMenuItem(decoded), with: server)
            Issue.record("Expected an attested request without delivery mode to fail closed")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
        }
        #expect(menu.actionCount == 0)
    }

    @Test
    @MainActor
    func `attested menu provider cannot contradict background delivery`() async throws {
        let foreground = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let menu = try ResultMenuService(outcome: foreground)
        let server = Self.server(services: ServiceActionResultServices(menu: menu))

        do {
            _ = try await Self.handleCurrent(
                .clickMenuItem(.init(
                    appIdentifier: "PID:701",
                    itemPath: "File > New",
                    expectedIdentity: .init(processIdentifier: 701, processStartIdentity: 9001))),
                with: server)
            Issue.record("Expected the provider delivery contradiction to fail closed")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery?.mode == .foreground)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
        }
        #expect(menu.actionCount == 1)
    }

    @Test
    @MainActor
    func `targetless app menu and Dock refusals retain their retry-safe outcome`() async throws {
        let applications = TargetlessRefusalApplicationService()
        let appServer = Self.server(services: ServiceActionResultServices(applications: applications))
        for request in [
            PeekabooBridgeRequest.activateApplication(.init(identifier: "StubApp")),
            .hideApplication(.init(
                identifier: "PID:123",
                expectedIdentity: .init(processIdentifier: 123, processStartIdentity: 456))),
        ] {
            await Self.expectTargetlessRefusal(request, with: appServer, equals: applications.refusal)
        }

        let menu = try ResultMenuService(outcome: applications.refusal, includesTarget: false)
        let menuServer = Self.server(services: ServiceActionResultServices(menu: menu))
        let menuRequests: [PeekabooBridgeRequest] = try [
            .clickMenuItem(.init(
                appIdentifier: "PID:701",
                itemPath: "File > New",
                expectedIdentity: .init(processIdentifier: 701, processStartIdentity: 9001))),
            .clickMenuItemByName(.init(
                appIdentifier: "PID:701",
                itemName: "New",
                expectedIdentity: .init(processIdentifier: 701, processStartIdentity: 9001))),
            .clickMenuExtra(.init(name: "Clock")),
            .clickMenuBarItemNamed(.init(
                name: "Clock",
                expectedLeafEvidence: fixtureMenuLeaf(selector: "Clock", matchKind: .exact))),
            .clickMenuBarItemIndex(.init(
                index: 2,
                expectedLeafEvidence: fixtureMenuLeaf(selector: "2", matchKind: .index, index: 2))),
        ]
        for request in menuRequests {
            await Self.expectTargetlessRefusal(request, with: menuServer, equals: applications.refusal)
        }
        #expect(menu.actionCount == menuRequests.count)

        let dock = try ResultDockService(itemOutcome: applications.refusal, includesTarget: false)
        let dockServer = Self.server(services: ServiceActionResultServices(dock: dock))
        let dockRequests: [PeekabooBridgeRequest] = [
            .launchDockItem(.init(appName: "Safari")),
            .rightClickDockItem(.init(appName: "Safari", menuItem: "Options")),
        ]
        for request in dockRequests {
            await Self.expectTargetlessRefusal(request, with: dockServer, equals: applications.refusal)
        }
        #expect(dock.itemActionCount == dockRequests.count)
    }

    @Test
    @MainActor
    func `target-bearing refusal is emitted before successful response handling`() async throws {
        let refusal = DesktopActionOutcome.refused(reason: .targetUnavailable)
        let menu = try ResultMenuService(outcome: refusal)
        let server = Self.server(services: ServiceActionResultServices(menu: menu))

        do {
            _ = try await Self.handleCurrent(
                .clickMenuItem(.init(
                    appIdentifier: "PID:701",
                    itemPath: "File > New",
                    expectedIdentity: .init(processIdentifier: 701, processStartIdentity: 9001))),
                with: server)
            Issue.record("Expected target-bearing refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == refusal)
            #expect(failure.outcome.dispatchState == .none)
        }
    }

    @Test
    @MainActor
    func `attested menu and Dock providers cannot omit canonical outcomes`() async throws {
        let menu = try ResultMenuService(reportsOutcome: false)
        let menuServer = Self.server(services: ServiceActionResultServices(menu: menu))
        await Self.expectIndeterminateMissingOutcome(
            .clickMenuItem(.init(
                appIdentifier: "PID:701",
                itemPath: "File > New",
                expectedIdentity: .init(processIdentifier: 701, processStartIdentity: 9001))),
            with: menuServer)

        let dock = try ResultDockService(reportsOutcome: false)
        let dockServer = Self.server(services: ServiceActionResultServices(dock: dock))
        await Self.expectIndeterminateMissingOutcome(.launchDockItem(.init(appName: "Safari")), with: dockServer)
        await Self.expectIndeterminateMissingOutcome(.hideDock, with: dockServer)
    }

    @Test
    @MainActor
    func `menu mutation refuses before dispatch when service cannot return an owner`() async throws {
        let menu = LegacyMenuService()
        let server = Self.server(services: ServiceActionResultServices(menu: menu))

        do {
            _ = try await Self.handleCurrent(
                .clickMenuItem(.init(
                    appIdentifier: "PID:701",
                    itemPath: "File > New",
                    expectedIdentity: .init(processIdentifier: 701, processStartIdentity: 9001))),
                with: server)
            Issue.record("Expected an owner-less menu service to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
        }
        #expect(menu.actionCount == 0)
    }

    @Test
    @MainActor
    func `attested menu cancellation retains typed zero dispatch semantics`() async throws {
        let cancellation = DesktopActionFailure.preDispatchRefusal(
            reason: .requestCancelled,
            message: "Cancelled before AXPress")
        let menu = try ResultMenuService(failure: cancellation)
        let server = Self.server(services: ServiceActionResultServices(menu: menu))

        do {
            _ = try await Self.handleCurrent(
                .clickMenuItem(.init(
                    appIdentifier: "PID:701",
                    itemPath: "File > New",
                    expectedIdentity: .init(processIdentifier: 701, processStartIdentity: 9001))),
                with: server)
            Issue.record("Expected typed menu cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure == cancellation)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        #expect(menu.actionCount == 1)
    }

    @Test
    @MainActor
    func `unattested menu mutation dispatches through the legacy service`() async throws {
        let menu = LegacyMenuService()
        let server = Self.server(services: ServiceActionResultServices(menu: menu))

        let handled = try await server.handleAuthorized(
            .clickMenuItem(.init(appIdentifier: "Fixture", itemPath: "File > New")),
            peer: nil,
            permissions: Self.permissions)

        guard case .ok = handled.response else {
            Issue.record("Expected the legacy menu response")
            return
        }
        #expect(handled.mutation == nil)
        #expect(menu.actionCount == 1)
    }

    @Test
    @MainActor
    func `attested automation refuses before dispatch without an outcome provider`() async throws {
        let automation = StubNonTargetedAutomationService()
        let server = Self.server(services: ServiceActionResultServices(automation: automation))
        let request = PeekabooBridgeRequest.click(.init(target: .elementId("B1"), clickType: .single))

        do {
            _ = try await Self.handleCurrent(request, with: server)
            Issue.record("Expected receipt-incapable automation to fail closed")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.retrySafety == .safe)
        }
        #expect(automation.actionCount == 0)

        _ = try await server.handleAuthorized(request, peer: nil, permissions: Self.permissions)
        #expect(automation.actionCount == 1)
    }

    @Test
    @MainActor
    func `Dock item mutations target the exact Dock generation and visibility stays global`() async throws {
        let dock = try ResultDockService()
        let server = Self.server(services: ServiceActionResultServices(dock: dock))

        for request in [
            PeekabooBridgeRequest.launchDockItem(.init(appName: "Safari")),
            .rightClickDockItem(.init(appName: "Safari", menuItem: "Options")),
        ] {
            let handled = try await Self.handleCurrent(request, with: server)
            Self.expectHandlerTarget(handled, processIdentifier: 702, processStartIdentity: 9002)
            #expect(handled.outcome == dock.itemOutcome)
        }

        let hide = try await Self.handleCurrent(.hideDock, with: server)
        Self.expectGlobalTarget(hide)
        #expect(hide.outcome == dock.visibilityOutcome)

        let show = try await Self.handleCurrent(.showDock, with: server)
        Self.expectGlobalTarget(show)
        #expect(show.outcome == dock.visibilityOutcome)
    }

    @Test
    @MainActor
    func `Dock item mutation refuses before dispatch when service cannot name Dock`() async throws {
        let dock = LegacyDockService()
        let server = Self.server(services: ServiceActionResultServices(dock: dock))

        do {
            _ = try await Self.handleCurrent(
                .launchDockItem(.init(appName: "Safari")),
                with: server)
            Issue.record("Expected an owner-less Dock service to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
        }
        #expect(dock.actionCount == 0)
        for request in [PeekabooBridgeRequest.hideDock, .showDock] {
            do {
                _ = try await Self.handleCurrent(request, with: server)
                Issue.record("Expected receipt-incapable Dock visibility to refuse")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.refusalReason == .runtimeIncompatible)
                #expect(failure.outcome.dispatchState == .none)
            }
        }
        #expect(dock.visibilityActionCount == 0)
    }

    @Test
    @MainActor
    func `unattested Dock mutations dispatch through the legacy service`() async throws {
        let dock = LegacyDockService()
        let server = Self.server(services: ServiceActionResultServices(dock: dock))

        for request in [
            PeekabooBridgeRequest.launchDockItem(.init(appName: "Safari")),
            .hideDock,
            .showDock,
        ] {
            let handled = try await server.handleAuthorized(
                request,
                peer: nil,
                permissions: Self.permissions)
            guard case .ok = handled.response else {
                Issue.record("Expected a legacy Dock response for \(request.operation.rawValue)")
                continue
            }
            #expect(handled.mutation == nil)
        }
        #expect(dock.actionCount == 1)
        #expect(dock.visibilityActionCount == 2)
    }

    @Test
    @MainActor
    func `unattested legacy dialog actions preserve outcome-less responses`() async throws {
        let dialogs = NilOutcomeDialogService()
        let server = Self.server(services: ServiceActionResultServices(dialogs: dialogs))
        let requests = Self.legacyDialogRequests

        for request in requests {
            let handled = try await server.handleAuthorized(
                request,
                peer: nil,
                permissions: Self.permissions)
            guard case let .dialogResult(result) = handled.response else {
                Issue.record("Expected the legacy dialog response for \(request.operation.rawValue)")
                continue
            }
            #expect(result.success)
            #expect(result.outcome == nil)
            #expect(handled.mutation == nil)
        }
        #expect(dialogs.actions == requests.map(\.operation))
    }

    @Test
    @MainActor
    func `attested legacy dialog actions refuse before provider dispatch`() async throws {
        let dialogs = NilOutcomeDialogService()
        let server = Self.server(services: ServiceActionResultServices(dialogs: dialogs))
        let requests = Self.legacyDialogRequests

        for request in requests {
            do {
                _ = try await Self.handleCurrent(request, with: server)
                Issue.record("Expected \(request.operation.rawValue) to fail closed")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.dispatchState == .none)
                #expect(failure.outcome.refusalReason == .operationUnsupported)
                #expect(failure.outcome.retrySafety == .safe)
            } catch {
                Issue.record("Unexpected \(request.operation.rawValue) error: \(error)")
            }
        }
        #expect(dialogs.actions.isEmpty)
    }

    @MainActor
    private static func server(services: any PeekabooBridgeServiceProviding) -> PeekabooBridgeServer {
        PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            hostIdentity: nil,
            permissionStatusEvaluator: { _ in Self.permissions })
    }

    @MainActor
    private static func handleCurrent(
        _ request: PeekabooBridgeRequest,
        with server: PeekabooBridgeServer) async throws -> PeekabooBridgeHandledResponse
    {
        try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try await server.handleAuthorized(request, peer: nil, permissions: Self.permissions)
        }
    }

    @MainActor
    private static func expectTargetlessRefusal(
        _ request: PeekabooBridgeRequest,
        with server: PeekabooBridgeServer,
        equals expected: DesktopActionOutcome) async
    {
        do {
            _ = try await self.handleCurrent(request, with: server)
            Issue.record("Expected \(request.operation.rawValue) to preserve its refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == expected, "Wrong refusal for \(request.operation.rawValue)")
        } catch {
            Issue.record("Unexpected \(request.operation.rawValue) error: \(error)")
        }
    }

    @MainActor
    private static func expectIndeterminateMissingOutcome(
        _ request: PeekabooBridgeRequest,
        with server: PeekabooBridgeServer) async
    {
        do {
            _ = try await self.handleCurrent(request, with: server)
            Issue.record("Expected \(request.operation.rawValue) to reject a missing canonical outcome")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: nil))
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private static let legacyDialogRequests: [PeekabooBridgeRequest] = [
        .dialogClickButton(.init(buttonText: "OK", windowTitle: nil, appName: "Fixture")),
        .backgroundDialogClickButton(.init(buttonText: "Cancel", windowTitle: nil, appName: "Fixture")),
        .dialogEnterText(.init(
            text: "hello",
            fieldIdentifier: nil,
            clearExisting: false,
            windowTitle: nil,
            appName: "Fixture",
            focus: nil)),
        .dialogHandleFile(.init(
            path: "/tmp",
            filename: "fixture.txt",
            actionButton: nil,
            ensureExpanded: false,
            appName: "Fixture")),
        .dialogDismiss(.init(force: false, windowTitle: nil, appName: "Fixture")),
        .dialogDismiss(.init(force: true, windowTitle: nil, appName: "Fixture")),
    ]

    private static func expectHandlerTarget(
        _ handled: PeekabooBridgeHandledResponse,
        processIdentifier: Int32,
        processStartIdentity: UInt64)
    {
        guard case let .handlerResolved(target) = handled.mutation?.target else {
            Issue.record("Expected a handler-resolved mutation target")
            return
        }
        #expect(target.processIdentity.processIdentifier == processIdentifier)
        #expect(target.processIdentity.processStartIdentity == processStartIdentity)
    }

    private static func expectGlobalTarget(_ handled: PeekabooBridgeHandledResponse) {
        guard case .global = handled.mutation?.target else {
            Issue.record("Expected a global mutation target")
            return
        }
    }

    private static let permissions = PermissionsStatus(
        screenRecording: true,
        accessibility: true,
        postEvent: true)
}

@MainActor
private final class ServiceActionResultServices: PeekabooBridgeServiceProviding {
    private let base: StubServices
    private let dialogService: any DialogServiceProtocol
    let menu: any MenuServiceProtocol
    let dock: any DockServiceProtocol

    var permissions: PermissionsService {
        self.base.permissions
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        self.base.screenCapture
    }

    var automation: any UIAutomationServiceProtocol {
        self.base.automation
    }

    var windows: any WindowManagementServiceProtocol {
        self.base.windows
    }

    var applications: any ApplicationServiceProtocol {
        self.base.applications
    }

    var dialogs: any DialogServiceProtocol {
        self.dialogService
    }

    var snapshots: any SnapshotManagerProtocol {
        self.base.snapshots
    }

    var desktopObservation: any DesktopObservationServiceProtocol {
        self.base.desktopObservation
    }

    init(
        applications: any ApplicationServiceProtocol = StubApplicationService(),
        automation: (any UIAutomationServiceProtocol)? = nil,
        menu: (any MenuServiceProtocol)? = nil,
        dock: (any DockServiceProtocol)? = nil,
        dialogs: (any DialogServiceProtocol)? = nil)
    {
        self.base = StubServices(applications: applications, automation: automation)
        self.menu = menu ?? LegacyMenuService()
        self.dock = dock ?? LegacyDockService()
        self.dialogService = dialogs ?? self.base.dialogs
    }
}

@MainActor
private final class ResultMenuService: MenuServiceGenerationPinnedActionResultProviding,
    MenuServiceExactLeafActionResultProviding
{
    let outcome: DesktopActionOutcome
    private let suppliedOutcome: DesktopActionOutcome?
    private let reportsOutcome: Bool
    private let target: DesktopTargetIdentity?
    private let failure: DesktopActionFailure?
    private(set) var actionCount = 0
    private(set) var pinnedDeliveryModes: [DesktopActionOutcome.Delivery.Mode] = []

    init(
        outcome: DesktopActionOutcome? = nil,
        includesTarget: Bool = true,
        reportsOutcome: Bool = true,
        failure: DesktopActionFailure? = nil) throws
    {
        self.suppliedOutcome = outcome
        self.outcome = outcome ?? Self.defaultOutcome(mode: .foreground)
        self.reportsOutcome = reportsOutcome
        self.target = if includesTarget {
            try DesktopTargetIdentity(processIdentity: .init(
                processIdentifier: 701,
                processStartIdentity: 9001))
        } else {
            nil
        }
        self.failure = failure
    }

    func clickMenuItemActionResult(app _: String, itemPath _: String) async throws
        -> UIAutomationActionResult<Void>
    {
        try self.recordAction()
        return .init(payload: (), outcome: self.reportedOutcome(mode: .background), targetIdentity: self.target)
    }

    func clickMenuItemByNameActionResult(app _: String, itemName _: String) async throws
        -> UIAutomationActionResult<Void>
    {
        try self.recordAction()
        return .init(payload: (), outcome: self.reportedOutcome(mode: .background), targetIdentity: self.target)
    }

    func clickMenuItemActionResult(request: MenuItemActionRequest) async throws
        -> UIAutomationActionResult<Void>
    {
        try self.recordAction()
        self.pinnedDeliveryModes.append(request.deliveryMode)
        return .init(
            payload: (),
            outcome: self.reportedOutcome(mode: request.deliveryMode),
            targetIdentity: self.target)
    }

    func clickMenuItemByNameActionResult(request: MenuItemByNameActionRequest) async throws
        -> UIAutomationActionResult<Void>
    {
        try self.recordAction()
        self.pinnedDeliveryModes.append(request.deliveryMode)
        return .init(
            payload: (),
            outcome: self.reportedOutcome(mode: request.deliveryMode),
            targetIdentity: self.target)
    }

    func clickMenuExtraActionResult(title: String) async throws -> UIAutomationActionResult<Void> {
        try self.recordAction()
        return try .init(
            payload: (),
            outcome: self.reportedOutcome(mode: .foreground),
            targetIdentity: self.target,
            selectedLeafEvidence: [fixtureMenuLeaf(selector: title, matchKind: .exact)])
    }

    func clickMenuBarItemActionResult(named name: String) async throws -> UIAutomationActionResult<ClickResult> {
        try self.recordAction()
        return try .init(
            payload: .init(elementDescription: name, location: nil),
            outcome: self.reportedOutcome(mode: .foreground),
            targetIdentity: self.target,
            selectedLeafEvidence: [fixtureMenuLeaf(selector: name, matchKind: .exact)])
    }

    func clickMenuBarItemActionResult(at index: Int) async throws -> UIAutomationActionResult<ClickResult> {
        try self.recordAction()
        return try .init(
            payload: .init(elementDescription: "\(index)", location: nil),
            outcome: self.reportedOutcome(mode: .foreground),
            targetIdentity: self.target,
            selectedLeafEvidence: [fixtureMenuLeaf(selector: String(index), matchKind: .index, index: index)])
    }

    func clickMenuBarItemActionResult(request: MenuBarItemActionRequest) async throws
        -> UIAutomationActionResult<ClickResult>
    {
        if let name = request.name {
            return try await self.clickMenuBarItemActionResult(named: name)
        }
        return try await self.clickMenuBarItemActionResult(at: request.index ?? 0)
    }

    func applicationMenuOutcome(
        mode: DesktopActionOutcome.Delivery.Mode = .background) -> DesktopActionOutcome
    {
        self.suppliedOutcome ?? Self.defaultOutcome(mode: mode)
    }

    private func reportedOutcome(
        mode: DesktopActionOutcome.Delivery.Mode) -> DesktopActionOutcome?
    {
        self.reportsOutcome ? self.applicationMenuOutcome(mode: mode) : nil
    }

    private static func defaultOutcome(
        mode: DesktopActionOutcome.Delivery.Mode) -> DesktopActionOutcome
    {
        .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: mode),
            evidence: .deliveryAccepted,
            unitCount: .one)
    }

    private func recordAction() throws {
        self.actionCount += 1
        if let failure = self.failure {
            throw failure
        }
    }

    func listMenus(for _: String) async throws -> MenuStructure {
        throw PeekabooError.notImplemented("test")
    }

    func listFrontmostMenus() async throws -> MenuStructure {
        throw PeekabooError.notImplemented("test")
    }

    func clickMenuItem(app _: String, itemPath _: String) async throws {}
    func clickMenuItemByName(app _: String, itemName _: String) async throws {}
    func clickMenuExtra(title _: String) async throws {}
    func isMenuExtraMenuOpen(title _: String, ownerPID _: pid_t?) async throws -> Bool {
        false
    }

    func menuExtraOpenMenuFrame(title _: String, ownerPID _: pid_t?) async throws -> CGRect? {
        nil
    }

    func listMenuExtras() async throws -> [MenuExtraInfo] {
        []
    }

    func listMenuBarItems(includeRaw _: Bool) async throws -> [MenuBarItemInfo] {
        []
    }

    func clickMenuBarItem(named name: String) async throws -> ClickResult {
        try await self.clickMenuBarItemActionResult(named: name).payload
    }

    func clickMenuBarItem(at index: Int) async throws -> ClickResult {
        try await self.clickMenuBarItemActionResult(at: index).payload
    }
}

@MainActor
private final class LegacyMenuService: MenuServiceProtocol {
    private(set) var actionCount = 0
    func listMenus(for _: String) async throws -> MenuStructure {
        throw PeekabooError.notImplemented("test")
    }

    func listFrontmostMenus() async throws -> MenuStructure {
        throw PeekabooError.notImplemented("test")
    }

    func clickMenuItem(app _: String, itemPath _: String) async throws {
        self.actionCount += 1
    }

    func clickMenuItemByName(app _: String, itemName _: String) async throws {
        self.actionCount += 1
    }

    func clickMenuExtra(title _: String) async throws {
        self.actionCount += 1
    }

    func isMenuExtraMenuOpen(title _: String, ownerPID _: pid_t?) async throws -> Bool {
        false
    }

    func menuExtraOpenMenuFrame(title _: String, ownerPID _: pid_t?) async throws -> CGRect? {
        nil
    }

    func listMenuExtras() async throws -> [MenuExtraInfo] {
        []
    }

    func listMenuBarItems(includeRaw _: Bool) async throws -> [MenuBarItemInfo] {
        []
    }

    func clickMenuBarItem(named _: String) async throws -> ClickResult {
        self.actionCount += 1
        return .init(elementDescription: "test", location: nil)
    }

    func clickMenuBarItem(at _: Int) async throws -> ClickResult {
        self.actionCount += 1
        return .init(elementDescription: "test", location: nil)
    }
}

@MainActor
private final class ResultDockService: DockServiceActionResultProviding {
    let itemOutcome: DesktopActionOutcome
    let visibilityOutcome = DesktopActionOutcome.confirmedChange(
        delivery: .init(mechanism: .nativeFramework, mode: .background),
        unitCount: DesktopActionOutcome.DispatchUnitCount(2))
    private let target: DesktopTargetIdentity?
    private let reportedItemOutcome: DesktopActionOutcome?
    private let reportedVisibilityOutcome: DesktopActionOutcome?
    private(set) var itemActionCount = 0
    private(set) var visibilityActionCount = 0

    init(
        itemOutcome: DesktopActionOutcome? = nil,
        includesTarget: Bool = true,
        reportsOutcome: Bool = true) throws
    {
        self.itemOutcome = itemOutcome ?? .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        self.target = if includesTarget {
            try DesktopTargetIdentity(processIdentity: .init(
                processIdentifier: 702,
                processStartIdentity: 9002))
        } else {
            nil
        }
        self.reportedItemOutcome = reportsOutcome ? self.itemOutcome : nil
        self.reportedVisibilityOutcome = reportsOutcome ? self.visibilityOutcome : nil
    }

    func launchFromDockActionResult(appName: String) async throws -> UIAutomationActionResult<Void> {
        self.itemActionCount += 1
        return try .init(
            payload: (),
            outcome: self.reportedItemOutcome,
            targetIdentity: self.target,
            selectedLeafEvidence: fixtureDockLeaves(appName: appName))
    }

    func rightClickDockItemActionResult(appName: String, menuItem: String?) async throws
        -> UIAutomationActionResult<Void>
    {
        self.itemActionCount += 1
        return try .init(
            payload: (),
            outcome: self.reportedItemOutcome,
            targetIdentity: self.target,
            selectedLeafEvidence: fixtureDockLeaves(appName: appName, menuItem: menuItem))
    }

    func hideDockActionResult() async throws -> DesktopActionResult<Void> {
        self.visibilityActionCount += 1
        return .init(outcome: self.reportedVisibilityOutcome)
    }

    func showDockActionResult() async throws -> DesktopActionResult<Void> {
        self.visibilityActionCount += 1
        return .init(outcome: self.reportedVisibilityOutcome)
    }

    func launchFromDock(appName _: String) async throws {}
    func addToDock(path _: String, persistent _: Bool) async throws {}
    func removeFromDock(appName _: String) async throws {}
    func rightClickDockItem(appName _: String, menuItem _: String?) async throws {}
    func hideDock() async throws {}
    func showDock() async throws {}
    func isDockAutoHidden() async -> Bool {
        false
    }

    func listDockItems(includeAll _: Bool) async throws -> [DockItem] {
        []
    }

    func findDockItem(name _: String) async throws -> DockItem {
        throw PeekabooError.notImplemented("test")
    }
}

@MainActor
private final class LegacyDockService: DockServiceProtocol {
    private(set) var actionCount = 0
    private(set) var visibilityActionCount = 0
    func launchFromDock(appName _: String) async throws {
        self.actionCount += 1
    }

    func addToDock(path _: String, persistent _: Bool) async throws {}
    func removeFromDock(appName _: String) async throws {}
    func rightClickDockItem(appName _: String, menuItem _: String?) async throws {
        self.actionCount += 1
    }

    func hideDock() async throws {
        self.visibilityActionCount += 1
    }

    func showDock() async throws {
        self.visibilityActionCount += 1
    }

    func isDockAutoHidden() async -> Bool {
        false
    }

    func listDockItems(includeAll _: Bool) async throws -> [DockItem] {
        []
    }

    func findDockItem(name _: String) async throws -> DockItem {
        throw PeekabooError.notImplemented("test")
    }
}

@MainActor
private final class SafeNoOpRefusingApplicationService: StubApplicationService {
    override var supportsSafeBackgroundApplicationLaunchNoOp: Bool {
        true
    }
}

@MainActor
private final class LegacyApplicationService: ApplicationServiceProtocol {
    let supportsApplicationLaunchOptions = true
    let supportsApplicationRelaunch = true
    let supportsSafeBackgroundApplicationLaunchNoOp = true
    let supportsProcessGenerationPinnedApplicationQuit = true
    let supportsProcessGenerationPinnedApplicationActivation = true

    private let app = ServiceApplicationInfo(
        processIdentifier: 123,
        processStartIdentity: 456,
        bundleIdentifier: "dev.legacy",
        name: "StubApp",
        isHiddenKnown: true,
        windowCount: 1,
        activationPolicy: .regular)

    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        UnifiedToolOutput(
            data: .init(applications: [self.app]),
            summary: .init(brief: "1 app", status: .success, counts: ["applications": 1]),
            metadata: .init(duration: 0))
    }

    func findApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        self.app
    }

    func listWindows(for _: String, timeout _: Float?) async throws -> UnifiedToolOutput<ServiceWindowListData> {
        UnifiedToolOutput(
            data: .init(windows: [], targetApplication: self.app),
            summary: .init(brief: "0 windows", status: .success, counts: ["windows": 0]),
            metadata: .init(duration: 0))
    }

    func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        self.app
    }

    func isApplicationRunning(identifier _: String) async -> Bool {
        true
    }

    func launchApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        self.app
    }

    func launchApplication(request _: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo {
        self.app
    }

    func relaunchApplication(request _: ApplicationRelaunchRequest) async throws -> ServiceApplicationInfo {
        self.app
    }

    func activateApplication(identifier _: String) async throws {}
    func activateApplication(request _: ApplicationActivationRequest) async throws {}
    func quitApplication(identifier _: String, force _: Bool) async throws -> Bool {
        true
    }

    func quitApplication(request _: ApplicationQuitRequest) async throws -> Bool {
        true
    }

    func hideApplication(identifier _: String) async throws {}
    func unhideApplication(identifier _: String) async throws {}
    func hideOtherApplications(identifier _: String) async throws {}
    func showAllApplications() async throws {}
}

@MainActor
private final class TargetlessRefusalApplicationService: StubApplicationService {
    let refusal = DesktopActionOutcome.refused(reason: .targetUnavailable)

    override func activateApplicationTargetedActionResult(
        request _: ApplicationActivationRequest) async throws -> UIAutomationActionResult<Void>
    {
        .init(payload: (), outcome: self.refusal, targetIdentity: nil)
    }

    override func hideApplicationTargetedActionResult(identifier _: String) async throws
        -> UIAutomationActionResult<Void>
    {
        .init(payload: (), outcome: self.refusal, targetIdentity: nil)
    }

    override func hideApplicationTargetedActionResult(
        request _: ApplicationHideRequest) async throws -> UIAutomationActionResult<Void>
    {
        .init(payload: (), outcome: self.refusal, targetIdentity: nil)
    }
}

@MainActor
private final class NilOutcomeDialogService: DialogServiceProtocol {
    private(set) var actions: [PeekabooBridgeOperation] = []

    func findActiveDialog(windowTitle _: String?, appName _: String?) async throws -> DialogInfo {
        throw PeekabooError.notImplemented("test")
    }

    func clickButton(
        buttonText _: String,
        windowTitle _: String?,
        appName _: String?) async throws -> DialogActionResult
    {
        try await self.clickButton(
            buttonText: "ignored",
            windowTitle: nil,
            appName: nil,
            allowGlobalFallback: true)
    }

    func clickButton(
        buttonText _: String,
        windowTitle _: String?,
        appName _: String?,
        allowGlobalFallback: Bool) async throws -> DialogActionResult
    {
        self.actions.append(allowGlobalFallback ? .dialogClickButton : .backgroundDialogClickButton)
        return .init(success: true, action: .clickButton)
    }

    func enterText(
        text _: String,
        fieldIdentifier _: String?,
        clearExisting _: Bool,
        windowTitle _: String?,
        appName _: String?) async throws -> DialogActionResult
    {
        self.actions.append(.dialogEnterText)
        return .init(success: true, action: .enterText)
    }

    func handleFileDialog(
        path _: String?,
        filename _: String?,
        actionButton _: String?,
        ensureExpanded _: Bool,
        appName _: String?) async throws -> DialogActionResult
    {
        self.actions.append(.dialogHandleFile)
        return .init(success: true, action: .handleFileDialog)
    }

    func dismissDialog(
        force _: Bool,
        windowTitle _: String?,
        appName _: String?) async throws -> DialogActionResult
    {
        self.actions.append(.dialogDismiss)
        return .init(success: true, action: .dismiss)
    }

    func listDialogElements(windowTitle _: String?, appName _: String?) async throws -> DialogElements {
        throw PeekabooError.notImplemented("test")
    }
}
