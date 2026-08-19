import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooBridgeTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

struct PeekabooBridgeActionOutcomeProjectionTests {
    @Test
    @MainActor
    func `receiptless activation projects successful outcomes and rejects every non-success state`() async throws {
        let applications = StubApplicationService()
        let server = PeekabooBridgeServer(
            services: StubServices(applications: applications),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            hostIdentity: nil,
            postEventAccessEvaluator: { false },
            postEventAccessRequester: { false },
            permissionStatusEvaluator: { _ in Self.grantedPermissions })
        let request = PeekabooBridgeRequest.activateApplication(.init(identifier: "StubApp"))
        let delivery = DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: .foreground)
        let outcomes: [DesktopActionOutcome] = [
            .confirmedChange(delivery: delivery, unitCount: .one),
            .confirmedNoChange(),
            .dispatchedUnverified(delivery: delivery, evidence: .deliveryAccepted, unitCount: .one),
            .refused(reason: .targetUnavailable),
            .partial(delivery: delivery, unitCount: .one),
            .suspectedNoop(delivery: delivery, unitCount: .one),
            .indeterminate(delivery: delivery, evidence: .completionUnknown, unitCount: .one),
        ]

        for expected in outcomes {
            applications.actionOutcome = expected
            let response = try await Self.send(.projectedAction(.init(request: request)), to: server)
            guard case let .projectedAction(projected) = response else {
                Issue.record("Expected projected application response")
                continue
            }
            let projectedOutcome = expected.routed(to: .bridge).projection
            switch expected.state {
            case .confirmedChange, .confirmedNoChange, .dispatchedUnverified:
                guard case .ok = projected.response else {
                    Issue.record("Expected successful activation response for \(expected.state.rawValue)")
                    continue
                }
                #expect(projected.outcome == projectedOutcome)
            case .refused, .partial, .suspectedNoop, .indeterminate:
                guard case let .error(envelope) = projected.response else {
                    Issue.record("Expected activation error for \(expected.state.rawValue)")
                    continue
                }
                #expect(projected.outcome == projectedOutcome)
                #expect(envelope.actionOutcome == projectedOutcome)
            }
        }
    }

    @Test
    @MainActor
    func `quit rejection preserves false legacy payload and projected refusal`() async throws {
        let applications = StubApplicationService()
        let refusal = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "The native quit request was rejected.",
            hint: "Refresh the application inventory before retrying.")
        applications.quitResultError = refusal
        let server = PeekabooBridgeServer(
            services: StubServices(applications: applications),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            hostIdentity: nil,
            permissionStatusEvaluator: { _ in Self.grantedPermissions })

        let handled = try await server.handleAuthorized(
            Self.quitRequest,
            peer: nil,
            permissions: Self.grantedPermissions)
        guard case let .bool(handledSucceeded) = handled.response else {
            Issue.record("Expected a handled bool response")
            return
        }
        #expect(!handledSucceeded)
        #expect(handled.outcome == refusal.outcome)

        let legacyResponse = try await Self.send(Self.quitRequest, to: server)
        guard case let .bool(legacySucceeded) = legacyResponse else {
            Issue.record("Expected a bare legacy bool response")
            return
        }
        #expect(!legacySucceeded)

        let projectedResponse = try await Self.send(
            .projectedAction(.init(request: Self.quitRequest)),
            to: server)
        guard case let .projectedAction(projected) = projectedResponse,
              case let .bool(projectedSucceeded) = projected.response
        else {
            Issue.record("Expected a projected bool response")
            return
        }
        #expect(!projectedSucceeded)
        #expect(projected.outcome == refusal.outcome.routed(to: .bridge).projection)
        #expect(projected.outcome?.state == .refused)
        #expect(projected.outcome?.refusalReason == .targetUnavailable)
        #expect(projected.outcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
    }

    @Test
    @MainActor
    func `quit compatibility does not swallow drift or unsafe failures`() async throws {
        let applications = StubApplicationService()
        let server = PeekabooBridgeServer(
            services: StubServices(applications: applications),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            hostIdentity: nil,
            permissionStatusEvaluator: { _ in Self.grantedPermissions })

        applications.quitResultError = PeekabooError.commandFailed(
            "Application PID changed process generation")
        let driftResponse = try await Self.send(Self.quitRequest, to: server)
        guard case .error = driftResponse else {
            Issue.record("Expected process-generation drift to remain an error")
            return
        }

        let unsafeFailure = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "The quit request may have been dispatched.",
            hint: "Observe the target before retrying.")
            .attributed(to: DesktopActionTargetReceipt(
                processIdentifier: 123,
                processStartIdentity: 456))
        applications.quitResultError = unsafeFailure
        let projectedQuitRequest = PeekabooBridgeRequest.projectedAction(.init(request: Self.quitRequest))
        let unsafeData = try await Self.sendRaw(projectedQuitRequest, to: server, peer: nil)
        let unsafeResponse = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: unsafeData)
        guard case let .projectedAction(projected) = unsafeResponse,
              case let .error(envelope) = projected.response
        else {
            Issue.record("Expected unsafe quit failure to remain an error")
            return
        }
        #expect(projected.outcome == unsafeFailure.outcome.routed(to: .bridge).projection)
        #expect(envelope.operationMayHaveCompleted)
        #expect(envelope.actionOutcome == projected.outcome)
        #expect(envelope.actionTargetReceipt == nil)

        let legacy = try JSONDecoder.peekabooBridgeDecoder().decode(
            LegacyProtocol128BridgeResponse.self,
            from: unsafeData)
        guard case let .projectedAction(legacyProjected) = legacy,
              case let .error(legacyEnvelope) = legacyProjected.response
        else {
            Issue.record("Expected protocol 1.28 to decode the projected quit failure")
            return
        }
        #expect(legacyProjected.outcome?.state == "indeterminate")
        #expect(legacyProjected.outcome?.mutationDispatched == true)
        #expect(legacyProjected.outcome?.retrySafe == false)
        #expect(legacyEnvelope.operationMayHaveCompleted == true)
        #expect(legacyEnvelope.actionOutcome == legacyProjected.outcome)
        #expect(legacyEnvelope.actionTargetReceipt == nil)

        let currentEnvelope = PeekabooBridgeErrorEnvelope(
            code: .internalError,
            actionFailure: unsafeFailure.routed(to: .bridge))
        let currentResponse = PeekabooBridgeResponse.projectedActionForCurrentRequestVocabulary(
            response: .error(currentEnvelope),
            outcome: currentEnvelope.actionOutcome,
            usesCurrentVocabulary: true)
        guard case let .projectedAction(currentProjected) = currentResponse,
              case let .error(preservedEnvelope) = currentProjected.response
        else {
            Issue.record("Expected protocol 1.29 projected quit failure")
            return
        }
        #expect(preservedEnvelope.actionTargetReceipt == unsafeFailure.targetReceipt)
        #expect(preservedEnvelope.actionOutcome == currentProjected.outcome)
    }

    @Test
    @MainActor
    func `current server preserves legacy shape and honors projected opt in`() async throws {
        let server = PeekabooBridgeServer(
            services: StubServices(),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            hostIdentity: nil,
            postEventAccessEvaluator: { false },
            postEventAccessRequester: { true },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: false,
                    postEvent: false)
            })

        let legacyResponse = try await Self.send(.requestPostEventPermission, to: server)
        guard case let .bool(granted) = legacyResponse else {
            Issue.record("Expected a bare legacy bool response")
            return
        }
        #expect(granted)

        let projectedResponse = try await Self.send(
            .projectedAction(.init(request: .requestPostEventPermission)),
            to: server)
        guard case let .projectedAction(projectedPayload) = projectedResponse else {
            Issue.record("Expected an explicitly projected response")
            return
        }
        guard case let .bool(projectedGranted) = projectedPayload.response else {
            Issue.record("Expected the legacy bool response inside projected carriage")
            return
        }
        #expect(projectedGranted)
        #expect(projectedPayload.outcome?.state == .dispatchedUnverified)
        #expect(projectedPayload.outcome?.outcome.delivery == .init(
            mechanism: .nativeFramework,
            mode: .foreground))
        #expect(projectedPayload.outcome?.outcome.dispatchState == .dispatched(unitCount: .one))

        let handshakeResponse = try await Self.send(.handshake(.init(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            client: .init(
                bundleIdentifier: "dev.peekaboo.tests",
                teamIdentifier: nil,
                processIdentifier: 42,
                hostname: nil),
            requestedHostKind: .onDemand)), to: server)
        guard case let .handshake(handshake) = handshakeResponse else {
            Issue.record("Expected a current handshake response")
            return
        }
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.desktopActionOutcomeProjection) == true)
    }

    @Test
    func `client wraps mutations only after current capability negotiation`() async throws {
        let currentHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.desktopActionOutcomeProjectionVersion,
            supportedOperations: [.click],
            hostCapabilities: [PeekabooBridgeHostCapability.desktopActionOutcomeProjection])
        let currentPeer = try ScriptedBridgePeer(responses: [
            .handshake(currentHandshake),
            .projectedAction(.init(response: .ok, outcome: nil)),
        ])
        let currentClient = PeekabooBridgeClient(socketPath: currentPeer.socketPath, requestTimeoutSec: 1)

        _ = try await currentClient.handshake(client: Self.clientIdentity)
        try await currentClient.sendExpectOK(Self.clickRequest)
        let currentRequests = await currentPeer.requests
        #expect(currentRequests.count == 2)
        let currentAction = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeRequest.self,
            from: currentRequests[1])
        guard case let .projectedAction(payload) = currentAction,
              case .click = payload.request
        else {
            Issue.record("Expected a projected click after current capability negotiation")
            await currentPeer.waitUntilFinished()
            return
        }
        await currentPeer.waitUntilFinished()

        let previousHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 22),
            supportedOperations: [.click],
            hostCapabilities: [PeekabooBridgeHostCapability.desktopActionOutcomeProjection])
        let previousPeer = try ScriptedBridgePeer(responses: [
            .handshake(previousHandshake),
            .ok,
        ])
        let previousClient = PeekabooBridgeClient(socketPath: previousPeer.socketPath, requestTimeoutSec: 1)

        _ = try await previousClient.handshake(client: Self.clientIdentity)
        try await previousClient.sendExpectOK(Self.clickRequest)
        let previousRequests = await previousPeer.requests
        #expect(previousRequests.count == 2)
        let previousAction = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeRequest.self,
            from: previousRequests[1])
        guard case .click = previousAction else {
            Issue.record("Expected legacy click carriage for a previous protocol host")
            await previousPeer.waitUntilFinished()
            return
        }
        await previousPeer.waitUntilFinished()
    }

    @Test
    func `capable client treats a missing projected response as lost`() async throws {
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.desktopActionOutcomeProjectionVersion,
            supportedOperations: [.click],
            hostCapabilities: [PeekabooBridgeHostCapability.desktopActionOutcomeProjection])
        let peer = try ScriptedBridgePeer(responses: [.handshake(handshake), .ok])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)

        _ = try await client.handshake(client: Self.clientIdentity)
        do {
            try await client.sendExpectOK(Self.clickRequest)
            Issue.record("Expected unwrapped capable-host response to fail closed")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .responseLost)
            #expect(failure.outcome.projection.requiresFreshObservation)
            #expect(!failure.outcome.projection.retrySafe)
        }
        await peer.waitUntilFinished()
    }

    @Test
    @MainActor
    func `current server projects action failures only for opted in requests`() async throws {
        let services = StubServices()
        let unitCount = try #require(DesktopActionOutcome.DispatchUnitCount(2))
        let failure = DesktopActionFailure.partial(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            unitCount: unitCount,
            message: "Primary click changed state but cleanup failed",
            hint: "Recover the remaining side effect before another click.",
            causeDescription: "cleanup receipt was unavailable")
        services.automationStub.clickError = failure
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            hostIdentity: nil,
            postEventAccessEvaluator: { true },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    postEvent: true)
            })

        let legacyResponse = try await Self.send(Self.clickRequest, to: server)
        guard case let .error(legacyError) = legacyResponse else {
            Issue.record("Expected a bare legacy error response")
            return
        }
        #expect(legacyError.actionOutcome == nil)
        #expect(legacyError.operationMayHaveCompleted)

        let projectedResponse = try await Self.send(
            .projectedAction(.init(request: Self.clickRequest)),
            to: server)
        guard case let .projectedAction(projectedPayload) = projectedResponse else {
            Issue.record("Expected projected action failure carriage")
            return
        }
        guard case let .error(projectedError) = projectedPayload.response else {
            Issue.record("Expected the legacy error response inside projected carriage")
            return
        }

        let expectedOutcome = failure.routed(to: .bridge).outcome.projection
        #expect(projectedPayload.outcome == expectedOutcome)
        #expect(projectedError.actionOutcome == expectedOutcome)
        #expect(projectedPayload.outcome == projectedError.actionOutcome)
        #expect(projectedError.operationMayHaveCompleted)
        #expect(projectedError.message == failure.message)
        #expect(projectedError.actionFailureHint == failure.hint)
        #expect(projectedError.actionFailureCauseDescription == failure.causeDescription)
    }

    @Test
    @MainActor
    func `current server preserves every successful canonical outcome behind legacy responses`() async throws {
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            hostIdentity: nil,
            permissionStatusEvaluator: { _ in Self.grantedPermissions })

        for outcome in DesktopActionOutcomeFixtures.canonicalOutcomes {
            services.automationStub.actionOutcome = outcome
            let legacy = try await Self.send(Self.clickRequest, to: server)
            guard case .ok = legacy else {
                Issue.record("Expected unchanged legacy click response for \(outcome.state.rawValue)")
                continue
            }

            let projected = try await Self.send(
                .projectedAction(.init(request: Self.clickRequest)),
                to: server)
            guard case let .projectedAction(payload) = projected,
                  case .ok = payload.response
            else {
                Issue.record("Expected projected click response for \(outcome.state.rawValue)")
                continue
            }
            #expect(payload.outcome == outcome.routed(to: .bridge).projection)
        }
    }

    @Test
    @MainActor
    func `all backed automation families retain their native success outcome`() async throws {
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            hostIdentity: nil)
        let expected = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .background))
        services.automationStub.actionOutcome = expected
        let requests: [PeekabooBridgeRequest] = [
            Self.clickRequest,
            .type(.init(
                text: "x",
                target: nil,
                clearExisting: false,
                typingDelay: 0,
                snapshotId: nil)),
            .typeActions(.init(
                actions: [.text("x")],
                cadence: .fixed(milliseconds: 0),
                snapshotId: nil)),
            .scroll(.init(request: .init(
                direction: .down,
                amount: 1,
                foreground: true))),
            .hotkey(.init(keys: "cmd,a", holdDuration: 0)),
            .setValue(.init(target: "B1", value: .string("x"), snapshotId: "snapshot")),
            .performAction(.init(target: "B1", actionName: "AXPress", snapshotId: "snapshot")),
        ]
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 480)
        let exactTarget = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: .init(
                windowID: 73,
                ownerProcessIdentifier: 123,
                ownerProcessStartIdentity: 456,
                capturedBounds: bounds),
            bounds: bounds))

        for request in requests {
            services.automationStub.uiAutomationOutcomeTargetIdentity = switch request.operation {
            case .setValue, .performAction: exactTarget
            default: nil
            }
            let handled = try await server.handleAuthorized(
                request,
                peer: nil,
                permissions: Self.grantedPermissions)
            #expect(handled.outcome == expected, "Missing native outcome for \(request.operation.rawValue)")
        }
    }

    @Test
    func `remote automation preserves current outcomes and legacy absence`() async throws {
        let currentOutcome = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground))
        let currentHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.desktopActionOutcomeProjectionVersion,
            supportedOperations: [.click],
            hostCapabilities: [PeekabooBridgeHostCapability.desktopActionOutcomeProjection])
        let currentPeer = try ScriptedBridgePeer(responses: [
            .handshake(currentHandshake),
            .projectedAction(.init(response: .ok, outcome: currentOutcome.projection)),
        ])
        let currentClient = PeekabooBridgeClient(socketPath: currentPeer.socketPath, requestTimeoutSec: 1)
        _ = try await currentClient.handshake(client: Self.clientIdentity)
        let currentRemote = await MainActor.run { RemoteUIAutomationService(client: currentClient) }
        let currentResult = try await currentRemote.clickWithOutcome(
            target: .coordinates(.zero),
            clickType: .single,
            snapshotId: nil)
        #expect(currentResult.outcome == currentOutcome)
        await currentPeer.waitUntilFinished()

        let previousHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 22),
            supportedOperations: [.click])
        let previousPeer = try ScriptedBridgePeer(responses: [
            .handshake(previousHandshake),
            .ok,
        ])
        let previousClient = PeekabooBridgeClient(socketPath: previousPeer.socketPath, requestTimeoutSec: 1)
        _ = try await previousClient.handshake(client: Self.clientIdentity)
        let previousRemote = await MainActor.run { RemoteUIAutomationService(client: previousClient) }
        let previousResult = try await previousRemote.clickWithOutcome(
            target: .coordinates(.zero),
            clickType: .single,
            snapshotId: nil)
        #expect(previousResult.outcome == nil)
        await previousPeer.waitUntilFinished()
    }

    @Test
    func `remote automation preserves canonical current failures before legacy mapping`() async throws {
        let expected = DesktopActionFailure.partial(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "The target changed but cleanup failed",
            hint: "Recover the remaining side effect.",
            causeDescription: "cleanup receipt was unavailable")
        let envelope = PeekabooBridgeErrorEnvelope(code: .internalError, actionFailure: expected)
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.desktopActionOutcomeProjectionVersion,
            supportedOperations: [.click],
            hostCapabilities: [PeekabooBridgeHostCapability.desktopActionOutcomeProjection])
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(handshake),
            .projectedAction(.init(
                response: .error(envelope),
                outcome: expected.outcome.projection)),
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        _ = try await client.handshake(client: Self.clientIdentity)
        let remote = await MainActor.run { RemoteUIAutomationService(client: client) }

        do {
            _ = try await remote.clickWithOutcome(
                target: .coordinates(.zero),
                clickType: .single,
                snapshotId: nil)
            Issue.record("Expected canonical remote action failure")
        } catch let actual as DesktopActionFailure {
            #expect(actual == expected)
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `remote background launch preserves canonical failure context across client boundary`() async throws {
        let expected = DesktopActionFailure.partial(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one,
            message: "The application launched but readiness verification failed",
            hint: "Observe the application before attempting another launch.",
            causeDescription: "the host could not acquire a readiness receipt")
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: Self.receiptlessProtocolVersion,
            supportedOperations: [.launchApplicationWithOptions],
            hostCapabilities: [
                PeekabooBridgeHostCapability.desktopActionOutcomeProjection,
                PeekabooBridgeHostCapability.safeBackgroundApplicationLaunchNoOp,
            ])
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(handshake),
            BridgeTestFixtures.actionFailureResponse(failure: expected),
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        _ = try await client.handshake(
            client: Self.clientIdentity,
            protocolVersion: Self.receiptlessProtocolVersion)
        let remote = await MainActor.run {
            RemoteApplicationService(
                client: client,
                supportsLaunchOptions: true,
                supportsSafeBackgroundLaunchNoOp: true)
        }

        do {
            _ = try await remote.launchApplicationResult(request: ApplicationLaunchRequest(
                applicationIdentifier: "TextEdit",
                activates: false))
            Issue.record("Expected canonical background-launch failure")
        } catch let actual as DesktopActionFailure {
            #expect(actual == expected)
            #expect(actual.outcome.projection == expected.outcome.projection)
            #expect(actual.hint == expected.hint)
            #expect(actual.causeDescription == expected.causeDescription)
        }
        await peer.waitUntilFinished()
    }

    @Test
    @MainActor
    func `remote automation keeps legacy invalid request mapping`() {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .invalidRequest,
            message: "Legacy host rejected the click")

        let error = RemoteUIAutomationService.automationError(for: envelope, snapshotId: nil)

        guard case let PeekabooError.invalidInput(message) = error else {
            Issue.record("Expected the existing legacy invalid-input mapping")
            return
        }
        #expect(message == "Legacy host rejected the click")
    }

    @Test
    func `projected response round trips every canonical action outcome`() throws {
        let cases = DesktopActionOutcomeFixtures.canonicalCases

        #expect(cases.map(\.state) == [
            .confirmedChange,
            .confirmedNoChange,
            .partial,
            .dispatchedUnverified,
            .suspectedNoop,
            .refused,
            .indeterminate,
        ])

        for expectation in cases {
            let outcome = expectation.outcome
            let response = BridgeTestFixtures.projectedActionResponse(for: outcome)
            let data = try JSONEncoder.peekabooBridgeEncoder().encode(response)
            let projection = try #require(Self.projectedAssociation(from: data)["outcome"] as? [String: Any])
            Self.expectProjection(projection, equals: expectation)
            let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeResponse.self,
                from: data)

            guard case let .projectedAction(payload) = decoded else {
                Issue.record("Expected a projected Bridge response for \(outcome.state.rawValue)")
                continue
            }
            #expect(payload.outcome == outcome.projection)
            Self.expectResponseKind(payload.response, matches: outcome)
        }
    }

    @Test
    func `projected wrappers preserve the legacy payload under one additive wire layer`() throws {
        let legacyRequest = Self.clickRequest
        let projectedRequest = PeekabooBridgeRequest.projectedAction(.init(request: legacyRequest))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(projectedRequest)
        let requestRoot = try Self.object(from: requestData)
        let requestCase = try #require(requestRoot["projectedAction"] as? [String: Any])
        let requestAssociation = try #require(requestCase["_0"] as? [String: Any])
        let requestWrapper = try #require(requestAssociation["request"] as? [String: Any])
        let legacyRequestObject = try Self.object(from: Self.legacyClickRequestData)

        #expect(Set(requestRoot.keys) == ["projectedAction"])
        #expect(Set(requestCase.keys) == ["_0"])
        #expect(Set(requestAssociation.keys) == ["request"])
        #expect(try Self.canonicalJSON(requestWrapper) == Self.canonicalJSON(legacyRequestObject))

        let outcome = DesktopActionOutcomeFixtures.canonicalOutcomes[0]
        let projectedResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .ok,
            outcome: outcome.projection))
        let responseData = try JSONEncoder.peekabooBridgeEncoder().encode(projectedResponse)
        let responseRoot = try Self.object(from: responseData)
        let responseCase = try #require(responseRoot["projectedAction"] as? [String: Any])
        let responseAssociation = try #require(responseCase["_0"] as? [String: Any])

        #expect(Set(responseRoot.keys) == ["projectedAction"])
        #expect(Set(responseCase.keys) == ["_0"])
        #expect(Set(responseAssociation.keys) == ["response", "outcome"])
        #expect((responseAssociation["response"] as? [String: Any])?["ok"] != nil)
        let projection = try #require(responseAssociation["outcome"] as? [String: Any])
        #expect(projection["state"] as? String == "confirmed_change")
        #expect(projection["delivery_mode"] as? String == "background")
        #expect(projection["mutation_dispatched"] as? Bool == true)
    }

    @Test
    func `legacy unwrapped requests and responses remain wire compatible`() throws {
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(Self.clickRequest)
        let requestObject = try Self.object(from: requestData)
        let legacyRequestObject = try Self.object(from: Self.legacyClickRequestData)
        #expect(try Self.canonicalJSON(requestObject) == Self.canonicalJSON(legacyRequestObject))

        let decodedRequest = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeRequest.self,
            from: Self.legacyClickRequestData)
        guard case .click = decodedRequest else {
            Issue.record("Expected the legacy click request to remain unwrapped")
            return
        }

        let legacyResponseData = Data(#"{"ok":{}}"#.utf8)
        let decodedResponse = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: legacyResponseData)
        guard case .ok = decodedResponse else {
            Issue.record("Expected the previous protocol's bare ok response")
            return
        }
        let reencodedResponse = try JSONEncoder.peekabooBridgeEncoder().encode(decodedResponse)
        #expect(try Set(Self.object(from: reencodedResponse).keys) == ["ok"])
    }

    @Test
    func `projected response permits an omitted outcome`() throws {
        let response = PeekabooBridgeResponse.projectedAction(.init(response: .ok, outcome: nil))
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(response)
        let root = try Self.object(from: data)
        let projectedCase = try #require(root["projectedAction"] as? [String: Any])
        let payload = try #require(projectedCase["_0"] as? [String: Any])

        #expect(payload["outcome"] == nil)

        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
        guard case let .projectedAction(decodedPayload) = decoded else {
            Issue.record("Expected a projected Bridge response")
            return
        }
        #expect(decodedPayload.outcome == nil)
        guard case .ok = decodedPayload.response else {
            Issue.record("Expected the wrapped legacy ok response")
            return
        }
    }

    @Test
    func `projected request validation accepts one mutation layer only`() throws {
        let wrapper = PeekabooBridgeProjectedActionRequest(request: Self.clickRequest)
        let validated = try wrapper.validatedRequest()

        guard case .click = validated else {
            Issue.record("Expected projected request validation to preserve the click request")
            return
        }

        self.expectInvalidProjectedRequest(.init(request: .permissionsStatus))
        self.expectInvalidProjectedRequest(.init(request: .handshake(.init(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            client: .init(
                bundleIdentifier: "dev.peekaboo.tests",
                teamIdentifier: nil,
                processIdentifier: 42,
                hostname: nil)))))
        self.expectInvalidProjectedRequest(.init(request: .projectedAction(wrapper)))
    }

    @Test
    @MainActor
    func `projected request preflight rejects unsafe shapes before routing or recursive decode`() async throws {
        let services = StubServices()
        var permissionEvaluationCount = 0
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            hostIdentity: nil,
            permissionStatusEvaluator: { _ in
                permissionEvaluationCount += 1
                return PermissionsStatus(
                    screenRecording: false,
                    accessibility: false,
                    postEvent: false)
            })

        let readOnly = try await Self.send(.projectedAction(.init(request: .permissionsStatus)), to: server)
        Self.expectProjectedInvalidResponse(readOnly)
        let handshake = PeekabooBridgeRequest.handshake(.init(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            client: Self.clientIdentity))
        let wrappedHandshake = try await Self.send(.projectedAction(.init(request: handshake)), to: server)
        Self.expectProjectedInvalidResponse(wrappedHandshake)
        #expect(permissionEvaluationCount == 0)
        #expect(services.automationStub.lastClick == nil)

        let escapedNestedWrapper = Data(
            #"{"projectedAction":{"_0":{"request":{"projected\u0041ction":{"_0":{"request":BROKEN}}}}}}"#.utf8)
        let nestedResponse = try await Self.decodeRaw(escapedNestedWrapper, with: server)
        guard case let .error(nestedEnvelope) = nestedResponse else {
            Issue.record("Expected raw preflight to reject nested projection carriage")
            return
        }
        #expect(nestedEnvelope.code == .invalidRequest)
        #expect(nestedEnvelope.message == "Projected Bridge action requests cannot be nested")

        let deepPrefix = #"{"projectedAction":{"_0":{"request":{"click":{"_0":{"target":"#
        let deepRequest = Data((
            deepPrefix +
                String(repeating: "[", count: PeekabooBridgeRequestPreflight.maximumJSONNestingDepth + 1))
            .utf8)
        let deepResponse = try await Self.decodeRaw(deepRequest, with: server)
        guard case let .error(deepEnvelope) = deepResponse else {
            Issue.record("Expected raw preflight to reject excessive JSON depth")
            return
        }
        #expect(deepEnvelope.code == .invalidRequest)
        #expect(deepEnvelope.message == "Bridge request JSON exceeds the maximum nesting depth")
        #expect(permissionEvaluationCount == 0)
        #expect(services.automationStub.lastClick == nil)

        let arbitraryPayloadKey = PeekabooBridgeRequest.projectedAction(.init(request: .browserExecute(.init(
            toolName: "fixture",
            arguments: ["projectedAction": .string("ordinary nested browser payload")]))))
        let arbitraryPayloadData = try JSONEncoder.peekabooBridgeEncoder().encode(arbitraryPayloadKey)
        #expect(throws: Never.self) {
            try PeekabooBridgeRequestPreflight.validate(arbitraryPayloadData)
        }
    }
}

