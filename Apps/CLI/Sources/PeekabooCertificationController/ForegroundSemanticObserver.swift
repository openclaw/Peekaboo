import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridge

actor LiveForegroundSemanticObserver {
    private static let protocolVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 30)

    private let plan: CertificationObserveOnlyPlan
    private let client: PeekabooBridgeClient
    private let process: CertificationProcessReceipt
    private let build: CertificationControllerBuildReceipt
    private var listener: PeekabooBridgeListenerAttestation?
    private var session: PeekabooBridgeOperationSessionAttestation?
    private var sequence: UInt64 = 0
    private var baselineFocusIdentity: FocusedElementIdentity?

    init(plan: CertificationObserveOnlyPlan) throws {
        guard let clientInstanceID = plan.clientUUID else {
            throw CertificationControllerError.invalidPlan("Observe-only client_instance_id is invalid.")
        }
        let authenticated = try CertificationControllerBuildIdentityResolver.current(
            expectedTeamID: plan.expectedControllerBuild.teamID
        )
        try plan.expectedControllerBuild.requireMatches(authenticated.build)
        self.plan = plan
        self.process = authenticated.process
        self.build = authenticated.build
        self.client = PeekabooBridgeClient(
            socketPath: plan.socketPath,
            operationClientInstanceID: clientInstanceID,
            trustedHostTeamIDs: Set(plan.trustedBridgeHostTeamIDs)
        )
    }

    func connect() async throws {
        guard self.listener == nil, self.session == nil else {
            throw CertificationControllerError.runtimeRefusal("Observe-only handshake may run only once.")
        }
        let response = try await self.client.handshake(
            client: PeekabooBridgeClientIdentity(
                bundleIdentifier: Bundle.main.bundleIdentifier,
                teamIdentifier: self.build.teamID,
                processIdentifier: self.process.pid,
                hostname: Host.current().name
            ),
            requestedHost: self.plan.expectedHost.hostKind,
            protocolVersion: Self.protocolVersion
        )
        guard response.negotiatedVersion == Self.protocolVersion,
              response.hostKind == self.plan.expectedHost.hostKind,
              response.supportedOperations.contains(.getFocusedElement),
              response.enabledOperations?.contains(.getFocusedElement) == true,
              response.hostCapabilities?.contains("attestedOperationReceipts") == true,
              response.hostCapabilities?.contains("codeSignatureBuildIdentity") == true,
              let host = response.hostIdentity,
              host.processIdentifier == self.plan.expectedHost.processIdentifier,
              host.processStartIdentity == self.plan.expectedHost.processStartIdentity,
              host.processStartIdentityDecimal == self.plan.expectedHost.processStartIdentityDecimal,
              host.codeSignatureHash == self.plan.expectedHost.codeSignatureHash,
              host.sourceCommit == self.plan.expectedHost.sourceCommit,
              let listener = response.operationAttestation,
              let session = response.operationSessionAttestation,
              listener.host.processIdentifier == host.processIdentifier,
              listener.host.processStartIdentity == host.processStartIdentity,
              listener.host.codeSignatureHash == host.codeSignatureHash,
              session.listenerInstanceID == listener.listenerInstanceID,
              session.clientInstanceID.uuidString.lowercased() == self.plan.clientInstanceID,
              session.client.processIdentifier == self.process.pid,
              String(session.client.processStartIdentity) == self.process.startIdentity,
              session.client.codeSignatureHash == self.process.codeSignatureHash,
              session.remainingClaimCount > 3,
              session.maximumRequestCount > 3
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Observe-only Bridge handshake is not the exact source/session in the plan."
            )
        }
        try listener.validateSignature()
        try session.validateSignature(listenerAttestation: listener)
        self.listener = listener
        self.session = session
    }

    func readSemanticValue() async throws -> String {
        guard let listener = self.listener,
              let session = self.session,
              let processStartIdentity = self.plan.target.processStartIdentity,
              self.sequence < 3
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Observe-only Bridge session is unavailable or exhausted."
            )
        }
        try self.preflightTarget(processStartIdentity: processStartIdentity)
        let focus = try await self.client.getFocusedElement(
            targetProcessIdentifier: self.plan.target.pid
        )
        let value = try CertificationSemanticReadback.value(from: focus, plan: self.plan)
        guard let focus,
              let focusIdentity = FocusedElementIdentity(focus),
              self.baselineFocusIdentity == nil || self.baselineFocusIdentity == focusIdentity
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Foreground semantic element identity changed between fresh readbacks."
            )
        }
        if self.baselineFocusIdentity == nil {
            self.baselineFocusIdentity = focusIdentity
        }
        try self.preflightTarget(processStartIdentity: processStartIdentity)
        guard let bundle = await self.client.lastOperationReceiptBundle() else {
            throw CertificationControllerError.runtimeRefusal(
                "Foreground semantic readback returned without a signed Bridge bundle."
            )
        }
        try bundle.validate(trustAnchor: .listenerAttestation(listener))
        let payload = bundle.receipt.payload
        guard bundle.operationAttestation == listener,
              bundle.operationSessionAttestation == session,
              payload.listenerInstanceID == listener.listenerInstanceID,
              payload.sessionID == session.sessionID,
              payload.sessionSequence.value == self.sequence,
              payload.client.processIdentifier == self.process.pid,
              String(payload.client.processStartIdentity) == self.process.startIdentity,
              payload.client.codeSignatureHash == self.process.codeSignatureHash,
              payload.operation == .getFocusedElement,
              payload.outcome == nil,
              case let .process(receiptTarget) = payload.target,
              receiptTarget.processIdentifier == self.plan.target.pid,
              receiptTarget.processStartIdentity == processStartIdentity
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Foreground semantic readback receipt changed session, client, or target."
            )
        }
        try self.validateCanonicalRequest(bundle.canonicalRequest, payload: payload)
        try self.validateCanonicalResponse(bundle.canonicalResponse, focus: focus)
        self.sequence += 1
        return value
    }

    func processReceipt() -> CertificationProcessReceipt {
        self.process
    }

    func buildReceipt() -> CertificationControllerBuildReceipt {
        self.build
    }

    func focusedElementReceipt() throws -> CertificationFocusedElementReceipt {
        guard let baselineFocusIdentity else {
            throw CertificationControllerError.runtimeRefusal(
                "Foreground semantic baseline element identity is unavailable."
            )
        }
        return CertificationFocusedElementReceipt(
            identity: baselineFocusIdentity,
            semanticElement: self.plan.semanticElement
        )
    }

    private func preflightTarget(processStartIdentity: UInt64) throws {
        guard SystemIdentityResolver.processStartIdentity(self.plan.target.pid) == processStartIdentity,
              let live = SystemIdentityResolver.windowMutationIdentity(
                  windowID: CGWindowID(self.plan.target.windowID)
              ),
              live.ownerProcessIdentifier == self.plan.target.pid,
              live.ownerProcessStartIdentity == processStartIdentity,
              live.capturedBounds == self.plan.target.bounds.cgRect
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Foreground exact-window process generation or bounds changed before readback."
            )
        }
    }

    private func validateCanonicalRequest(
        _ data: Data,
        payload: PeekabooBridgeOperationReceiptPayload
    ) throws {
        let outer = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: data)
        guard case let .attestedOperation(attested) = outer,
              attested.requestID == payload.requestID,
              attested.sessionID == payload.sessionID,
              attested.sessionSequence == payload.sessionSequence,
              case let .getFocusedElement(request) = attested.request,
              request.targetProcessIdentifier == self.plan.target.pid,
              request.expectedProcessIdentity?.processIdentifier == self.plan.target.pid,
              request.expectedProcessIdentity?.processStartIdentity == self.plan.target.processStartIdentity
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Foreground semantic canonical request is not process-generation pinned."
            )
        }
    }

    private func validateCanonicalResponse(_ data: Data, focus: UIFocusInfo) throws {
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
        guard case let .focusedElement(signedFocus) = response,
              let signedFocus
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Foreground semantic signed response differs from the fresh Accessibility value."
            )
        }
        let signedData = try JSONEncoder.peekabooBridgeEncoder().encode(signedFocus)
        let localData = try JSONEncoder.peekabooBridgeEncoder().encode(focus)
        guard signedData == localData else {
            throw CertificationControllerError.runtimeRefusal(
                "Foreground semantic signed response differs from the fresh Accessibility value."
            )
        }
    }
}

enum CertificationSemanticReadback {
    static func value(from focus: UIFocusInfo?, plan: CertificationObserveOnlyPlan) throws -> String {
        guard let focus,
              focus.processId == Int(plan.target.pid),
              focus.windowID == plan.target.windowID,
              focus.role == plan.semanticElement.role,
              plan.semanticElement.identifier == nil || focus.identifier == plan.semanticElement.identifier,
              plan.semanticElement.title == nil || focus.title == plan.semanticElement.title,
              plan.target.bounds.cgRect.contains(CGPoint(x: focus.frame.midX, y: focus.frame.midY)),
              let value = focus.value
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Fresh Accessibility readback does not match the exact foreground semantic target."
            )
        }
        return value
    }
}
