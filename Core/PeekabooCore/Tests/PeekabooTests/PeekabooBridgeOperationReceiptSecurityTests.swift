import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooBridgeOperationReceiptSecurityTests {
    @Test
    func `handled no-dispatch outcome keeps post-execution attribution failure retry-safe`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let expectedIdentity = ApplicationProcessIdentity(
            processIdentifier: getpid(),
            processStartIdentity: generation)
        let services = await MainActor.run {
            let services = StubServices()
            services.automationStub.actionOutcome = .refused(reason: .targetUnavailable)
            services.automationStub.uiAutomationOutcomeTargetIdentity = try? DesktopTargetIdentity(
                processIdentity: .init(
                    processIdentifier: getpid(),
                    processStartIdentity: generation + 1))
            return services
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
                })
        }
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()

        do {
            let client = PeekabooBridgeClient(socketPath: socketPath)
            _ = try await client.handshake(client: Self.clientIdentity)
            do {
                _ = try await client.clickWithOutcome(
                    target: .elementId("B1"),
                    clickType: .single,
                    snapshotId: "snapshot",
                    expectedProcessIdentity: expectedIdentity)
                Issue.record("Expected contradictory result attribution to be refused")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.retrySafety == .safe)
                #expect(failure.outcome.dispatchState == .none)
            }
            let receipt = try #require(await client.lastOperationReceipt())
            #expect(receipt.payload.targetAttributionFailure?.stage == .postExecution)
            #expect(receipt.payload.outcome?.state == .refused)
            #expect(receipt.payload.outcome?.retrySafe == true)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    @Test
    func `receipt archive rejects permissive directories and symlinks`() throws {
        let permissive = URL(fileURLWithPath: "/tmp/pbor-permissive-\(UUID().uuidString)", isDirectory: true)
        let symlinkURL = URL(fileURLWithPath: "/tmp/pbor-symlink-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: permissive)
            unlink(symlinkURL.path)
        }
        try FileManager.default.createDirectory(at: permissive, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: permissive.path)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try PeekabooBridgePrivateReceiptArchive.prepareDirectory(permissive)
        }

        #expect(symlink("/tmp", symlinkURL.path) == 0)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try PeekabooBridgePrivateReceiptArchive.prepareDirectory(symlinkURL)
        }
    }

    @Test
    func `handshake rejects a signed attestation that contradicts the advertised CDHash`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let attestation = authority.attestation
        let handshake = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.attestedOperationReceiptVersion,
            hostKind: .gui,
            build: "test",
            supportedOperations: [.permissionsStatus],
            permissions: .init(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: [.permissionsStatus],
            hostIdentity: .init(
                processIdentifier: attestation.host.processIdentifier,
                processStartIdentity: attestation.host.processStartIdentity,
                bundleIdentifier: "dev.peekaboo.tests",
                bundleShortVersion: "1",
                bundleVersion: "1",
                codeSignatureHash: "contradictory-cdhash"),
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.desktopActionOutcomeProjection,
            ],
            operationAttestation: attestation)
        let handshakeData = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeResponse.handshake(handshake))
        let peer = try ScriptedBridgePeer(scripts: [[.respondData(handshakeData)]])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)

        do {
            _ = try await client.handshake(client: Self.clientIdentity)
            Issue.record("Expected contradictory host CDHash to be rejected")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .unauthorizedClient)
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `handshake requires outcome projection for protocol 1 29 receipts`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let attestation = authority.attestation
        let handshake = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.attestedOperationReceiptVersion,
            hostKind: .gui,
            build: "test",
            supportedOperations: [.permissionsStatus],
            permissions: .init(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: [.permissionsStatus],
            hostIdentity: .init(
                processIdentifier: attestation.host.processIdentifier,
                processStartIdentity: attestation.host.processStartIdentity,
                bundleIdentifier: "dev.peekaboo.tests",
                bundleShortVersion: "1",
                bundleVersion: "1",
                codeSignatureHash: attestation.host.codeSignatureHash),
            hostCapabilities: [PeekabooBridgeHostCapability.attestedOperationReceipts],
            operationAttestation: attestation)
        let handshakeData = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeResponse.handshake(handshake))
        let peer = try ScriptedBridgePeer(scripts: [[.respondData(handshakeData)]])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)

        do {
            _ = try await client.handshake(client: Self.clientIdentity)
            Issue.record("Expected missing outcome projection to be rejected")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .unauthorizedClient)
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `raw attested mutations require projected outcome carriage`() throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let rawRequest = PeekabooBridgeRequest.requestPostEventPermission
        let rawPayload = PeekabooBridgeAttestedOperationRequest(
            requestID: UUID(),
            expectedListenerInstanceID: authority.attestation.listenerInstanceID,
            client: authority.attestation.host,
            request: rawRequest)

        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try rawPayload.validatedRequest()
        }

        let projectedRequest = PeekabooBridgeRequest.projectedAction(.init(request: rawRequest))
        let projectedPayload = PeekabooBridgeAttestedOperationRequest(
            requestID: UUID(),
            expectedListenerInstanceID: authority.attestation.listenerInstanceID,
            client: authority.attestation.host,
            request: projectedRequest)
        #expect(try projectedPayload.validatedRequest().operation == .requestPostEventPermission)

        let response = PeekabooBridgeResponse.ok
        let now = PeekabooBridgeOperationReceiptCoding.unixMilliseconds()
        let receiptPayload = try PeekabooBridgeOperationReceiptPayload(
            requestID: rawPayload.requestID,
            listenerInstanceID: authority.attestation.listenerInstanceID,
            listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(
                authority.attestation.publicKey),
            host: authority.attestation.host,
            client: authority.attestation.host,
            operation: rawRequest.operation,
            requestSHA256: PeekabooBridgeOperationReceiptCoding.sha256(rawRequest),
            responseSHA256: PeekabooBridgeOperationReceiptCoding.sha256(response),
            target: .global,
            outcome: nil,
            startedAtUnixMilliseconds: now,
            completedAtUnixMilliseconds: now)
        let receipt = try authority.signAndArchive(receiptPayload)
        let bundle = try Self.bundle(
            authority: authority,
            receipt: receipt,
            request: rawRequest,
            response: response)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try bundle.validate()
        }
    }

    @Test
    func `offline bundle validation rejects signed operation semantics that contradict its bytes`() throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let request = PeekabooBridgeRequest.permissionsStatus
        let response = PeekabooBridgeResponse.permissionsStatus(.init(
            screenRecording: true,
            accessibility: true))
        let now = PeekabooBridgeOperationReceiptCoding.unixMilliseconds()
        let payload = try PeekabooBridgeOperationReceiptPayload(
            requestID: UUID(),
            listenerInstanceID: authority.attestation.listenerInstanceID,
            listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(
                authority.attestation.publicKey),
            host: authority.attestation.host,
            client: authority.attestation.host,
            operation: .daemonStatus,
            requestSHA256: PeekabooBridgeOperationReceiptCoding.sha256(request),
            responseSHA256: PeekabooBridgeOperationReceiptCoding.sha256(response),
            target: .global,
            outcome: nil,
            startedAtUnixMilliseconds: now,
            completedAtUnixMilliseconds: now)
        let receipt = try authority.signAndArchive(payload)
        let bundle = try PeekabooBridgeOperationReceiptBundle(
            operationAttestation: authority.attestation,
            receipt: receipt,
            canonicalListenerAttestationPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(
                authority.attestation.unsignedPayload),
            canonicalReceiptPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(receipt.payload),
            canonicalRequest: PeekabooBridgeOperationReceiptCoding.canonicalData(request),
            canonicalResponse: PeekabooBridgeOperationReceiptCoding.canonicalData(response))

        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try bundle.validate()
        }
    }

    @Test
    func `offline bundle validation rejects a signed target that contradicts its request`() throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let expectedIdentity = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 1001)
        let contradictoryIdentity = ApplicationProcessIdentity(
            processIdentifier: 43,
            processStartIdentity: 2002)
        let request = PeekabooBridgeRequest.activateApplication(.init(
            identifier: "dev.peekaboo.fixture",
            expectedIdentity: expectedIdentity))
        let response = PeekabooBridgeResponse.ok
        let now = PeekabooBridgeOperationReceiptCoding.unixMilliseconds()
        let payload = try PeekabooBridgeOperationReceiptPayload(
            requestID: UUID(),
            listenerInstanceID: authority.attestation.listenerInstanceID,
            listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(
                authority.attestation.publicKey),
            host: authority.attestation.host,
            client: authority.attestation.host,
            operation: request.operation,
            requestSHA256: PeekabooBridgeOperationReceiptCoding.sha256(request),
            responseSHA256: PeekabooBridgeOperationReceiptCoding.sha256(response),
            target: .process(contradictoryIdentity),
            outcome: nil,
            startedAtUnixMilliseconds: now,
            completedAtUnixMilliseconds: now)
        let receipt = try authority.signAndArchive(payload)
        let bundle = try PeekabooBridgeOperationReceiptBundle(
            operationAttestation: authority.attestation,
            receipt: receipt,
            canonicalListenerAttestationPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(
                authority.attestation.unsignedPayload),
            canonicalReceiptPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(receipt.payload),
            canonicalRequest: PeekabooBridgeOperationReceiptCoding.canonicalData(request),
            canonicalResponse: PeekabooBridgeOperationReceiptCoding.canonicalData(response))

        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try bundle.validate()
        }
    }

    @Test
    func `offline bundle validation reproduces a claimed attribution failure`() throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let identity = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 1001)
        let request = PeekabooBridgeRequest.activateApplication(.init(
            identifier: "dev.peekaboo.fixture",
            expectedIdentity: identity))
        let failure = PeekabooBridgeTargetAttributionFailure(
            .contradictoryProcessIdentifier,
            stage: .preDispatch)
        let response = PeekabooBridgeResponse.error(.init(
            code: .invalidRequest,
            message: "Forged target attribution failure",
            context: "bridge_target_attribution:\(failure.code.rawValue)"))
        let now = PeekabooBridgeOperationReceiptCoding.unixMilliseconds()
        let payload = try PeekabooBridgeOperationReceiptPayload(
            requestID: UUID(),
            listenerInstanceID: authority.attestation.listenerInstanceID,
            listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(
                authority.attestation.publicKey),
            host: authority.attestation.host,
            client: authority.attestation.host,
            operation: request.operation,
            requestSHA256: PeekabooBridgeOperationReceiptCoding.sha256(request),
            responseSHA256: PeekabooBridgeOperationReceiptCoding.sha256(response),
            target: nil,
            targetAttributionFailure: failure,
            targetAttributionEvidence: request.operationTargetEvidence.map(
                PeekabooBridgeOperationTargetEvidence.init),
            outcome: nil,
            startedAtUnixMilliseconds: now,
            completedAtUnixMilliseconds: now)
        let receipt = try authority.signAndArchive(payload)
        let bundle = try PeekabooBridgeOperationReceiptBundle(
            operationAttestation: authority.attestation,
            receipt: receipt,
            canonicalListenerAttestationPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(
                authority.attestation.unsignedPayload),
            canonicalReceiptPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(receipt.payload),
            canonicalRequest: PeekabooBridgeOperationReceiptCoding.canonicalData(request),
            canonicalResponse: PeekabooBridgeOperationReceiptCoding.canonicalData(response))

        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try bundle.validate()
        }
    }

    @Test
    func `offline validation rejects unpinned success and malformed retry semantics`() throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let now = PeekabooBridgeOperationReceiptCoding.unixMilliseconds()

        let focusRequest = PeekabooBridgeRequest.focusWindow(.init(target: .application("Fixture")))
        let successResponse = PeekabooBridgeResponse.ok
        let successPayload = try PeekabooBridgeOperationReceiptPayload(
            requestID: UUID(),
            listenerInstanceID: authority.attestation.listenerInstanceID,
            listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(
                authority.attestation.publicKey),
            host: authority.attestation.host,
            client: authority.attestation.host,
            operation: focusRequest.operation,
            requestSHA256: PeekabooBridgeOperationReceiptCoding.sha256(focusRequest),
            responseSHA256: PeekabooBridgeOperationReceiptCoding.sha256(successResponse),
            target: .global,
            outcome: nil,
            startedAtUnixMilliseconds: now,
            completedAtUnixMilliseconds: now)
        let successReceipt = try authority.signAndArchive(successPayload)
        let successBundle = try Self.bundle(
            authority: authority,
            receipt: successReceipt,
            request: focusRequest,
            response: successResponse)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try successBundle.validate()
        }

        let mutationRequest = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: 42))
        let failure = PeekabooBridgeTargetAttributionFailure(
            .missingProcessGeneration,
            stage: .preDispatch)
        let malformedResponse = PeekabooBridgeResponse.error(.init(
            code: .invalidRequest,
            message: "Missing retry semantics",
            context: "bridge_target_attribution:\(failure.code.rawValue)"))
        let failurePayload = try PeekabooBridgeOperationReceiptPayload(
            requestID: UUID(),
            listenerInstanceID: authority.attestation.listenerInstanceID,
            listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(
                authority.attestation.publicKey),
            host: authority.attestation.host,
            client: authority.attestation.host,
            operation: mutationRequest.operation,
            requestSHA256: PeekabooBridgeOperationReceiptCoding.sha256(mutationRequest),
            responseSHA256: PeekabooBridgeOperationReceiptCoding.sha256(malformedResponse),
            target: nil,
            targetAttributionFailure: failure,
            targetAttributionEvidence: mutationRequest.operationTargetEvidence.map(
                PeekabooBridgeOperationTargetEvidence.init),
            outcome: nil,
            startedAtUnixMilliseconds: now,
            completedAtUnixMilliseconds: now)
        let failureReceipt = try authority.signAndArchive(failurePayload)
        let failureBundle = try Self.bundle(
            authority: authority,
            receipt: failureReceipt,
            request: mutationRequest,
            response: malformedResponse)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try failureBundle.validate()
        }

        let safeFailure = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .invalidRequest,
            message: "Target attribution was refused")
        let nestedEnvelope = PeekabooBridgeErrorEnvelope(
            code: .invalidRequest,
            actionFailure: safeFailure,
            context: "bridge_target_attribution:\(failure.code.rawValue)")
        let contradictoryProjectedResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .error(nestedEnvelope),
            outcome: DesktopActionOutcome.confirmedChange(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .background)).projection))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try PeekabooBridgeOperationReceiptSemantics.validateTargetAttribution(
                failurePayload,
                request: .projectedAction(.init(request: mutationRequest)),
                response: contradictoryProjectedResponse)
        }
    }

    @Test
    func `request evidence preserves focused process and activation generations`() throws {
        let identity = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 9_007_199_254_740_993)
        let focused = PeekabooBridgeRequest.getFocusedElement(.init(
            targetProcessIdentifier: identity.processIdentifier,
            expectedProcessIdentity: identity))
        let activate = PeekabooBridgeRequest.activateApplication(.init(
            identifier: "dev.peekaboo.fixture",
            expectedIdentity: identity))
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let windowIdentity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: identity.processIdentifier,
            ownerProcessStartIdentity: identity.processStartIdentity,
            capturedBounds: bounds)
        let focus = PeekabooBridgeRequest.focusWindow(.init(
            target: .windowId(windowIdentity.windowID),
            expectedIdentity: windowIdentity))

        #expect(try PeekabooBridgeOperationTargetAttribution.resolveRequest(focused)?.processIdentity == identity)
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveRequest(activate)?.processIdentity == identity)
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveRequest(focus)?.exactWindow?.identity ==
            windowIdentity)
        let wireEvidence = PeekabooBridgeOperationTargetEvidence(.init(processIdentity: identity))
        let encodedEvidence = try PeekabooBridgeOperationReceiptCoding.canonicalData(wireEvidence)
        let encodedEvidenceString = try #require(String(data: encodedEvidence, encoding: .utf8))
        #expect(encodedEvidenceString.contains("\"9007199254740993\""))
        #expect(try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeOperationTargetEvidence.self,
            from: encodedEvidence) == wireEvidence)
        #expect(throws: DesktopTargetIdentityError.missingProcessGeneration) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveRequest(.getFocusedElement(.init(
                targetProcessIdentifier: identity.processIdentifier)))
        }
        #expect(throws: DesktopTargetIdentityError.missingProcessGeneration) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveRequest(.focusWindow(.init(
                target: .windowId(windowIdentity.windowID))))
        }
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveRequest(.focusWindow(.init(
                target: .application("Fixture"))))
        }
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: .focusWindow(.init(target: .application("Fixture"))),
                response: .ok)
        }
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: .click(.init(
                    target: .elementId("B1"),
                    clickType: .single,
                    snapshotId: nil)),
                response: .ok)
        }
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: .type(.init(
                    text: "x",
                    target: "B1",
                    clearExisting: false,
                    typingDelay: 0,
                    snapshotId: nil)),
                response: .ok)
        }
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: .targetedScroll(.init(request: .init(
                    direction: .down,
                    amount: 1,
                    target: "S1",
                    snapshotId: "snapshot"))),
                response: .ok)
        }
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: .setValue(.init(target: "S1", value: .string("x"), snapshotId: "snapshot")),
                response: .elementActionResult(.init(target: "S1", actionName: nil, anchorPoint: nil)))
        }
    }

    private static var clientIdentity: PeekabooBridgeClientIdentity {
        PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.receipt-security-tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil)
    }

    private static func bundle(
        authority: PeekabooBridgeOperationReceiptAuthority,
        receipt: PeekabooBridgeOperationReceipt,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse) throws -> PeekabooBridgeOperationReceiptBundle
    {
        try PeekabooBridgeOperationReceiptBundle(
            operationAttestation: authority.attestation,
            receipt: receipt,
            canonicalListenerAttestationPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(
                authority.attestation.unsignedPayload),
            canonicalReceiptPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(receipt.payload),
            canonicalRequest: PeekabooBridgeOperationReceiptCoding.canonicalData(request),
            canonicalResponse: PeekabooBridgeOperationReceiptCoding.canonicalData(response))
    }
}