extension PeekabooBridgeActionOutcomeProjectionTests {
    @Test
    @MainActor
    func `protocol 1 28 decoder accepts unauthorized cancellation and daemon shutdown failures`() async throws {
        let unauthorizedServer = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: ["dev.peekaboo.allowed"],
            permissionStatusEvaluator: { _ in Self.grantedPermissions })
        let unauthorizedPeer = PeekabooBridgePeer(
            processIdentifier: getpid(),
            userIdentifier: getuid(),
            bundleIdentifier: "dev.peekaboo.untrusted",
            teamIdentifier: nil)
        let unauthorizedData = try await Self.sendRaw(
            .projectedAction(.init(request: Self.moveMouseRequest)),
            to: unauthorizedServer,
            peer: unauthorizedPeer)
        let unauthorized = try Self.decodeLegacyProjectedFailure(unauthorizedData)
        #expect(unauthorized.envelope.actionOutcome?.refusalReason == .runtimeIncompatible)
        #expect(unauthorized.envelope.actionOutcome?.escalation == .updateRuntime)
        #expect(unauthorized.outcome == unauthorized.envelope.actionOutcome)
        Self.expectNoReceiptOnlyFailureVocabulary(in: unauthorizedData)

        let cancellationServer = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in Self.grantedPermissions })
        let disconnectedProbe: @Sendable () -> Bool = { false }
        let cancellationData = try await PeekabooBridgeRequestContext.$clientConnectionProbe.withValue(
            disconnectedProbe)
        {
            try await Self.sendRaw(
                .projectedAction(.init(request: Self.moveMouseRequest)),
                to: cancellationServer,
                peer: nil)
        }
        let cancellation = try Self.decodeLegacyProjectedFailure(cancellationData)
        #expect(cancellation.envelope.actionOutcome == nil)
        #expect(cancellation.outcome == nil)
        Self.expectNoReceiptOnlyFailureVocabulary(in: cancellationData)

        let daemonServer = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            daemonControl: RejectingConditionalDaemonControl(),
            permissionStatusEvaluator: { _ in Self.grantedPermissions })
        let daemonData = try await Self.sendRaw(
            .projectedAction(.init(request: Self.moveMouseRequest)),
            to: daemonServer,
            peer: nil)
        let daemon = try Self.decodeLegacyProjectedFailure(daemonData)
        #expect(daemon.envelope.actionOutcome?.refusalReason == .runtimeIncompatible)
        #expect(daemon.envelope.actionOutcome?.escalation == .updateRuntime)
        #expect(daemon.outcome == daemon.envelope.actionOutcome)
        Self.expectNoReceiptOnlyFailureVocabulary(in: daemonData)
    }

    @Test
    @MainActor
    func `signed protocol 1 29 failures retain exact transport and cancellation semantics`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-attested-failure-vocabulary-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)

        let unauthorizedServer = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: ["dev.peekaboo.allowed"],
            permissionStatusEvaluator: { _ in Self.grantedPermissions })
        let unauthorized = try await Self.sendAttestedProjectedFailure(
            sequence: 0,
            server: unauthorizedServer,
            authority: authority,
            session: session)
        Self.expectCurrentAttestedFailure(
            unauthorized,
            reason: .transportSessionUnavailable,
            escalation: .reconnectSession,
            authority: authority,
            session: session)

        let cancellationServer = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in Self.grantedPermissions })
        let cancellation = try await Self.sendAttestedProjectedFailure(
            sequence: 1,
            server: cancellationServer,
            authority: authority,
            session: session,
            connectionProbe: { false })
        Self.expectCurrentAttestedFailure(
            cancellation,
            reason: .requestCancelled,
            escalation: .none,
            authority: authority,
            session: session)

        let daemonServer = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            daemonControl: RejectingConditionalDaemonControl(),
            permissionStatusEvaluator: { _ in Self.grantedPermissions })
        let daemon = try await Self.sendAttestedProjectedFailure(
            sequence: 2,
            server: daemonServer,
            authority: authority,
            session: session)
        Self.expectCurrentAttestedFailure(
            daemon,
            reason: .transportSessionUnavailable,
            escalation: .reconnectSession,
            authority: authority,
            session: session)
    }

    @Test
    func `current protocol 1 30 preserves projection capability introduced at 1 23`() {
        let currentVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 31)
        let projectionVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 23)

        #expect(PeekabooBridgeConstants.protocolVersion == currentVersion)
        #expect(PeekabooBridgeConstants.supportedProtocolRange.upperBound == currentVersion)
        #expect(PeekabooBridgeConstants.desktopActionOutcomeProjectionVersion == projectionVersion)
        #expect(PeekabooBridgeHostCapability.desktopActionOutcomeProjection == "desktopActionOutcomeProjection")

        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: currentVersion,
            supportedOperations: [.click],
            hostCapabilities: [PeekabooBridgeHostCapability.desktopActionOutcomeProjection])
        #expect(handshake.hostCapabilities == ["desktopActionOutcomeProjection"])
    }

    @Test(arguments: [23, 28])
    func `legacy projected wire omits composite success and failure outcomes`(minorVersion: Int) throws {
        let version = PeekabooBridgeProtocolVersion(major: 1, minor: minorVersion)
        #expect(version >= PeekabooBridgeConstants.desktopActionOutcomeProjectionVersion)
        #expect(version < PeekabooBridgeConstants.attestedOperationReceiptVersion)
        let units = try #require(DesktopActionOutcome.DispatchUnitCount(2))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: units)

        let success = PeekabooBridgeResponse.projectedActionForCurrentRequestVocabulary(
            response: .ok,
            outcome: outcome.projection)
        let successData = try JSONEncoder.peekabooBridgeEncoder().encode(success)
        guard case let .projectedAction(successProjection) = try JSONDecoder.peekabooBridgeDecoder().decode(
            LegacyProtocol128BridgeResponse.self,
            from: successData)
        else {
            Issue.record("Expected legacy projected success")
            return
        }
        #expect(successProjection.outcome == nil)

        let failure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: units,
            message: "Mixed delivery completion is unknown")
        let failureResponse = PeekabooBridgeResponse.projectedActionForCurrentRequestVocabulary(
            response: .error(.init(code: .internalError, actionFailure: failure)),
            outcome: failure.outcome.projection)
        let failureData = try JSONEncoder.peekabooBridgeEncoder().encode(failureResponse)
        let decodedFailure = try Self.decodeLegacyProjectedFailure(failureData)
        #expect(decodedFailure.outcome == nil)
        #expect(decodedFailure.envelope.actionOutcome == nil)
        #expect(decodedFailure.envelope.operationMayHaveCompleted == true)
        #expect(successData.range(of: Data("composite".utf8)) == nil)
        #expect(failureData.range(of: Data("composite".utf8)) == nil)
    }

    @Test(arguments: [23, 28])
    func `legacy projected dialog strips process-only target receipt`(minorVersion: Int) throws {
        let version = PeekabooBridgeProtocolVersion(major: 1, minor: minorVersion)
        #expect(version >= PeekabooBridgeConstants.desktopActionOutcomeProjectionVersion)
        #expect(version < PeekabooBridgeConstants.attestedOperationReceiptVersion)
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let processReceipt = DesktopActionTargetReceipt(
            processIdentifier: 42,
            processStartIdentity: 1001)
        let result = DialogActionResult(
            success: true,
            action: .clickButton,
            outcome: outcome,
            targetReceipt: processReceipt)

        let legacy = PeekabooBridgeResponse.projectedActionForCurrentRequestVocabulary(
            response: .dialogResult(result),
            outcome: outcome.projection,
            usesCurrentVocabulary: false)
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(legacy)
        guard case let .projectedAction(projected) = try JSONDecoder.peekabooBridgeDecoder().decode(
            LegacyProtocol128BridgeResponse.self,
            from: data),
            case let .dialogResult(decoded) = projected.response
        else {
            Issue.record("Expected protocol 1.28 to decode the projected dialog response")
            return
        }
        #expect(decoded.targetReceipt == nil)

        let current = PeekabooBridgeResponse.projectedActionForCurrentRequestVocabulary(
            response: .dialogResult(result),
            outcome: outcome.projection,
            usesCurrentVocabulary: true)
        guard case let .projectedAction(currentProjected) = current,
              case let .dialogResult(currentResult) = currentProjected.response
        else {
            Issue.record("Expected current projected dialog response")
            return
        }
        #expect(currentResult.targetReceipt == processReceipt)
    }
}

