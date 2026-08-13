import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

struct PeekabooBridgeActionOutcomeProjectionTests {
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
        #expect(projectedPayload.outcome == nil)

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
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            supportedOperations: [.click],
            hostCapabilities: [PeekabooBridgeHostCapability.desktopActionOutcomeProjection])
        let currentPeer = try NegotiatedProjectionBridgePeer(responses: [
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
        let previousPeer = try NegotiatedProjectionBridgePeer(responses: [
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
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            supportedOperations: [.click],
            hostCapabilities: [PeekabooBridgeHostCapability.desktopActionOutcomeProjection])
        let peer = try NegotiatedProjectionBridgePeer(responses: [.handshake(handshake), .ok])
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

        for outcome in BridgeTestFixtures.canonicalActionOutcomes {
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

        for request in requests {
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
            delivery: .init(mechanism: .accessibilityAction, mode: .background))
        let currentHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            supportedOperations: [.click],
            hostCapabilities: [PeekabooBridgeHostCapability.desktopActionOutcomeProjection])
        let currentPeer = try NegotiatedProjectionBridgePeer(responses: [
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
        let previousPeer = try NegotiatedProjectionBridgePeer(responses: [
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
        let expected = try DesktopActionFailure.partial(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "The target changed but cleanup failed",
            hint: "Recover the remaining side effect.",
            causeDescription: "cleanup receipt was unavailable")
        let envelope = PeekabooBridgeErrorEnvelope(code: .internalError, actionFailure: expected)
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            supportedOperations: [.click],
            hostCapabilities: [PeekabooBridgeHostCapability.desktopActionOutcomeProjection])
        let peer = try NegotiatedProjectionBridgePeer(responses: [
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
        let outcomes = BridgeTestFixtures.canonicalActionOutcomes
        let expectations = Self.projectionExpectations

        #expect(outcomes.map(\.state) == [
            .confirmedChange,
            .confirmedNoChange,
            .partial,
            .dispatchedUnverified,
            .suspectedNoop,
            .refused,
            .indeterminate,
        ])
        #expect(outcomes.count == expectations.count)

        for (outcome, expectation) in zip(outcomes, expectations) {
            let legacyResponse = Self.legacyResponse(for: outcome)
            let response = PeekabooBridgeResponse.projectedAction(.init(
                response: legacyResponse,
                outcome: outcome.projection))
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

        let outcome = BridgeTestFixtures.canonicalActionOutcomes[0]
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

    @Test
    func `projection capability is introduced at protocol 1 23`() {
        let expectedVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 23)

        #expect(PeekabooBridgeConstants.protocolVersion == expectedVersion)
        #expect(PeekabooBridgeConstants.supportedProtocolRange.upperBound == expectedVersion)
        #expect(PeekabooBridgeHostCapability.desktopActionOutcomeProjection == "desktopActionOutcomeProjection")

        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: expectedVersion,
            supportedOperations: [.click],
            hostCapabilities: [PeekabooBridgeHostCapability.desktopActionOutcomeProjection])
        #expect(handshake.hostCapabilities == ["desktopActionOutcomeProjection"])
    }

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

    private static func legacyResponse(for outcome: DesktopActionOutcome) -> PeekabooBridgeResponse {
        guard !outcome.isConfirmed else { return .ok }
        return BridgeTestFixtures.errorResponse(
            code: .internalError,
            message: "Fixture \(outcome.state.rawValue)",
            details: "Fixture details \(outcome.state.rawValue)",
            permission: .accessibility,
            kind: .appNotFound,
            context: "fixture:\(outcome.state.rawValue)",
            operationMayHaveCompleted: outcome.projection.mutationDispatched)
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
        equals expected: ProjectionExpectation)
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
        if expected.deliveryMechanism != nil {
            expectedKeys.formUnion(["delivery_mechanism", "delivery_mode"])
        }
        if expected.dispatchedUnitCount != nil {
            expectedKeys.insert("dispatched_unit_count")
        }
        if expected.refusalReason != nil {
            expectedKeys.insert("refusal_reason")
        }

        #expect(Set(projection.keys) == expectedKeys)
        #expect(projection["state"] as? String == expected.state)
        #expect(projection["effect"] as? String == expected.effect)
        #expect(projection["route"] as? String == "local")
        #expect(projection["delivery_mechanism"] as? String == expected.deliveryMechanism)
        #expect(projection["delivery_mode"] as? String == expected.deliveryMode)
        #expect(projection["evidence"] as? String == expected.evidence)
        #expect(projection["dispatch_state"] as? String == expected.dispatchState)
        #expect(projection["dispatched_unit_count"] as? Int == expected.dispatchedUnitCount)
        #expect(projection["retry_safety"] as? String == expected.retrySafety)
        #expect(projection["escalation"] as? String == expected.escalation)
        #expect(projection["refusal_reason"] as? String == expected.refusalReason)
        #expect(projection["mutation_dispatched"] as? Bool == expected.mutationDispatched)
        #expect(projection["retry_safe"] as? Bool == expected.retrySafe)
        #expect(projection["requires_fresh_observation"] as? Bool == expected.requiresFreshObservation)
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

    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.tests",
        teamIdentifier: nil,
        processIdentifier: getpid(),
        hostname: nil)

    private static let grantedPermissions = PermissionsStatus(
        screenRecording: true,
        accessibility: true,
        postEvent: true)

    private static let legacyClickRequestData = Data(
        #"{"click":{"_0":{"clickType":"single","target":{"kind":"coordinates","x":17,"y":29}}}}"#.utf8)

    private static let projectionExpectations: [ProjectionExpectation] = [
        .init(
            state: "confirmed_change",
            effect: "confirmed",
            deliveryMechanism: "accessibility_action",
            deliveryMode: "background",
            evidence: "verified_change",
            dispatchState: "dispatched",
            dispatchedUnitCount: 1,
            retrySafety: "not_applicable",
            escalation: "none",
            refusalReason: nil,
            mutationDispatched: true,
            retrySafe: false,
            requiresFreshObservation: false),
        .init(
            state: "confirmed_no_change",
            effect: "confirmed",
            deliveryMechanism: nil,
            deliveryMode: nil,
            evidence: "verified_no_change",
            dispatchState: "none",
            dispatchedUnitCount: nil,
            retrySafety: "not_applicable",
            escalation: "none",
            refusalReason: nil,
            mutationDispatched: false,
            retrySafe: false,
            requiresFreshObservation: false),
        .init(
            state: "partial",
            effect: "partial",
            deliveryMechanism: "accessibility_action",
            deliveryMode: "background",
            evidence: "primary_change_verified_cleanup_failed",
            dispatchState: "dispatched",
            dispatchedUnitCount: 2,
            retrySafety: "unsafe",
            escalation: "recover_side_effect",
            refusalReason: nil,
            mutationDispatched: true,
            retrySafe: false,
            requiresFreshObservation: false),
        .init(
            state: "dispatched_unverified",
            effect: "unverifiable",
            deliveryMechanism: "process_targeted_events",
            deliveryMode: "background",
            evidence: "operation_still_running",
            dispatchState: "dispatched",
            dispatchedUnitCount: 3,
            retrySafety: "unsafe",
            escalation: "observe_before_retry",
            refusalReason: nil,
            mutationDispatched: true,
            retrySafe: false,
            requiresFreshObservation: true),
        .init(
            state: "suspected_noop",
            effect: "suspected_noop",
            deliveryMechanism: "accessibility_action",
            deliveryMode: "background",
            evidence: "observed_no_change",
            dispatchState: "dispatched",
            dispatchedUnitCount: 1,
            retrySafety: "safe",
            escalation: "refresh_target",
            refusalReason: nil,
            mutationDispatched: true,
            retrySafe: true,
            requiresFreshObservation: false),
        .init(
            state: "refused",
            effect: "refused",
            deliveryMechanism: nil,
            deliveryMode: nil,
            evidence: "request_refused",
            dispatchState: "none",
            dispatchedUnitCount: nil,
            retrySafety: "safe",
            escalation: "grant_permission",
            refusalReason: "permission_denied",
            mutationDispatched: false,
            retrySafe: true,
            requiresFreshObservation: false),
        .init(
            state: "indeterminate",
            effect: "unverifiable",
            deliveryMechanism: "process_targeted_events",
            deliveryMode: "background",
            evidence: "response_lost",
            dispatchState: "may_have_dispatched",
            dispatchedUnitCount: 2,
            retrySafety: "unsafe",
            escalation: "observe_before_retry",
            refusalReason: nil,
            mutationDispatched: true,
            retrySafe: false,
            requiresFreshObservation: true),
    ]

    private struct ProjectionExpectation {
        let state: String
        let effect: String
        let deliveryMechanism: String?
        let deliveryMode: String?
        let evidence: String
        let dispatchState: String
        let dispatchedUnitCount: Int?
        let retrySafety: String
        let escalation: String
        let refusalReason: String?
        let mutationDispatched: Bool
        let retrySafe: Bool
        let requiresFreshObservation: Bool
    }
}

@MainActor
enum StubAutomationOutcomeTestControl {
    private static var typeOutcomes: [ObjectIdentifier: DesktopActionOutcome] = [:]
    private static var hotkeyOutcomes: [ObjectIdentifier: [DesktopActionOutcome]] = [:]
    private static var hotkeyCallCounts: [ObjectIdentifier: Int] = [:]

    static func setTypeOutcome(_ outcome: DesktopActionOutcome?, for automation: StubAutomationService) {
        self.typeOutcomes[ObjectIdentifier(automation)] = outcome
    }

    static func typeOutcome(for automation: StubAutomationService) -> DesktopActionOutcome? {
        self.typeOutcomes[ObjectIdentifier(automation)]
    }

    static func setHotkeyOutcomes(_ outcomes: [DesktopActionOutcome]?, for automation: StubAutomationService) {
        self.hotkeyOutcomes[ObjectIdentifier(automation)] = outcomes
    }

    static func nextHotkeyOutcome(for automation: StubAutomationService) -> DesktopActionOutcome? {
        let identifier = ObjectIdentifier(automation)
        guard var outcomes = self.hotkeyOutcomes[identifier], !outcomes.isEmpty else { return nil }
        let outcome = outcomes.removeFirst()
        self.hotkeyOutcomes[identifier] = outcomes
        return outcome
    }

    static func resetHotkeyCalls(for automation: StubAutomationService) {
        self.hotkeyCallCounts[ObjectIdentifier(automation)] = 0
    }

    static func recordHotkeyCall(for automation: StubAutomationService) {
        let identifier = ObjectIdentifier(automation)
        self.hotkeyCallCounts[identifier, default: 0] += 1
    }

    static func hotkeyCallCount(for automation: StubAutomationService) -> Int {
        self.hotkeyCallCounts[ObjectIdentifier(automation), default: 0]
    }
}

extension StubAutomationService: UIAutomationActionOutcomeProviding {
    func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?) async throws -> UIAutomationActionResult<Void>
    {
        try await self.click(target: target, clickType: clickType, snapshotId: snapshotId)
        return self.actionResult(())
    }

    func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> UIAutomationActionResult<Void>
    {
        try await self.click(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier)
        return self.actionResult(())
    }

    func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<Void>
    {
        try await self.click(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedProcessIdentity: expectedProcessIdentity)
        return self.actionResult(())
    }

    func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<Void>
    {
        try await self.click(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds)
        return self.actionResult(())
    }

    func typeWithOutcome(
        text: String,
        target: String?,
        clearExisting: Bool,
        typingDelay: Int,
        snapshotId: String?) async throws -> UIAutomationActionResult<Void>
    {
        try await self.type(
            text: text,
            target: target,
            clearExisting: clearExisting,
            typingDelay: typingDelay,
            snapshotId: snapshotId)
        return self.actionResult(())
    }

    func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?) async throws -> UIAutomationActionResult<TypeResult>
    {
        try await self.typeActionResult(self.typeActions(actions, cadence: cadence, snapshotId: snapshotId))
    }

    func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> UIAutomationActionResult<TypeResult>
    {
        try await self.typeActionResult(self.typeActions(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier))
    }

    func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<TypeResult>
    {
        try await self.typeActionResult(self.typeActions(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            expectedProcessIdentity: expectedProcessIdentity))
    }

    func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<TypeResult>
    {
        try await self.typeActionResult(self.typeActions(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds))
    }

    func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        target: ExactWindowKeyboardTarget) async throws -> UIAutomationActionResult<TypeResult>
    {
        try await self.typeActionResult(self.typeActions(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            target: target))
    }

    func scrollWithOutcome(_ request: ScrollRequest) async throws -> UIAutomationActionResult<Void> {
        try await self.scroll(request)
        return self.actionResult(())
    }

    func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int) async throws -> UIAutomationActionResult<Void>
    {
        StubAutomationOutcomeTestControl.recordHotkeyCall(for: self)
        try await self.hotkey(keys: keys, holdDuration: holdDuration)
        if let outcome = StubAutomationOutcomeTestControl.nextHotkeyOutcome(for: self) {
            return UIAutomationActionResult(payload: (), outcome: outcome)
        }
        return self.actionResult(())
    }

    func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        targetProcessIdentifier: pid_t) async throws -> UIAutomationActionResult<Void>
    {
        try await self.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            targetProcessIdentifier: targetProcessIdentifier)
        return self.actionResult(())
    }

    func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<Void>
    {
        try await self.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            expectedProcessIdentity: expectedProcessIdentity)
        return self.actionResult(())
    }

    func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<Void>
    {
        try await self.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds)
        return self.actionResult(())
    }

    func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        target: ExactWindowKeyboardTarget) async throws -> UIAutomationActionResult<Void>
    {
        try await self.hotkey(keys: keys, holdDuration: holdDuration, target: target)
        return self.actionResult(())
    }

    func setValueWithOutcome(
        target: String,
        value: UIElementValue,
        snapshotId: String?) async throws -> UIAutomationActionResult<ElementActionResult>
    {
        try await self.actionResult(self.setValue(target: target, value: value, snapshotId: snapshotId))
    }

    func performActionWithOutcome(
        target: String,
        actionName: String,
        snapshotId: String?) async throws -> UIAutomationActionResult<ElementActionResult>
    {
        try await self.actionResult(self.performAction(
            target: target,
            actionName: actionName,
            snapshotId: snapshotId))
    }

    private func actionResult<Payload: Sendable>(_ payload: Payload) -> UIAutomationActionResult<Payload> {
        UIAutomationActionResult(payload: payload, outcome: self.actionOutcome)
    }

    private func typeActionResult<Payload: Sendable>(_ payload: Payload) -> UIAutomationActionResult<Payload> {
        UIAutomationActionResult(
            payload: payload,
            outcome: StubAutomationOutcomeTestControl.typeOutcome(for: self) ?? self.actionOutcome)
    }
}

