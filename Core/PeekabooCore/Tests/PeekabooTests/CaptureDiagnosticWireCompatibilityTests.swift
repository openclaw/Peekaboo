import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge

@Suite(.serialized)
@MainActor
struct CaptureDiagnosticWireCompatibilityTests {
    @Test
    func `unoffered signed late blocker survives an old decoder`() async throws {
        let fixture = try await Self.fixture(offers: nil)
        let response = try await Self.signedResponse(fixture)
        let old = try JSONDecoder.peekabooBridgeDecoder().decode(
            OldResponse.self,
            from: PeekabooBridgeOperationReceiptCoding.canonicalData(response.response))
        #expect(try PeekabooBridgeOperationReceiptCoding.sha256(old) == response.receipt.payload.responseSHA256)
        #expect(Self.error(in: response.response)?.screenCaptureKitOwnershipDiagnostic == nil)
        #expect(Self.error(in: response.response)?.message.contains("4242") == true)
    }

    @Test(arguments: ["absent", "unknown", "typed"], [29, PeekabooBridgeConstants.protocolVersion.minor])
    func `signed diagnostics require an exact offer at each supported version`(offer: String, minor: Int) async throws {
        let fixture = try await Self.fixture(offers: Self.offers(offer), version: .init(major: 1, minor: minor))
        let response = try await Self.signedResponse(fixture)
        let envelope = try #require(Self.error(in: response.response))
        #expect(envelope.screenCaptureKitOwnershipDiagnostic == (offer == "typed" ? Self.diagnostic : nil))
        #expect(envelope.standardizedErrorCode == .captureFailed)
        #expect(envelope.message == Self.diagnostic.userMessage)
        #expect(envelope.actionOutcome?.mutationDispatched == false)
        if offer != "typed" {
            let old = try JSONDecoder.peekabooBridgeDecoder().decode(
                OldResponse.self, from: PeekabooBridgeOperationReceiptCoding.canonicalData(response.response))
            #expect(try PeekabooBridgeOperationReceiptCoding.sha256(old) == response.receipt.payload.responseSHA256)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func `signed projection preserves earlier mutation outcomes`(offered: Bool, projected: Bool) async throws {
        let fixture = try await Self.fixture(offers: Self.offers(offered ? "typed" : "absent"), priorMutation: true)
        if !projected {
            let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
                _ = try await Self.signedResponse(fixture, priorMutation: true, projected: false)
            }
            #expect(error?.code == .invalidRequest)
            #expect(error?.message == "Mutating attested Bridge operations require action outcome carriage")
            return
        }
        let response = try await Self.signedResponse(fixture, priorMutation: true, projected: projected)
        let envelope = try #require(Self.error(in: response.response))
        #expect(envelope.operationMayHaveCompleted)
        #expect(envelope.actionOutcome?.mutationDispatched == true)
        #expect(envelope.desktopActionFailure?.outcome.retrySafety == .unsafe)
        #expect(envelope.standardizedErrorCode == .captureFailed)
        #expect(envelope.screenCaptureKitOwnershipDiagnostic == (offered ? Self.diagnostic : nil))
        if !offered {
            let old = try JSONDecoder.peekabooBridgeDecoder().decode(
                OldResponse.self, from: PeekabooBridgeOperationReceiptCoding.canonicalData(response.response))
            #expect(try PeekabooBridgeOperationReceiptCoding.sha256(old) == response.receipt.payload.responseSHA256)
        }
    }