extension PeekabooBridgeActionOutcomeProjectionTests {
    private func expectInvalidProjectedRequest(_ request: PeekabooBridgeProjectedActionRequest) {
        do {
            _ = try request.validatedRequest()
            Issue.record("Expected projected request validation to reject \(request.request.operation.rawValue)")
        } catch let error as PeekabooBridgeErrorEnvelope {
            #expect(error.code == .invalidRequest)
        } catch {
            Issue.record("Expected a Bridge invalid-request envelope, got \(error)")
        }
    }

    private static func expectProjectedInvalidResponse(_ response: PeekabooBridgeResponse) {
        guard case let .projectedAction(payload) = response,
              case let .error(envelope) = payload.response
        else {
            Issue.record("Expected projected invalid-request response")
            return
        }
        #expect(envelope.code == .invalidRequest)
        #expect(payload.outcome == nil)
    }

    private static func expectResponseKind(
        _ response: PeekabooBridgeResponse,
        matches outcome: DesktopActionOutcome)
    {
        switch (response, outcome.isConfirmed) {
        case (.ok, true):
            break
        case let (.error(error), false):
            #expect(error.code == .internalError)
            #expect(error.actionOutcome == outcome.projection)
            #expect(error.message == "Fixture \(outcome.state.rawValue)")
            #expect(error.details == "Fixture details \(outcome.state.rawValue)")
            #expect(error.permission == .accessibility)
            #expect(error.kind == .appNotFound)
            #expect(error.context == "fixture:\(outcome.state.rawValue)")
            #expect(error.operationMayHaveCompleted == outcome.projection.mutationDispatched)
        default:
            Issue.record("Legacy response kind contradicted \(outcome.state.rawValue)")
        }
    }

