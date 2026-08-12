import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

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

    private static let clickRequest = PeekabooBridgeRequest.click(.init(
        target: .coordinates(CGPoint(x: 17, y: 29)),
        clickType: .single))

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