    @Test
    func `a later offered handshake cannot upgrade an earlier session`() async throws {
        let old = try await Self.fixture(offers: nil)
        let currentSession = try await Self.session(
            server: old.server,
            authority: old.authority,
            peer: old.session.peer,
            offers: Self.offers("typed"),
            version: PeekabooBridgeConstants.protocolVersion)
        let current = Fixture(server: old.server, authority: old.authority, session: currentSession)
        #expect(try await Self.error(in: Self.signedResponse(old).response)?.screenCaptureKitOwnershipDiagnostic == nil)
        #expect(try await Self.error(in: Self.signedResponse(current).response)?
            .screenCaptureKitOwnershipDiagnostic == Self.diagnostic)
        let rawData = await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(old.authority) {
            await old.server.handleDecoded(Self.request(priorMutation: false, projected: false), peer: old.session.peer)
        }
        let rawResponse = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: rawData)
        #expect(Self.error(in: rawResponse)?.screenCaptureKitOwnershipDiagnostic == nil)
        #expect(Self.error(in: rawResponse)?.standardizedErrorCode == .captureFailed)
    }

    @Test(arguments: ["absent", "unknown", "typed"], [false, true])
    func `receiptless old protocol offers cannot authorize diagnostic fields`(
        offer: String,
        projected: Bool) async throws
    {
        let server = CaptureReadinessPublicationTests.server(
            observation: LateBlockerObservation(diagnostic: Self.diagnostic, priorMutation: projected))
        try await server.prepareScreenCaptureKitOwnershipForServing()
        let peer = try OperationReceiptSessionFixture.currentPeer(codeSignatureHash: "synthetic-client")
        let handshakeResponse = try await server.handleHandshake(
            .init(
                protocolVersion: .init(major: 1, minor: 28),
                client: .init(bundleIdentifier: nil, teamIdentifier: nil, processIdentifier: getpid()),
                operationClientInstanceID: UUID(),
                clientCapabilities: Self.offers(offer)),
            peer: peer,
            permissions: Self.permissions)
        guard case let .handshake(handshake) = handshakeResponse else { throw POSIXError(.EINVAL) }
        #expect(handshake.operationSessionAttestation == nil)
        #expect(handshake.screenCaptureKitReadiness?.permitsAttempt == true)
        let request = Self.request(priorMutation: projected, projected: projected)
        let data = await server.handleDecoded(request, peer: peer)
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
        let envelope = try #require(Self.error(in: response))
        #expect(envelope.screenCaptureKitOwnershipDiagnostic == nil)
        #expect(envelope.standardizedErrorCode == .captureFailed)
        #expect(envelope.operationMayHaveCompleted == projected)
        let old = try JSONDecoder.peekabooBridgeDecoder().decode(OldResponse.self, from: data)
        #expect(try PeekabooBridgeOperationReceiptCoding.canonicalData(old) ==
            PeekabooBridgeOperationReceiptCoding.canonicalData(response))
    }

    @Test
    func `current client offers diagnostic response semantics only with signed sessions`() {
        #expect(PeekabooBridgeClient.offeredCapabilities(for: PeekabooBridgeConstants.protocolVersion)
            .contains(PeekabooBridgeClientCapability.screenCaptureKitOwnershipDiagnostics))
        #expect(PeekabooBridgeClient.offeredCapabilities(for: .init(major: 1, minor: 29))
            .contains(PeekabooBridgeClientCapability.screenCaptureKitOwnershipDiagnostics))
        #expect(!PeekabooBridgeClient.offeredCapabilities(for: .init(major: 1, minor: 28))
            .contains(PeekabooBridgeClientCapability.screenCaptureKitOwnershipDiagnostics))
    }

    @Test
    func `blocked capture readiness does not gate inspectAccessibilityTree`() async throws {
        let diagnostic = Self.diagnostic
        let server = CaptureReadinessPublicationTests.server(
            allowedOperations: [.desktopObservation, .inspectAccessibilityTree],
            preparation: { throw diagnostic })
        try await server.prepareScreenCaptureKitOwnershipForServing()
        try server.validateOperationAccess(
            for: .inspectAccessibilityTree(.init(windowContext: nil)),
            permissions: .init(screenRecording: false, accessibility: true, appleScript: false, postEvent: false),
            effectiveOps: [.inspectAccessibilityTree])
    }

    @Test(
        arguments: ["absent", "unknown", "capture", "target", "both"],
        [29, PeekabooBridgeConstants.protocolVersion.minor])
    func `target diagnostics are independently negotiated before signing`(offer: String, minor: Int) async throws {
        let captureCapability = PeekabooBridgeClientCapability.screenCaptureKitOwnershipDiagnostics
        let targetCapability = PeekabooBridgeClientCapability.desktopObservationTargetChangeDiagnostics
        let offers: [String] = switch offer {
        case "capture": [PeekabooBridgeClientCapability.screenCaptureKitOwnershipDiagnostics]
        case "target": [PeekabooBridgeClientCapability.desktopObservationTargetChangeDiagnostics]
        case "both": [captureCapability, targetCapability]
        case "unknown": ["futureTargetDiagnostics"]
        default: []
        }
        let offered = offer == "target" || offer == "both"
        let fixture = try await Self.fixture(
            offers: offers, version: .init(major: 1, minor: minor), targetChange: true)
        let response = try await Self.signedResponse(fixture)
        let envelope = try #require(Self.error(in: response.response))
        #expect(envelope.desktopObservationTargetChangeDiagnostic == (offered ? Self.targetDiagnostic : nil))
        #expect(envelope.code == .notFound)
        #expect(envelope.kind == .windowNotFound)
        #expect(envelope.details == #"targetChanged("fixture")"#)
        #expect(envelope.message == "Desktop observation target changed during capture: fixture")
        if !offered {
            let bytes = try PeekabooBridgeOperationReceiptCoding.canonicalData(response.response)
            let old = try JSONDecoder.peekabooBridgeDecoder().decode(OldResponse.self, from: bytes)
            #expect(try PeekabooBridgeOperationReceiptCoding.canonicalData(old) == bytes)
            #expect(try PeekabooBridgeOperationReceiptCoding.sha256(old) == response.receipt.payload.responseSHA256)
        }
        let rawData = await fixture.server.handleDecoded(
            Self.request(priorMutation: false, projected: false), peer: fixture.session.peer)
        let raw = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: rawData)
        #expect(Self.error(in: raw)?.desktopObservationTargetChangeDiagnostic == nil)
    }

    @Test(arguments: [false, true])
    func `signed target diagnostics retain wrapped mutation failures`(offered: Bool) async throws {
        let fixture = try await Self.fixture(
            offers: offered ? [PeekabooBridgeClientCapability.desktopObservationTargetChangeDiagnostics] : [],
            priorMutation: true,
            targetChange: true)
        let response = try await Self.signedResponse(fixture, priorMutation: true, projected: true)
        let envelope = try #require(Self.error(in: response.response))
        #expect(envelope.desktopObservationTargetChangeDiagnostic == (offered ? Self.targetDiagnostic : nil))
        #expect(envelope.desktopActionFailure?.desktopObservationTargetChangeDiagnostic ==
            (offered ? Self.targetDiagnostic : nil))
        #expect(envelope.code == .internalError)
        #expect(envelope.operationMayHaveCompleted)
        #expect(envelope.message == "fixture mutation failure")
        #expect(envelope.details?.contains("desktopObservationTargetChangeDiagnostic") == false)
        if !offered {
            let old = try JSONDecoder.peekabooBridgeDecoder().decode(
                OldResponse.self, from: PeekabooBridgeOperationReceiptCoding.canonicalData(response.response))
            #expect(try PeekabooBridgeOperationReceiptCoding.sha256(old) == response.receipt.payload.responseSHA256)
        }
    }

    @Test(arguments: [false, true])
    func `target diagnostic projection covers nested browser action failures`(offered: Bool) {
        let failure = DesktopActionFailure.preDispatchRefusal(reason: .targetUnavailable, message: "fixture")
            .preservingDesktopObservationTargetChangeDiagnostic(Self.targetDiagnostic)
        let envelope = PeekabooBridgeErrorEnvelope(code: .notFound, actionFailure: failure)
        #expect(envelope.desktopActionFailure?.desktopObservationTargetChangeDiagnostic == Self.targetDiagnostic)
        let response = PeekabooBridgeResponse.error(envelope)
            .projectingDesktopObservationTargetChangeDiagnostics(offered: offered)
        #expect(Self.error(in: response)?.desktopActionFailure?.desktopObservationTargetChangeDiagnostic ==
            (offered ? Self.targetDiagnostic : nil))
        let browser = PeekabooBridgeResponse.projectedAction(.init(
            response: .browserToolResponse(.init(content: [], isError: true, meta: nil, actionFailure: failure)),
            outcome: failure.outcome.projection))
            .projectingDesktopObservationTargetChangeDiagnostics(offered: offered)
        guard case let .projectedAction(projected) = browser,
              case let .browserToolResponse(result) = projected.response
        else {
            Issue.record("Expected nested browser response")
            return
        }
        #expect(result.actionFailure?
            .desktopObservationTargetChangeDiagnostic == (offered ? Self.targetDiagnostic : nil))
        #expect(envelope.removingScreenCaptureKitDiagnostic().desktopObservationTargetChangeDiagnostic ==
            Self.targetDiagnostic)
        #expect(failure.removingScreenCaptureKitDiagnostic().desktopObservationTargetChangeDiagnostic ==
            Self.targetDiagnostic)
    }

    @Test
    func `target capability versions and missing or future diagnostic fields`() throws {
        for minor in [28, 29, PeekabooBridgeConstants.protocolVersion.minor] {
            #expect(PeekabooBridgeClient.offeredCapabilities(for: .init(major: 1, minor: minor))
                .contains(PeekabooBridgeClientCapability.desktopObservationTargetChangeDiagnostics) == (minor >= 29))
        }
        let old = Data(#"{"code":"notFound","message":"fixture"}"#.utf8)
        #expect(try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeErrorEnvelope.self, from: old)
            .desktopObservationTargetChangeDiagnostic == nil)
        let future = Data(#"""
        {"code":"notFound","message":"fixture",
         "desktopObservationTargetChangeDiagnostic":{"classification":"future","phase":"future",
          "passive_recovery":{"attempted":false,"attempt_count":0,"final_status":"future"}}}
        """#.utf8)
        let diagnostic = try #require(JSONDecoder.peekabooBridgeDecoder()
            .decode(PeekabooBridgeErrorEnvelope.self, from: future).desktopObservationTargetChangeDiagnostic)
        #expect(diagnostic.classification == .unknown)
        #expect(diagnostic.phase == .unknown)
        #expect(diagnostic.passiveRecovery.finalStatus == .unknown)
    }

    @Test
    func `receiptless target offers retain exact legacy bytes`() async throws {
        let server = CaptureReadinessPublicationTests.server(
            observation: TargetChangeObservation(diagnostic: Self.targetDiagnostic))
        let peer = try OperationReceiptSessionFixture.currentPeer(codeSignatureHash: "synthetic-client")
        _ = try await server.handleHandshake(
            .init(
                protocolVersion: .init(major: 1, minor: 28),
                client: .init(bundleIdentifier: nil, teamIdentifier: nil, processIdentifier: getpid()),
                clientCapabilities: [PeekabooBridgeClientCapability.desktopObservationTargetChangeDiagnostics]),
            peer: peer,
            permissions: Self.permissions)
        let data = await server.handleDecoded(Self.request(priorMutation: false, projected: false), peer: peer)
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
        #expect(Self.error(in: response)?.desktopObservationTargetChangeDiagnostic == nil)
        let old = try JSONDecoder.peekabooBridgeDecoder().decode(OldResponse.self, from: data)
        #expect(try PeekabooBridgeOperationReceiptCoding.canonicalData(old) ==
            PeekabooBridgeOperationReceiptCoding.canonicalData(response))
    }

    private static let targetDiagnostic = DesktopObservationTargetChangeDiagnostic(
        classification: .captureReceiptMismatch, phase: .afterCapture, passiveRecovery: .exhausted)

    private static func offers(_ offer: String) -> [String]? {
        switch offer {
        case "typed": [PeekabooBridgeClientCapability.screenCaptureKitOwnershipDiagnostics]
        case "unknown": ["futureUnknownDiagnosticFormat"]
        default: nil
        }
    }

    private static let permissions = PermissionsStatus(
        screenRecording: true, accessibility: true, appleScript: false, postEvent: false)

    private static let diagnostic = ScreenCaptureKitOwnershipDiagnostic.capturing(
        ScreenCaptureKitOwnerLease.LeaseError.uncoordinatedProcesses([
            .init(processIdentifier: 4242, processStartIdentity: 9001, executablePath: "/synthetic/first"),
            .init(processIdentifier: 4343, processStartIdentity: 9002, executablePath: "/synthetic/second"),
        ]), stage: .entry)

    private struct Fixture {
        let server: PeekabooBridgeServer
        let authority: PeekabooBridgeOperationReceiptAuthority
        let session: OperationReceiptSessionFixture
    }

    private static func fixture(
        offers: [String]?,
        version: PeekabooBridgeProtocolVersion = PeekabooBridgeConstants.protocolVersion,
        priorMutation: Bool = false,
        targetChange: Bool = false) async throws -> Fixture
    {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("wire-\(UUID().uuidString).sock")
        let authority = try PeekabooBridgeOperationReceiptAuthority(socketPath: socket.path)
        let peer = try OperationReceiptSessionFixture.currentPeer(
            codeSignatureHash: "synthetic-client")
        let observation: any DesktopObservationServiceProtocol = targetChange
            ? TargetChangeObservation(diagnostic: Self.targetDiagnostic, priorMutation: priorMutation)
            : LateBlockerObservation(diagnostic: Self.diagnostic, priorMutation: priorMutation)
        let server = CaptureReadinessPublicationTests.server(observation: observation)
        try await server.prepareScreenCaptureKitOwnershipForServing()
        #expect(server.hostCapabilities.contains(PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership))
        let session = try await Self.session(
            server: server,
            authority: authority,
            peer: peer,
            offers: offers,
            version: version)
        return Fixture(server: server, authority: authority, session: session)
    }

    private static func session(
        server: PeekabooBridgeServer,
        authority: PeekabooBridgeOperationReceiptAuthority,
        peer: PeekabooBridgePeer,
        offers: [String]?,
        version: PeekabooBridgeProtocolVersion) async throws -> OperationReceiptSessionFixture
    {
        let clientID = UUID()
        let response = try await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(authority) {
            try await server.handleHandshake(
                .init(
                    protocolVersion: version,
                    client: .init(
                        bundleIdentifier: "synthetic.client",
                        teamIdentifier: nil,
                        processIdentifier: getpid()),
                    operationClientInstanceID: clientID,
                    clientCapabilities: offers),
                peer: peer,
                permissions: Self.permissions)
        }
        guard case let .handshake(handshake) = response else { throw POSIXError(.EINVAL) }
        return try OperationReceiptSessionFixture(
            clientInstanceID: clientID,
            peer: peer,
            attestation: #require(handshake.operationSessionAttestation))
    }

    private static func request(priorMutation: Bool, projected: Bool) -> PeekabooBridgeRequest {
        let request = PeekabooBridgeRequest.desktopObservation(.init(
            target: .screen(index: 0),
            capture: .init(engine: .modern, focus: priorMutation ? .foreground : .background),
            detection: .init(mode: .none)))
        return projected ? .projectedAction(.init(request: request)) : request
    }

    private static func signedResponse(
        _ fixture: Fixture,
        priorMutation: Bool = false,
        projected: Bool = false) async throws -> PeekabooBridgeAttestedOperationResponse
    {
        let request = Self.request(priorMutation: priorMutation, projected: projected)
        let payload = fixture.session.request(authority: fixture.authority, sequence: 0, request: request)
        let data = try await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(fixture.authority) {
            try await fixture.server.handleAttestedOperation(payload, peer: fixture.session.peer)
        }
        guard case let .attestedOperation(response) = try JSONDecoder.peekabooBridgeDecoder()
            .decode(PeekabooBridgeResponse.self, from: data) else { throw POSIXError(.EINVAL) }
        try response.receipt.validateSignature(publicKey: fixture.authority.attestation.publicKey)
        #expect(try PeekabooBridgeOperationReceiptCoding.sha256(response.response) == response.receipt.payload
            .responseSHA256)
        return response
    }

    private static func error(in response: PeekabooBridgeResponse) -> PeekabooBridgeErrorEnvelope? {
        switch response {
        case let .error(envelope): envelope
        case let .projectedAction(projected): self.error(in: projected.response)
        default: nil
        }
    }
}

@MainActor
private struct LateBlockerObservation: DesktopObservationServiceProtocol {
    let diagnostic: ScreenCaptureKitOwnershipDiagnostic
    let priorMutation: Bool

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        if self.priorMutation {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .capturePipeline, mode: .foreground),
                evidence: .completionUnknown,
                message: self.diagnostic.userMessage)
                .preservingScreenCaptureKitDiagnostic(self.diagnostic)
        }
        throw self.diagnostic
    }
}

/// Shipped response vocabulary, deliberately without the new diagnostic field.
private enum OldResponse: Codable {
    case error(OldErrorEnvelope)
    indirect case projectedAction(OldProjectedResponse)
}

private struct OldProjectedResponse: Codable {
    let response: OldResponse
    let outcome: DesktopActionOutcome.Projection?
}

private struct OldErrorEnvelope: Codable {
    let code: PeekabooBridgeErrorCode
    let message: String
    let details: String?
    let permission: PeekabooBridgePermissionKind?
    let kind: PeekabooBridgeErrorKind?
    let context: String?
    let operationMayHaveCompleted: Bool?
    let actionOutcome: DesktopActionOutcome.Projection?
    let actionFailureHint: String?
    let actionFailureCauseDescription: String?
    let actionTargetReceipt: DesktopActionTargetReceipt?
    let actionSelectedLeafEvidence: [DesktopSelectedLeafEvidence]?
}

@MainActor
private struct TargetChangeObservation: DesktopObservationServiceProtocol {
    let diagnostic: DesktopObservationTargetChangeDiagnostic
    var priorMutation = false

    func observe(_: DesktopObservationRequest) async throws -> DesktopObservationResult {
        if self.priorMutation {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .capturePipeline, mode: .foreground),
                evidence: .completionUnknown,
                message: "fixture mutation failure")
                .preservingDesktopObservationTargetChangeDiagnostic(self.diagnostic)
        }
        throw DesktopObservationError.targetChanged("fixture", diagnostic: self.diagnostic)
    }
}