    private static func expectProjection(
        _ projection: [String: Any],
        equals expected: CanonicalDesktopActionOutcomeCase)
    {
        var expectedKeys: Set = [
            "state",
            "effect",
            "route",
            "evidence",
            "dispatch_state",
            "retry_safety",
            "escalation",
            "mutation_dispatched",
            "retry_safe",
            "requires_fresh_observation",
        ]
        if expected.delivery != nil {
            expectedKeys.formUnion(["delivery_mechanism", "delivery_mode"])
        }
        if expected.unitCount != nil {
            expectedKeys.insert("dispatched_unit_count")
        }
        if expected.refusalReason != nil {
            expectedKeys.insert("refusal_reason")
        }

        #expect(Set(projection.keys) == expectedKeys)
        #expect(projection["state"] as? String == expected.state.rawValue)
        #expect(projection["effect"] as? String == expected.effect.rawValue)
        #expect(projection["route"] as? String == expected.route.rawValue)
        #expect(projection["delivery_mechanism"] as? String == expected.delivery?.mechanism.rawValue)
        #expect(projection["delivery_mode"] as? String == expected.delivery?.mode.rawValue)
        #expect(projection["evidence"] as? String == expected.evidence.rawValue)
        #expect(projection["dispatch_state"] as? String == Self.dispatchStateName(expected.dispatchState))
        #expect(projection["dispatched_unit_count"] as? Int == expected.unitCount?.rawValue)
        #expect(projection["retry_safety"] as? String == expected.retrySafety.rawValue)
        #expect(projection["escalation"] as? String == expected.escalation.rawValue)
        #expect(projection["refusal_reason"] as? String == expected.refusalReason?.rawValue)
        #expect(projection["mutation_dispatched"] as? Bool == expected.mutationDispatched)
        #expect(projection["retry_safe"] as? Bool == expected.retrySafe)
        #expect(projection["requires_fresh_observation"] as? Bool == expected.requiresFreshObservation)
    }

