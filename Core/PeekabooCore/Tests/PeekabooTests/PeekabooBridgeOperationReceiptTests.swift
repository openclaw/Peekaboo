import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooBridgeOperationReceiptTests {
    @Test
    func `concurrent atomic receipt writes use unique temporary paths`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writerCount = 16
        let barrier = ReceiptWriteBarrier(parties: writerCount)
        let payload = Data(repeating: 0xA5, count: 4 * 1024 * 1024)
        try PeekabooBridgePrivateReceiptArchive.prepareDirectory(root)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<writerCount {
                group.addTask {
                    await barrier.wait()
                    let destination = root.appendingPathComponent("receipt-\(index).json")
                    try PeekabooBridgePrivateReceiptArchive.writeAtomically(payload, to: destination)
                }
            }
            try await group.waitForAll()
        }

        for index in 0..<writerCount {
            let destination = root.appendingPathComponent("receipt-\(index).json")
            #expect(try Data(contentsOf: destination) == payload)
        }
        let artifacts = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(artifacts.filter { $0.hasSuffix(".tmp") }.isEmpty)

        let fixedNonce = try #require(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let first = PeekabooBridgePrivateReceiptArchive.temporaryURL(
            for: root.appendingPathComponent("first.json"),
            nonce: fixedNonce)
        let second = PeekabooBridgePrivateReceiptArchive.temporaryURL(
            for: root.appendingPathComponent("second.json"),
            nonce: fixedNonce)
        #expect(first != second)
        #expect(first.lastPathComponent == ".first.json.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.tmp")
        #expect(second.lastPathComponent == ".second.json.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.tmp")
    }

    @Test
    func `listener signs archives and exports independently verifiable operation bundles`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        let exportDirectory = root.appendingPathComponent("client-export", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: true,
                        accessibility: true,
                        postEvent: true)
                })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()

        do {
            let client = PeekabooBridgeClient(
                socketPath: socketPath,
                requestTimeoutSec: 2,
                operationReceiptExportDirectory: exportDirectory)
            let handshake = try await client.handshake(client: Self.clientIdentity)
            let attestation = try #require(handshake.operationAttestation)

            #expect(handshake.negotiatedVersion == PeekabooBridgeConstants.attestedOperationReceiptVersion)
            #expect(handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.attestedOperationReceipts) == true)
            try attestation.validateSignature()
            #expect(attestation.host.processIdentifier == getpid())
            #expect(attestation.host.processStartIdentity == SystemIdentityResolver.processStartIdentity(getpid()))

            let response = try await client.send(.permissionsStatus)
            guard case .permissionsStatus = response else {
                Issue.record("Expected permissions response, got \(response)")
                await host.stop()
                return
            }

            let bundle = try #require(await client.lastOperationReceiptBundle())
            try bundle.validate()
            let receipt = bundle.receipt
            #expect(receipt.payload.listenerInstanceID == attestation.listenerInstanceID)
            #expect(receipt.payload.host == attestation.host)
            #expect(receipt.payload.client.processIdentifier == getpid())
            #expect(receipt.payload.operation == .permissionsStatus)
            #expect(receipt.payload.target == .global)
            #expect(receipt.payload.outcome == nil)
            #expect(receipt.payload.requestSHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                bundle.canonicalRequest))
            #expect(receipt.payload.responseSHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                bundle.canonicalResponse))

            let fileName = receipt.payload.requestID.uuidString.lowercased() + ".json"
            let hostArchive = URL(fileURLWithPath: attestation.receiptArchiveDirectory)
                .appendingPathComponent(fileName)
            let clientExport = exportDirectory.appendingPathComponent(fileName)
            let archivedReceipt = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeOperationReceipt.self,
                from: Data(contentsOf: hostArchive))
            let exportedBundle = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeOperationReceiptBundle.self,
                from: Data(contentsOf: clientExport))
            #expect(archivedReceipt == receipt)
            #expect(exportedBundle == bundle)
            try exportedBundle.validate()
            Self.expectPrivateFile(hostArchive.path)
            Self.expectPrivateFile(clientExport.path)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    @Test
    func `listener identity rotates across socket lifetimes`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])

        try await host.startChecked()
        let first = try await PeekabooBridgeClient(socketPath: socketPath)
            .handshake(client: Self.clientIdentity)
            .operationAttestation
        _ = await host.stop()

        try await host.startChecked()
        let second = try await PeekabooBridgeClient(socketPath: socketPath)
            .handshake(client: Self.clientIdentity)
            .operationAttestation
        _ = await host.stop()

        #expect(first?.listenerInstanceID != second?.listenerInstanceID)
        #expect(first?.publicKey != second?.publicKey)
    }

    @Test
    func `mutating receipt carries canonical outcome and generation pinned target`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let expectedOutcome = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .background))
        let services = await MainActor.run {
            let services = StubServices()
            services.automationStub.actionOutcome = expectedOutcome
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
            let processIdentity = try ApplicationProcessIdentity(
                processIdentifier: getpid(),
                processStartIdentity: #require(SystemIdentityResolver.processStartIdentity(getpid())))
            let result = try await client.clickWithOutcome(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                expectedProcessIdentity: processIdentity)
            #expect(result.outcome == expectedOutcome.routed(to: .bridge))

            let receipt = try #require(await client.lastOperationReceipt())
            #expect(receipt.payload.operation == .targetedClick)
            #expect(receipt.payload.target == .process(processIdentity))
            #expect(receipt.payload.outcome == expectedOutcome.routed(to: .bridge).projection)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    @Test
    func `listener rejects replay and mismatched client generations before routing`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-replay-\(UUID().uuidString)",
            isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(socketPath: socketPath)
        let generation = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let codeSignatureHash = try #require(PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(
            processIdentifier: getpid()))
        let peer = PeekabooBridgePeer(
            processIdentifier: getpid(),
            processStartIdentity: generation,
            codeSignatureHash: codeSignatureHash,
            userIdentifier: getuid(),
            bundleIdentifier: nil,
            teamIdentifier: nil)
        let payload = PeekabooBridgeAttestedOperationRequest(
            requestID: UUID(),
            expectedListenerInstanceID: authority.attestation.listenerInstanceID,
            client: .init(
                processIdentifier: getpid(),
                processStartIdentity: generation,
                codeSignatureHash: codeSignatureHash),
            request: .permissionsStatus)

        try authority.claim(payload, peer: peer)
        #expect(throws: PeekabooBridgeOperationReceiptError.replayedRequest) {
            try authority.claim(payload, peer: peer)
        }

        let mismatched = PeekabooBridgeAttestedOperationRequest(
            requestID: UUID(),
            expectedListenerInstanceID: authority.attestation.listenerInstanceID,
            client: .init(
                processIdentifier: getpid(),
                processStartIdentity: generation + 1,
                codeSignatureHash: codeSignatureHash),
            request: .permissionsStatus)
        #expect(throws: PeekabooBridgeOperationReceiptError.clientIdentityMismatch) {
            try authority.claim(mismatched, peer: peer)
        }

        let nested = PeekabooBridgeAttestedOperationRequest(
            requestID: UUID(),
            expectedListenerInstanceID: authority.attestation.listenerInstanceID,
            client: payload.client,
            request: .projectedAction(.init(request: .attestedOperation(payload))))
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try nested.validatedRequest()
        }
    }

    @Test
    func `lost attested mutation response is retry unsafe and names its request`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let attestation = authority.attestation
        let handshake = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.attestedOperationReceiptVersion,
            hostKind: .gui,
            build: "test",
            supportedOperations: [.permissionsStatus, .requestPostEventPermission],
            permissions: .init(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: [.permissionsStatus, .requestPostEventPermission],
            hostIdentity: .init(
                processIdentifier: attestation.host.processIdentifier,
                processStartIdentity: attestation.host.processStartIdentity,
                bundleIdentifier: "dev.peekaboo.tests",
                bundleShortVersion: "1",
                bundleVersion: "1",
                codeSignatureHash: attestation.host.codeSignatureHash),
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.desktopActionOutcomeProjection,
            ],
            operationAttestation: attestation)
        let handshakeData = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeResponse.handshake(handshake))
        let peer = try ScriptedBridgePeer(scripts: [
            [.respondData(handshakeData)],
            [.close],
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        _ = try await client.handshake(client: Self.clientIdentity)

        do {
            try await client.sendExpectOK(.requestPostEventPermission)
            Issue.record("Expected the attested mutation response to be lost")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .responseLost)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.message.contains("request_id="))
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `tampering with signed receipt facts or exported bytes fails validation`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-tamper-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let response = PeekabooBridgeResponse.permissionsStatus(.init(
            screenRecording: true,
            accessibility: true))
        let request = PeekabooBridgeRequest.permissionsStatus
        let now = PeekabooBridgeOperationReceiptCoding.unixMilliseconds()
        let largeIdentity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9_007_199_254_740_993,
            capturedBounds: CGRect(x: 10, y: 20, width: 300, height: 200))
        let payload = try PeekabooBridgeOperationReceiptPayload(
            requestID: UUID(),
            listenerInstanceID: authority.attestation.listenerInstanceID,
            listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(
                authority.attestation.publicKey),
            host: authority.attestation.host,
            client: authority.attestation.host,
            operation: .permissionsStatus,
            requestSHA256: PeekabooBridgeOperationReceiptCoding.sha256(request),
            responseSHA256: PeekabooBridgeOperationReceiptCoding.sha256(response),
            target: .window(largeIdentity),
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
        try bundle.validate()

        let corrupted = PeekabooBridgeOperationReceiptBundle(
            operationAttestation: authority.attestation,
            receipt: receipt,
            canonicalListenerAttestationPayload: bundle.canonicalListenerAttestationPayload,
            canonicalReceiptPayload: bundle.canonicalReceiptPayload,
            canonicalRequest: Data("different request".utf8),
            canonicalResponse: bundle.canonicalResponse)
        #expect(throws: (any Error).self) {
            try corrupted.validate()
        }

        let encodedTarget = try PeekabooBridgeOperationReceiptCoding.canonicalData(payload.target)
        let targetObject = try #require(JSONSerialization.jsonObject(with: encodedTarget) as? [String: Any])
        #expect(targetObject["processStartIdentity"] as? String == "9007199254740993")
        #expect(try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeOperationTargetReceipt.self,
            from: encodedTarget) == .window(largeIdentity))

        let numericIdentity = Data(
            #"{"kind":"process","processIdentifier":42,"processStartIdentity":9007199254740993}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeOperationTargetReceipt.self,
                from: numericIdentity)
        }
        let noncanonicalIdentity = Data(
            #"{"kind":"process","processIdentifier":42,"processStartIdentity":"09007199254740993"}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeOperationTargetReceipt.self,
                from: noncanonicalIdentity)
        }
    }

    @Test
    func `observation and capture receipts use resolved stable targets without widening`() {
        let bounds = CGRect(x: 20, y: 30, width: 640, height: 480)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9_007_199_254_740_993,
            capturedBounds: bounds)
        let app = ApplicationIdentity(
            processIdentifier: 42,
            processStartIdentity: identity.ownerProcessStartIdentity,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "Fixture")
        let context = WindowContext(
            applicationName: "Fixture",
            applicationBundleId: "dev.peekaboo.fixture",
            applicationProcessId: 42,
            windowTitle: "Fixture",
            windowID: 73,
            windowBounds: bounds,
            windowMutationIdentity: identity)
        let resolved = ResolvedObservationTarget(
            kind: .windowID(73),
            app: app,
            window: .init(windowID: 73, title: "Fixture", bounds: bounds, index: 0),
            bounds: bounds,
            detectionContext: context)
        let capture = CaptureResult(
            imageData: Data(),
            metadata: .init(size: bounds.size, mode: .window))
        let observation = DesktopObservationResult(target: resolved, capture: capture, elements: nil)
        let request = PeekabooBridgeRequest.desktopObservation(.init(target: .windowID(73)))

        #expect(request.operationTargetReceipt(resolvedFrom: .desktopObservation(observation)) == .window(identity))

        let windowInfo = ServiceWindowInfo(
            windowID: 73,
            title: "Fixture",
            bounds: bounds,
            mutationIdentity: identity)
        let applicationInfo = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: identity.ownerProcessStartIdentity,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "Fixture")
        let exactCapture = CaptureResult(
            imageData: Data(),
            metadata: .init(
                size: bounds.size,
                mode: .window,
                applicationInfo: applicationInfo,
                windowInfo: windowInfo))
        #expect(request.operationTargetReceipt(resolvedFrom: .capture(exactCapture)) == .window(identity))

        let contradictoryCapture = CaptureResult(
            imageData: Data(),
            metadata: .init(
                size: bounds.size,
                mode: .window,
                applicationInfo: .init(
                    processIdentifier: 42,
                    processStartIdentity: identity.ownerProcessStartIdentity + 1,
                    bundleIdentifier: "dev.peekaboo.fixture",
                    name: "Fixture"),
                windowInfo: windowInfo))
        #expect(request.operationTargetReceipt(resolvedFrom: .capture(contradictoryCapture)) == .global)

        let processOnly = DesktopObservationResult(
            target: .init(kind: .appWindow, app: app),
            capture: capture,
            elements: nil)
        #expect(request.operationTargetReceipt(resolvedFrom: .desktopObservation(processOnly)) == .process(
            .init(processIdentifier: 42, processStartIdentity: identity.ownerProcessStartIdentity)))

        let incompleteIdentity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: identity.ownerProcessStartIdentity,
            capturedBounds: nil)
        let incompleteContext = WindowContext(
            applicationProcessId: 42,
            windowID: 73,
            windowBounds: bounds,
            windowMutationIdentity: incompleteIdentity)
        let unresolved = DesktopObservationResult(
            target: .init(
                kind: .windowID(73),
                app: .init(
                    processIdentifier: 42,
                    processStartIdentity: nil,
                    bundleIdentifier: nil,
                    name: "Fixture"),
                detectionContext: incompleteContext),
            capture: capture,
            elements: nil)
        #expect(request.operationTargetReceipt(resolvedFrom: .desktopObservation(unresolved)) == .global)

        let detection = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/fixture.png",
            elements: DetectedElements(),
            metadata: .init(
                detectionTime: 0,
                elementCount: 0,
                method: "fixture",
                windowContext: context))
        let detectRequest = PeekabooBridgeRequest.detectElements(.init(
            imageData: Data(),
            snapshotId: "snapshot",
            windowContext: context))
        #expect(detectRequest.operationTargetReceipt(resolvedFrom: .elementDetection(detection)) == .global)
        let inspectRequest = PeekabooBridgeRequest.inspectAccessibilityTree(.init(windowContext: context))
        #expect(inspectRequest.operationTargetReceipt(resolvedFrom: .elementDetection(detection)) == .window(identity))
    }

    private static var clientIdentity: PeekabooBridgeClientIdentity {
        PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.receipt-tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil)
    }

    private static func expectPrivateFile(_ path: String) {
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFREG)
        #expect(info.st_uid == geteuid())
        #expect(info.st_mode & 0o777 == 0o600)
    }
}

private actor ReceiptWriteBarrier {
    private let parties: Int
    private var waiting = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(parties: Int) {
        self.parties = parties
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.waiting += 1
            guard self.waiting == self.parties else {
                self.continuations.append(continuation)
                return
            }
            let continuations = self.continuations
            self.continuations.removeAll()
            continuations.forEach { $0.resume() }
            continuation.resume()
        }
    }
}
