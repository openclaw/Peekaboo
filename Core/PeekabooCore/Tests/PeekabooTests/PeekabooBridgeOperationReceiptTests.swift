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
    func `concurrent private directory creator revalidates the winning entry`() throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var injectedRace = false

        try PeekabooBridgePrivateReceiptArchive.prepareDirectory(root) { path, mode in
            #expect(!injectedRace)
            injectedRace = true
            #expect(mkdir(path, mode) == 0)
            errno = EEXIST
            return -1
        }

        #expect(injectedRace)
        var info = stat()
        #expect(lstat(root.path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFDIR)
        #expect(info.st_uid == geteuid())
        #expect(info.st_mode & 0o077 == 0)
    }

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
            let hostAttestation = URL(fileURLWithPath: attestation.receiptArchiveDirectory)
                .appendingPathComponent("attestation.json")
            let clientExport = exportDirectory.appendingPathComponent(fileName)
            let archivedReceipt = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeOperationReceipt.self,
                from: Data(contentsOf: hostArchive))
            let exportedBundle = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeOperationReceiptBundle.self,
                from: Data(contentsOf: clientExport))
            let archivedAttestation = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeListenerAttestation.self,
                from: Data(contentsOf: hostAttestation))
            #expect(archivedReceipt == receipt)
            #expect(archivedAttestation == attestation)
            #expect(exportedBundle == bundle)
            try archivedAttestation.validateSignature()
            try exportedBundle.validate()
            Self.expectPrivateDirectory(attestation.receiptArchiveDirectory)
            Self.expectPrivateFile(hostArchive.path)
            Self.expectPrivateFile(hostAttestation.path)
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
            #expect(result.targetIdentity?.processIdentity == processIdentity)

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
    func `targeted scroll receipt carries the executor owned exact target`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: generation,
            capturedBounds: bounds)
        let exactWindow = try UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
        let services = await MainActor.run {
            let services = StubServices()
            services.automationStub.actionOutcome = .confirmedChange(
                delivery: .init(mechanism: .accessibilityAction, mode: .background))
            services.automationStub.uiAutomationOutcomeTargetIdentity = DesktopTargetIdentity(
                exactWindow: exactWindow)
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
            let result = try await client.scrollWithOutcome(.init(
                direction: .down,
                amount: 1,
                target: "S1",
                snapshotId: "snapshot"))
            #expect(result.targetIdentity?.exactWindow?.identity == identity)
            let receipt = try #require(await client.lastOperationReceipt())
            #expect(receipt.payload.operation == .targetedScroll)
            #expect(receipt.payload.target == .window(identity))
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    @Test
    func `incomplete request attribution is archived as retry safe refusal before dispatch`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let services = await MainActor.run { StubServices() }
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
                    targetProcessIdentifier: 999_999)
                Issue.record("Expected incomplete process attribution to be refused")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.retrySafety == .safe)
                #expect(failure.outcome.dispatchState == .none)
            }
            let receipt = try #require(await client.lastOperationReceipt())
            #expect(receipt.payload.target == nil)
            #expect(receipt.payload.targetAttributionFailure?.code == .missingProcessGeneration)
            #expect(receipt.payload.targetAttributionFailure?.stage == .preDispatch)
            #expect(receipt.payload.targetAttributionEvidence?.count == 1)
            #expect(receipt.payload.outcome?.state == .refused)
            #expect(await MainActor.run { services.automationStub.lastProcessTargetedClick == nil })
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    @Test
    func `post dispatch target contradiction is archived as retry unsafe indeterminate`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let expectedIdentity = ApplicationProcessIdentity(
            processIdentifier: getpid(),
            processStartIdentity: generation)
        let services = await MainActor.run {
            let services = StubServices()
            services.automationStub.actionOutcome = .confirmedChange(
                delivery: .init(mechanism: .accessibilityAction, mode: .background))
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
                Issue.record("Expected contradictory result attribution to become indeterminate")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .indeterminate)
                #expect(failure.outcome.retrySafety == .unsafe)
                #expect(failure.outcome.dispatchState.mutationDispatched)
            }
            let receipt = try #require(await client.lastOperationReceipt())
            #expect(receipt.payload.target == nil)
            #expect(receipt.payload.targetAttributionFailure?.code == .contradictoryProcessGeneration)
            #expect(receipt.payload.targetAttributionFailure?.stage == .postExecution)
            #expect(receipt.payload.targetAttributionEvidence?.count == 2)
            #expect(receipt.payload.outcome?.state == .indeterminate)
            #expect(await MainActor.run { services.automationStub.lastProcessTargetedClick != nil })
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
            auditTokenProcessIdentifierVersion: 1,
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

        let unboundPeer = PeekabooBridgePeer(
            processIdentifier: getpid(),
            processStartIdentity: generation,
            codeSignatureHash: codeSignatureHash,
            userIdentifier: getuid(),
            bundleIdentifier: nil,
            teamIdentifier: nil)
        #expect(throws: PeekabooBridgeOperationReceiptError.peerIdentityMismatch) {
            try authority.claim(PeekabooBridgeAttestedOperationRequest(
                requestID: UUID(),
                expectedListenerInstanceID: authority.attestation.listenerInstanceID,
                client: payload.client,
                request: .permissionsStatus), peer: unboundPeer)
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
    func `observation and capture receipts use resolved stable targets without widening`() throws {
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

        #expect(try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: request,
            response: .desktopObservation(observation)).target == .window(identity))

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
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: request,
            response: .capture(exactCapture)).target == .window(identity))

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
        #expect(throws: DesktopTargetIdentityError.contradictoryProcessGeneration) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: request,
                response: .capture(contradictoryCapture))
        }

        let processOnly = DesktopObservationResult(
            target: .init(kind: .appWindow, app: app),
            capture: capture,
            elements: nil)
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: request,
                response: .desktopObservation(processOnly))
        }
        let differentIdentity = WindowMutationIdentity(
            windowID: 74,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: identity.ownerProcessStartIdentity,
            capturedBounds: bounds)
        let differentTarget = try DesktopTargetIdentity(exactWindow: .init(
            identity: differentIdentity,
            bounds: bounds))
        #expect(throws: DesktopTargetIdentityError.contradictoryWindowIdentifier) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: request,
                response: .desktopObservation(processOnly),
                handledTarget: differentTarget)
        }

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
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: request,
                response: .desktopObservation(unresolved))
        }

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
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: detectRequest,
            response: .elementDetection(detection)).target == .global)
        let inspectRequest = PeekabooBridgeRequest.inspectAccessibilityTree(.init(windowContext: context))
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: inspectRequest,
            response: .elementDetection(detection)).target == .window(identity))

        try Self.expectWindowMutationAttributionFailures(
            identity: identity,
            incompleteIdentity: incompleteIdentity,
            bounds: bounds)
    }

    @Test
    func `focused exact target is retained and contradictory focus is rejected`() throws {
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9_007_199_254_740_993,
            capturedBounds: bounds)
        let focused = FocusedElementIdentity(
            processIdentifier: 42,
            windowID: 73,
            role: "AXTextField",
            title: "Editor",
            identifier: "editor",
            frame: CGRect(x: 30, y: 40, width: 200, height: 30))
        let exact = try UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds,
            focusedElement: focused)
        let request = PeekabooBridgeRequest.exactWindowTargetedTypeActions(.init(
            actions: [.text("x")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: "snapshot",
            expectedWindowIdentity: identity,
            expectedWindowBounds: bounds,
            expectedFocusedElement: focused))

        let receipt = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: request,
            response: .ok,
            handledTarget: DesktopTargetIdentity(exactWindow: exact))
        #expect(receipt.target == .window(identity))
        #expect(receipt.focusedElement == focused)

        let contradictoryFocus = FocusedElementIdentity(
            processIdentifier: 42,
            windowID: 73,
            role: "AXTextField",
            title: "Other",
            identifier: "other",
            frame: CGRect(x: 30, y: 80, width: 200, height: 30))
        let contradictory = try UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds,
            focusedElement: contradictoryFocus)
        #expect(throws: DesktopTargetIdentityError.contradictoryFocusedElement) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: request,
                response: .ok,
                handledTarget: DesktopTargetIdentity(exactWindow: contradictory))
        }
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

    private static func expectPrivateDirectory(_ path: String) {
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFDIR)
        #expect(info.st_uid == geteuid())
        #expect(info.st_mode & 0o777 == 0o700)
    }

    private static func expectWindowMutationAttributionFailures(
        identity: WindowMutationIdentity,
        incompleteIdentity: WindowMutationIdentity,
        bounds: CGRect) throws
    {
        let moveRequest = PeekabooBridgeRequest.moveWindow(.init(
            target: .windowId(identity.windowID),
            expectedIdentity: identity,
            position: .zero))
        let replacementIdentity = WindowMutationIdentity(
            windowID: identity.windowID,
            ownerProcessIdentifier: identity.ownerProcessIdentifier,
            ownerProcessStartIdentity: identity.ownerProcessStartIdentity + 1,
            capturedBounds: bounds)
        let replacementWindow = ServiceWindowInfo(
            windowID: identity.windowID,
            title: "Replacement",
            bounds: bounds,
            mutationIdentity: replacementIdentity)
        let moveTarget = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: moveRequest,
            response: .window(replacementWindow))
        #expect(moveTarget.target == .window(identity))

        let incompleteMove = PeekabooBridgeRequest.moveWindow(.init(
            target: .windowId(incompleteIdentity.windowID),
            expectedIdentity: incompleteIdentity,
            position: .zero))
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: incompleteMove,
                response: .ok)
        }
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