    private static func dispatchStateName(_ state: DesktopActionOutcome.DispatchState) -> String {
        switch state {
        case .none: "none"
        case .dispatched: "dispatched"
        case .mayHaveDispatched: "may_have_dispatched"
        }
    }

    private static func object(from data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func canonicalJSON(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func projectedAssociation(from data: Data) throws -> [String: Any] {
        let root = try Self.object(from: data)
        let projectedCase = try #require(root["projectedAction"] as? [String: Any])
        return try #require(projectedCase["_0"] as? [String: Any])
    }

    private static func decodeLegacyProjectedFailure(
        _ data: Data) throws
        -> (envelope: LegacyProtocol128ErrorEnvelope, outcome: LegacyProtocol128ActionOutcome?)
    {
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(
            LegacyProtocol128BridgeResponse.self,
            from: data)
        guard case let .projectedAction(projected) = response,
              case let .error(envelope) = projected.response
        else {
            throw LegacyProtocol128TestError.expectedProjectedFailure
        }
        return (envelope, projected.outcome)
    }

    private static func expectNoReceiptOnlyFailureVocabulary(in data: Data) {
        let wire = String(bytes: data, encoding: .utf8) ?? ""
        #expect(!wire.contains("transport_session_unavailable"))
        #expect(!wire.contains("request_cancelled"))
        #expect(!wire.contains("reconnect_session"))
    }

    @MainActor
    private static func sendRaw(
        _ request: PeekabooBridgeRequest,
        to server: PeekabooBridgeServer,
        peer: PeekabooBridgePeer?) async throws -> Data
    {
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        return await server.decodeAndHandle(requestData, peer: peer)
    }

    @MainActor
    private static func sendAttestedProjectedFailure(
        sequence: UInt64,
        server: PeekabooBridgeServer,
        authority: PeekabooBridgeOperationReceiptAuthority,
        session: OperationReceiptSessionFixture,
        connectionProbe: @escaping @Sendable () -> Bool = { true }) async throws
        -> PeekabooBridgeAttestedOperationResponse
    {
        let projectedRequest = PeekabooBridgeRequest.projectedAction(.init(request: Self.moveMouseRequest))
        let payload = session.request(
            authority: authority,
            sequence: sequence,
            request: projectedRequest)
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeRequest.attestedOperation(payload))
        let responseData = await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(authority) {
            await PeekabooBridgeRequestContext.$clientConnectionProbe.withValue(connectionProbe) {
                await server.decodeAndHandle(requestData, peer: session.peer)
            }
        }
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: responseData)
        guard case let .attestedOperation(attested) = response else {
            throw LegacyProtocol128TestError.expectedAttestedFailure
        }
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: attested.receipt,
            request: projectedRequest,
            response: attested.response)
        try bundle.validate()
        return attested
    }

    private static func expectCurrentAttestedFailure(
        _ attested: PeekabooBridgeAttestedOperationResponse,
        reason: DesktopActionOutcome.RefusalReason,
        escalation: DesktopActionOutcome.Escalation,
        authority: PeekabooBridgeOperationReceiptAuthority,
        session: OperationReceiptSessionFixture)
    {
        guard case let .projectedAction(projected) = attested.response,
              case let .error(envelope) = projected.response
        else {
            Issue.record("Expected signed projected failure")
            return
        }
        #expect(projected.outcome == envelope.actionOutcome)
        #expect(projected.outcome?.outcome.refusalReason == reason)
        #expect(projected.outcome?.outcome.escalation == escalation)
        #expect(attested.receipt.payload.outcome == projected.outcome)
        #expect(attested.receipt.payload.sessionID == session.attestation.sessionID)
        #expect(throws: Never.self) {
            try attested.receipt.validateSignature(publicKey: authority.attestation.publicKey)
        }
    }

    @MainActor
    private static func send(
        _ request: PeekabooBridgeRequest,
        to server: PeekabooBridgeServer) async throws -> PeekabooBridgeResponse
    {
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        return try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: responseData)
    }

    @MainActor
    private static func decodeRaw(
        _ requestData: Data,
        with server: PeekabooBridgeServer) async throws -> PeekabooBridgeResponse
    {
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        return try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: responseData)
    }

    private static let clickRequest = PeekabooBridgeRequest.click(.init(
        target: .coordinates(CGPoint(x: 17, y: 29)),
        clickType: .single))

    private static let moveMouseRequest = PeekabooBridgeRequest.moveMouse(.init(
        to: CGPoint(x: 17, y: 29),
        duration: 0,
        steps: 1,
        profile: .linear))

    private static let quitRequest = PeekabooBridgeRequest.quitApplication(.init(
        identifier: "PID:123",
        force: false,
        expectedIdentity: .init(processIdentifier: 123, processStartIdentity: 456)))

    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.tests",
        teamIdentifier: nil,
        processIdentifier: getpid(),
        hostname: nil)

    private static let receiptlessProtocolVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 28)

    private static let grantedPermissions = PermissionsStatus(
        screenRecording: true,
        accessibility: true,
        postEvent: true)

    private static let legacyClickRequestData = Data(
        #"{"click":{"_0":{"clickType":"single","target":{"kind":"coordinates","x":17,"y":29}}}}"#.utf8)
}