private actor NegotiatedProjectionBridgePeerState {
    private(set) var requests: [Data] = []

    func record(_ request: Data) {
        self.requests.append(request)
    }
}

private final class NegotiatedProjectionBridgePeer: @unchecked Sendable {
    let socketPath: String
    private let listener: Int32
    private let state = NegotiatedProjectionBridgePeerState()
    private var task: Task<Void, Never>?

    var requests: [Data] {
        get async { await self.state.requests }
    }

    init(responses: [PeekabooBridgeResponse]) throws {
        self.socketPath = "/tmp/pb-projection-negotiation-\(UUID().uuidString).sock"
        self.listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard self.listener >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout.size(ofValue: address))
            let copied = self.socketPath.withCString { source in
                strlcpy(&address.sun_path.0, source, MemoryLayout.size(ofValue: address.sun_path))
            }
            guard copied < MemoryLayout.size(ofValue: address.sun_path) else {
                throw POSIXError(.ENAMETOOLONG)
            }
            let length = socklen_t(MemoryLayout.size(ofValue: address))
            let bindResult = withUnsafePointer(to: &address) { pointer in
                Darwin.bind(self.listener, UnsafePointer<sockaddr>(OpaquePointer(pointer)), length)
            }
            guard bindResult == 0, listen(self.listener, Int32(responses.count)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            Darwin.close(self.listener)
            try? FileManager.default.removeItem(atPath: self.socketPath)
            throw error
        }

        let listener = self.listener
        let socketPath = self.socketPath
        let state = self.state
        self.task = Task.detached {
            defer {
                Darwin.close(listener)
                try? FileManager.default.removeItem(atPath: socketPath)
            }
            for response in responses {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                let request = Self.readRequest(from: client)
                await state.record(request)
                if let data = try? JSONEncoder.peekabooBridgeEncoder().encode(response) {
                    Self.write(data, to: client)
                }
                Darwin.close(client)
            }
        }
    }

    func waitUntilFinished() async {
        await self.task?.value
        self.task = nil
    }

    private nonisolated static func readRequest(from descriptor: Int32) -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            return result
        }
    }

    private nonisolated static func write(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}