extension StubAutomationService: ScriptedUIAutomationActionOutcomeProviding {}

private enum LegacyProtocol128BridgeResponse: Decodable {
    case projectedAction(LegacyProtocol128ProjectedActionResponse)
}

private struct LegacyProtocol128ProjectedActionResponse: Decodable {
    let response: LegacyProtocol128NestedResponse
    let outcome: LegacyProtocol128ActionOutcome?
}

private enum LegacyProtocol128NestedResponse: Decodable {
    case ok
    case error(LegacyProtocol128ErrorEnvelope)
    case dialogResult(LegacyProtocol128DialogActionResult)
}

private struct LegacyProtocol128DialogActionResult: Decodable {
    let targetReceipt: LegacyProtocol128ActionTargetReceipt?
}

private struct LegacyProtocol128ErrorEnvelope: Decodable {
    let code: String
    let message: String
    let details: String?
    let permission: String?
    let kind: String?
    let context: String?
    let actionOutcome: LegacyProtocol128ActionOutcome?
    let operationMayHaveCompleted: Bool?
    let actionFailureHint: String?
    let actionFailureCauseDescription: String?
    let actionTargetReceipt: LegacyProtocol128ActionTargetReceipt?
}

private struct LegacyProtocol128ActionOutcome: Decodable, Equatable {
    let state: String
    let effect: String
    let route: String
    let deliveryMechanism: LegacyProtocol128DeliveryMechanism?
    let deliveryMode: String?
    let evidence: String
    let dispatchState: String
    let dispatchedUnitCount: Int?
    let retrySafety: String
    let escalation: LegacyProtocol128Escalation
    let refusalReason: LegacyProtocol128RefusalReason?
    let mutationDispatched: Bool
    let retrySafe: Bool
    let requiresFreshObservation: Bool

    private enum CodingKeys: String, CodingKey {
        case state
        case effect
        case route
        case deliveryMechanism = "delivery_mechanism"
        case deliveryMode = "delivery_mode"
        case evidence
        case dispatchState = "dispatch_state"
        case dispatchedUnitCount = "dispatched_unit_count"
        case retrySafety = "retry_safety"
        case escalation
        case refusalReason = "refusal_reason"
        case mutationDispatched = "mutation_dispatched"
        case retrySafe = "retry_safe"
        case requiresFreshObservation = "requires_fresh_observation"
    }
}

private struct LegacyProtocol128ActionTargetReceipt: Decodable, Equatable {
    let processIdentifier: Int32
    let processStartIdentity: UInt64
    let processStartIdentityDecimal: String?
    let windowID: Int

    private enum CodingKeys: String, CodingKey {
        case processIdentifier = "pid"
        case processStartIdentity = "process_start_identity"
        case processStartIdentityDecimal = "process_start_identity_decimal"
        case windowID = "window_id"
    }
}

private enum LegacyProtocol128DeliveryMechanism: String, Decodable, Equatable {
    case accessibilityAction = "accessibility_action"
    case accessibilityValue = "accessibility_value"
    case processTargetedEvents = "process_targeted_events"
    case windowTargetedEvents = "window_targeted_events"
    case globalEvents = "global_events"
    case clipboardTransaction = "clipboard_transaction"
    case nativeFramework = "native_framework"
    case browserProtocol = "browser_protocol"
    case capturePipeline = "capture_pipeline"
}

private enum LegacyProtocol128Escalation: String, Decodable, Equatable {
    case none
    case correctRequest = "correct_request"
    case grantPermission = "grant_permission"
    case refreshTarget = "refresh_target"
    case updateRuntime = "update_runtime"
    case recoverSideEffect = "recover_side_effect"
    case observeBeforeRetry = "observe_before_retry"
}

private enum LegacyProtocol128RefusalReason: String, Decodable, Equatable {
    case invalidRequest = "invalid_request"
    case permissionDenied = "permission_denied"
    case targetUnavailable = "target_unavailable"
    case runtimeIncompatible = "runtime_incompatible"
    case foregroundConsentRequired = "foreground_consent_required"
    case operationUnsupported = "operation_unsupported"
}

private enum LegacyProtocol128TestError: Error {
    case expectedProjectedFailure
    case expectedAttestedFailure
}

@MainActor
private final class RejectingConditionalDaemonControl: PeekabooConditionalDaemonControlProviding {
    func daemonStatus() async -> PeekabooDaemonStatus {
        PeekabooDaemonStatus(running: true)
    }

    func requestStop() async -> Bool {
        true
    }

    func requestStop(expectedPID _: pid_t) async -> Bool {
        true
    }

    func admitActivity(operation _: PeekabooBridgeOperation) async -> Bool {
        false
    }
}
