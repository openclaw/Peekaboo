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
    func `operation sessions bind negotiated capabilities across reuse and rollover`() async throws {
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: "/tmp/peekaboo-session-capabilities-\(UUID().uuidString).sock",
            maximumClaimCount: 1)
        let legacyCapabilities = PeekabooBridgeNegotiatedSessionCapabilities(
            protocolVersion: .init(major: 1, minor: 29),
            statelessClickVariants: false,
            exactWindowHeldPointerLifecycle: false)
        let legacy = try await OperationReceiptSessionFixture.make(
            authority: authority,
            negotiatedCapabilities: legacyCapabilities)
        let current = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: legacy.clientInstanceID,
            peer: legacy.peer,
            negotiatedCapabilities: .current)
        #expect(current.attestation.sessionID != legacy.attestation.sessionID)
        #expect(!legacyCapabilities.producerBoundSnapshotReferences)
        #expect(!legacyCapabilities.targetedClickAccessibilityValueDelivery)
        #expect(PeekabooBridgeNegotiatedSessionCapabilities.current.producerBoundSnapshotReferences)
        #expect(PeekabooBridgeNegotiatedSessionCapabilities.current.targetedClickAccessibilityValueDelivery)

        let legacyClaim = try await legacy.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: .permissionsStatus)
        #expect(legacyClaim.claim.negotiatedCapabilities == legacyCapabilities)
        let rollover = try await legacy.rolloverRefusal(
            authority: authority,
            sequence: 1,
            request: .permissionsStatus)
        let successor = try OperationReceiptSessionFixture(
            clientInstanceID: legacy.clientInstanceID,
            peer: legacy.peer,
            attestation: #require(rollover.refusal.payload.successorSessionAttestation))
        let successorClaim = try await successor.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: .permissionsStatus)
        #expect(successorClaim.claim.negotiatedCapabilities == legacyCapabilities)
        authority.complete(legacyClaim.claim)
        authority.complete(successorClaim.claim)
    }

    @Test
    func `listener archive does not depend on a predictable shared root`() throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        var archiveRoots: [URL] = []
        defer {
            try? FileManager.default.removeItem(at: root)
            for archiveRoot in archiveRoots {
                try? FileManager.default.removeItem(at: archiveRoot)
            }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        let predictable = URL(fileURLWithPath: socketPath + ".receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: predictable, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: predictable.path)

        let authority = try PeekabooBridgeOperationReceiptAuthority(socketPath: socketPath)
        #expect(authority.attestation.receiptArchiveDirectory != predictable.path)
        #expect(authority.attestation.receiptArchiveDirectory.contains("PeekabooOperationReceipts"))
        Self.expectPrivateDirectory(authority.attestation.receiptArchiveDirectory)

        var latest = authority
        for _ in 0..<18 {
            latest = try PeekabooBridgeOperationReceiptAuthority(socketPath: socketPath)
        }
        let archiveRoot = URL(fileURLWithPath: latest.attestation.receiptArchiveDirectory)
            .deletingLastPathComponent()
        archiveRoots.append(archiveRoot)
        let retained = try FileManager.default.contentsOfDirectory(atPath: archiveRoot.path)
            .filter { UUID(uuidString: $0) != nil }
        #expect(retained.count == 16)

        let other = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("other.sock").path)
        let otherArchiveRoot = URL(fileURLWithPath: other.attestation.receiptArchiveDirectory)
            .deletingLastPathComponent()
        archiveRoots.append(otherArchiveRoot)
        #expect(otherArchiveRoot != archiveRoot)
        #expect(otherArchiveRoot.deletingLastPathComponent() == archiveRoot.deletingLastPathComponent())
    }

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
            let client = TrustedBridgeClientFixture.make(
                socketPath: socketPath,
                requestTimeoutSec: 2,
                operationReceiptExportDirectory: exportDirectory)
            let handshake = try await client.handshake(
                client: Self.clientIdentity,
                protocolVersion: PeekabooBridgeConstants.attestedOperationReceiptVersion)
            let attestation = try #require(handshake.operationAttestation)
            let sessionAttestation = try #require(handshake.operationSessionAttestation)

            #expect(handshake.negotiatedVersion == PeekabooBridgeConstants.attestedOperationReceiptVersion)
            #expect(handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.attestedOperationReceipts) == true)
            try attestation.validateSignature()
            try sessionAttestation.validateSignature(listenerAttestation: attestation)
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
            #expect(receipt.payload.sessionID == sessionAttestation.sessionID)
            #expect(receipt.payload.sessionSequence == .init(0))
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
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(sessionAttestation.sessionID.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent("0.json")
            let hostAttestation = URL(fileURLWithPath: attestation.receiptArchiveDirectory)
                .appendingPathComponent("attestation.json")
            let hostSessionAttestation = URL(fileURLWithPath: attestation.receiptArchiveDirectory)
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(sessionAttestation.sessionID.uuidString.lowercased(), isDirectory: true)
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
            let archivedSessionAttestation = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeOperationSessionAttestation.self,
                from: Data(contentsOf: hostSessionAttestation))
            #expect(archivedReceipt == receipt)
            #expect(archivedAttestation == attestation)
            #expect(archivedSessionAttestation == sessionAttestation)
            #expect(exportedBundle == bundle)
            try archivedAttestation.validateSignature()
            try archivedSessionAttestation.validateSignature(listenerAttestation: archivedAttestation)
            try exportedBundle.validate()
            Self.expectPrivateDirectory(attestation.receiptArchiveDirectory)
            Self.expectPrivateFile(hostArchive.path)
            Self.expectPrivateFile(hostAttestation.path)
            Self.expectPrivateFile(hostSessionAttestation.path)
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
        let first = try await TrustedBridgeClientFixture.make(socketPath: socketPath)
            .handshake(client: Self.clientIdentity)
            .operationAttestation
        _ = await host.stop()

        try await host.startChecked()
        let second = try await TrustedBridgeClientFixture.make(socketPath: socketPath)
            .handshake(client: Self.clientIdentity)
            .operationAttestation
        _ = await host.stop()

        #expect(first?.listenerInstanceID != second?.listenerInstanceID)
        #expect(first?.publicKey != second?.publicKey)
    }

    @Test
    func `client crosses tiny session caps downgrades and recovers after listener restart`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                allowlistedTeams: [],
                allowlistedBundles: [],
                operationReceiptSessionCapacity: 2,
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
                })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        let client = TrustedBridgeClientFixture.make(
            socketPath: socketPath,
            requestTimeoutSec: 2,
            operationClientInstanceID: UUID())

        do {
            let initial = try await client.handshake(client: Self.clientIdentity)
            let firstListener = try #require(initial.operationAttestation)
            #expect(await client.exactWindowHeldPointerLifecycleEnabled)
            #expect(await client.statelessClickVariantsEnabled)
            var receiptSessionIDs: Set<UUID> = []
            for _ in 0..<5 {
                guard case .permissionsStatus = try await client.send(.permissionsStatus) else {
                    Issue.record("Expected permissions response during session rollover")
                    continue
                }
                let bundle = try #require(await client.lastOperationReceiptBundle())
                try bundle.validate()
                #expect(bundle.operationAttestation == firstListener)
                receiptSessionIDs.insert(bundle.operationSessionAttestation.sessionID)
            }
            // One slot remains reserved for a signed rollover refusal, so a cap of two renews
            // proactively after every successfully certified operation.
            #expect(receiptSessionIDs.count == 5)
            let sessionBeforeDowngrade = try #require(await client.lastOperationReceiptBundle())
                .operationSessionAttestation

            let legacy = try await client.handshake(
                client: Self.clientIdentity,
                protocolVersion: PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion)
            #expect(legacy.negotiatedVersion == PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion)
            #expect(legacy.operationAttestation == nil)
            #expect(legacy.operationSessionAttestation == nil)
            #expect(await client.exactWindowHeldPointerLifecycleEnabled == false)
            #expect(await client.statelessClickVariantsEnabled == false)
            guard case .permissionsStatus = try await client.send(.permissionsStatus) else {
                Issue.record("Expected legacy permissions response")
                await host.stop()
                return
            }
            #expect(await client.lastOperationReceipt() == nil)

            let restored = try await client.handshake(client: Self.clientIdentity)
            let restoredListener = try #require(restored.operationAttestation)
            let restoredSession = try #require(restored.operationSessionAttestation)
            #expect(await client.exactWindowHeldPointerLifecycleEnabled)
            #expect(await client.statelessClickVariantsEnabled)
            #expect(restoredListener == firstListener)
            #expect(restoredSession.predecessorSessionID == sessionBeforeDowngrade.sessionID)
            _ = try await client.send(.permissionsStatus)
            try #require(await client.lastOperationReceiptBundle()).validate()

            #expect(await host.stop() == .stopped)
            try await host.startChecked()
            let restarted = try await client.handshake(client: Self.clientIdentity)
            let restartedListener = try #require(restarted.operationAttestation)
            let restartedSession = try #require(restarted.operationSessionAttestation)
            #expect(restartedListener.listenerInstanceID != restoredListener.listenerInstanceID)
            #expect(restartedListener.publicKey != restoredListener.publicKey)
            #expect(restartedSession.predecessorSessionID == nil)
            _ = try await client.send(.permissionsStatus)
            let restartedBundle = try #require(await client.lastOperationReceiptBundle())
            try restartedBundle.validate()
            #expect(restartedBundle.operationAttestation == restartedListener)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    @Test
    func `mutation before any successful handshake is refused without transport`() async throws {
        let peer = try ScriptedBridgePeer(steps: [.respond(.ok)])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)

        do {
            try await client.sendExpectOK(.requestPostEventPermission)
            Issue.record("Expected a never-negotiated mutation to fail closed")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.evidence == .requestRefused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.outcome.refusalReason == .transportSessionUnavailable)
            #expect(failure.outcome.escalation == .reconnectSession)
        } catch {
            Issue.record("Expected canonical pre-transport refusal, got \(error)")
        }
        do {
            _ = try await client.send(.permissionsStatus)
            Issue.record("Expected a never-negotiated read-only request to retain its session error")
        } catch let error as PeekabooBridgeClientOperationSessionError {
            #expect(error == .handshakeRequired)
        }
        #expect(await peer.acceptedConnectionCount == 0)
        await peer.stop()
    }

    @Test
    func `explicit protocol 1 28 handshake keeps requests receiptless`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                allowlistedTeams: [],
                allowlistedBundles: [],
                operationReceiptSessionCapacity: 2,
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
                })
        }
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()

        do {
            let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
            let handshake = try await client.handshake(
                client: Self.clientIdentity,
                protocolVersion: PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion)
            #expect(handshake.negotiatedVersion == PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion)
            #expect(handshake.operationAttestation == nil)
            #expect(handshake.operationSessionAttestation == nil)
            guard case .permissionsStatus = try await client.send(.permissionsStatus) else {
                Issue.record("Expected legacy permissions response")
                await host.stop()
                return
            }
            #expect(await client.lastOperationReceipt() == nil)
            #expect(await client.lastOperationReceiptBundle() == nil)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    @Test
    func `mutating receipt carries canonical outcome and generation pinned target`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let expectedOutcome = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .background))
        let canonicalExpectedOutcome = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            unitCount: .one)
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
            let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
            _ = try await client.handshake(client: Self.clientIdentity)
            let processIdentity = try ApplicationProcessIdentity(
                processIdentifier: getpid(),
                processStartIdentity: #require(SystemIdentityResolver.processStartIdentity(getpid())))
            let result = try await client.clickWithOutcome(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                expectedProcessIdentity: processIdentity)
            #expect(result.outcome == canonicalExpectedOutcome.routed(to: .bridge))
            #expect(result.targetIdentity?.processIdentity == processIdentity)

            let receipt = try #require(await client.lastOperationReceipt())
            #expect(receipt.payload.operation == .targetedClick)
            #expect(receipt.payload.target == .process(processIdentity))
            #expect(receipt.payload.outcome == canonicalExpectedOutcome.routed(to: .bridge).projection)
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
            let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
            _ = try await client.handshake(client: Self.clientIdentity)
            let result = try await client.scrollWithOutcome(.init(
                direction: .down,
                amount: 1,
                target: "S1",
                snapshotId: "snapshot",
                expectedWindow: exactWindow))
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
            let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
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
            services.automationStub.allowsContradictoryOutcomeTargetIdentityForTesting = true
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
            let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
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
}

extension PeekabooBridgeOperationReceiptTests {
    @Test
    func `rollover archive failure stays trusted and reports server busy`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-rollover-write-failure-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = GatedFailingSessionAttestationWriter(parties: 1)
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path,
            maximumClaimCount: 4,
            maximumSessionCount: 4,
            retainedRetiredSessionCount: 1,
            sessionAttestationWriter: writer.write)
        let clientInstanceID = UUID()
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let listener = authority.attestation
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.attestedOperationReceiptVersion,
            hostKind: .gui,
            build: "rollover-write-failure-test",
            supportedOperations: [.permissionsStatus],
            permissions: .init(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: [.permissionsStatus],
            hostIdentity: .init(
                processIdentifier: listener.host.processIdentifier,
                processStartIdentity: listener.host.processStartIdentity,
                bundleIdentifier: "dev.peekaboo.rollover-write-failure",
                bundleShortVersion: "1",
                bundleVersion: "1",
                codeSignatureHash: listener.host.codeSignatureHash),
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.desktopActionOutcomeProjection,
            ],
            operationAttestation: listener,
            operationSessionAttestation: session.attestation)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            operationClientInstanceID: clientInstanceID)

        do {
            let handshakeTask = Task { try await client.handshake(client: Self.clientIdentity) }
            let handshakeRequest = try await peer.nextRequest()
            try await peer.respond(.handshake(handshake), to: handshakeRequest)
            _ = try await handshakeTask.value

            try authority.retireSession(
                session.attestation.sessionID,
                clientInstanceID: clientInstanceID,
                peer: session.peer)
            writer.beginFailing()
            let operation = Task { try await client.send(.permissionsStatus) }
            let wireRequest = try await peer.nextRequest()
            guard case let .attestedOperation(payload) = try wireRequest.decode(),
                  case let .rolloverRequired(refusal) = try await authority.claim(payload, peer: session.peer)
            else {
                Issue.record("Expected signed rollover refusal")
                await peer.stop()
                return
            }
            #expect(refusal.payload.disposition == .sessionRolloverUnavailable)
            #expect(refusal.payload.successorSessionAttestation == nil)
            #expect(refusal.payload.retrySafe)
            #expect(!refusal.payload.mutationDispatched)
            try refusal.validate(
                listenerAttestation: listener,
                predecessorSession: session.attestation,
                request: payload)
            try await peer.respond(.operationSessionRollover(refusal), to: wireRequest)

            do {
                _ = try await operation.value
                Issue.record("Expected rollover persistence pressure to surface as server busy")
            } catch let envelope as PeekabooBridgeErrorEnvelope {
                #expect(envelope.code == .serverBusy)
                #expect(!envelope.operationMayHaveCompleted)
            }
            #expect(await MainActor.run {
                PeekabooBridgeServer.operationReceiptClaimErrorCode(
                    .archiveWriteFailed("injected")) == .serverBusy
            })
            #expect(writer.arrivalCount == 1)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `session claims accept out of order reject replay and roll to one signed successor`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-replay-\(UUID().uuidString)",
            isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: socketPath,
            maximumClaimCount: 2,
            maximumSessionCount: 4,
            retainedRetiredSessionCount: 1)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let sequenceOne = try await session.acceptedClaim(
            authority: authority,
            sequence: 1,
            request: .permissionsStatus)
        let sequenceZero = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: .permissionsStatus)

        #expect(sequenceOne.claim.remainingClaimCount == 1)
        #expect(sequenceZero.claim.remainingClaimCount == 0)
        await #expect(throws: PeekabooBridgeOperationReceiptError.replayedRequest) {
            try await authority.claim(sequenceOne.request, peer: session.peer)
        }

        let firstRollover = try await session.rolloverRefusal(
            authority: authority,
            sequence: 2,
            request: .permissionsStatus)
        let secondRollover = try await session.rolloverRefusal(
            authority: authority,
            sequence: 3,
            request: .permissionsStatus)
        try firstRollover.refusal.validate(
            listenerAttestation: authority.attestation,
            predecessorSession: session.attestation,
            request: firstRollover.request)
        try secondRollover.refusal.validate(
            listenerAttestation: authority.attestation,
            predecessorSession: session.attestation,
            request: secondRollover.request)
        let successor = try #require(firstRollover.refusal.payload.successorSessionAttestation)
        let repeatedSuccessor = try #require(secondRollover.refusal.payload.successorSessionAttestation)
        #expect(repeatedSuccessor == successor)
        #expect(successor.predecessorSessionID == session.attestation.sessionID)
        #expect(successor.listenerInstanceID == authority.attestation.listenerInstanceID)

        let successorFixture = OperationReceiptSessionFixture(
            clientInstanceID: session.clientInstanceID,
            peer: session.peer,
            attestation: successor)
        let successorSequenceZero = try await successorFixture.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: .permissionsStatus)
        #expect(successorSequenceZero.request.requestID != sequenceZero.request.requestID)

        let otherAuthority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("other.sock").path)
        await #expect(throws: PeekabooBridgeOperationReceiptError.listenerInstanceMismatch) {
            try await otherAuthority.claim(sequenceZero.request, peer: session.peer)
        }

        authority.complete(sequenceOne.claim)
        authority.complete(sequenceZero.claim)
        authority.complete(successorSequenceZero.claim)
    }

    @Test
    func `concurrent duplicate claims admit once and concurrent renewals share a successor`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-concurrency-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path,
            maximumClaimCount: 2,
            maximumSessionCount: 4,
            retainedRetiredSessionCount: 1)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let payload = session.request(
            authority: authority,
            sequence: 0,
            request: .permissionsStatus)
        let claimantCount = 16
        let claimBarrier = ReceiptWriteBarrier(parties: claimantCount)
        let claimOutcomes = await withTaskGroup(of: OperationReceiptClaimRaceOutcome.self) { group in
            for _ in 0..<claimantCount {
                group.addTask {
                    await claimBarrier.wait()
                    do {
                        switch try await authority.claim(payload, peer: session.peer) {
                        case let .accepted(claim):
                            return OperationReceiptClaimRaceOutcome.accepted(claim)
                        case .rolloverRequired:
                            return OperationReceiptClaimRaceOutcome.unexpected(
                                "duplicate claim requested rollover")
                        }
                    } catch PeekabooBridgeOperationReceiptError.replayedRequest {
                        return OperationReceiptClaimRaceOutcome.replayed
                    } catch {
                        return OperationReceiptClaimRaceOutcome.unexpected("\(error)")
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let acceptedClaims = claimOutcomes.compactMap { outcome -> PeekabooBridgeOperationSessionClaim? in
            guard case let .accepted(claim) = outcome else { return nil }
            return claim
        }
        #expect(acceptedClaims.count == 1)
        #expect(claimOutcomes.filter {
            if case .replayed = $0 {
                true
            } else {
                false
            }
        }.count == 15)
        #expect(!claimOutcomes.contains {
            if case .unexpected = $0 {
                true
            } else {
                false
            }
        })

        let secondClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 1,
            request: .permissionsStatus)
        let renewalCount = 8
        let renewalBarrier = ReceiptWriteBarrier(parties: renewalCount)
        let renewalOutcomes = await withTaskGroup(of: OperationReceiptClaimRaceOutcome.self) { group in
            for offset in 0..<renewalCount {
                group.addTask {
                    await renewalBarrier.wait()
                    let request = session.request(
                        authority: authority,
                        sequence: UInt64(2 + offset),
                        request: .permissionsStatus)
                    do {
                        switch try await authority.claim(request, peer: session.peer) {
                        case .accepted:
                            return OperationReceiptClaimRaceOutcome.unexpected(
                                "out-of-range claim was accepted")
                        case let .rolloverRequired(refusal):
                            return OperationReceiptClaimRaceOutcome.rollover(refusal)
                        }
                    } catch {
                        return OperationReceiptClaimRaceOutcome.unexpected("\(error)")
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let successorIDs = Set(renewalOutcomes.compactMap { outcome -> UUID? in
            guard case let .rollover(refusal) = outcome else { return nil }
            return refusal.payload.successorSessionAttestation?.sessionID
        })
        #expect(successorIDs.count == 1)
        #expect(renewalOutcomes.filter {
            if case .rollover = $0 {
                true
            } else {
                false
            }
        }.count == renewalCount)
        #expect(!renewalOutcomes.contains {
            if case .unexpected = $0 {
                true
            } else {
                false
            }
        })

        acceptedClaims.forEach(authority.complete)
        authority.complete(secondClaim.claim)
    }

    @Test
    func `concurrent clients keep independent bounded replay sessions`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-clients-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path,
            maximumClaimCount: 2,
            maximumSessionCount: 6,
            maximumActiveSessionCountPerPeer: 4,
            retainedRetiredSessionCount: 1)
        let first = try await OperationReceiptSessionFixture.make(authority: authority)
        let second = try await OperationReceiptSessionFixture.make(authority: authority)
        #expect(first.clientInstanceID != second.clientInstanceID)
        #expect(first.attestation.sessionID != second.attestation.sessionID)

        let requests = [
            (first, UInt64(0)),
            (first, UInt64(1)),
            (second, UInt64(0)),
            (second, UInt64(1)),
        ]
        let barrier = ReceiptWriteBarrier(parties: requests.count)
        let outcomes = await withTaskGroup(of: OperationReceiptClaimRaceOutcome.self) { group in
            for (session, sequence) in requests {
                group.addTask {
                    await barrier.wait()
                    let request = session.request(
                        authority: authority,
                        sequence: sequence,
                        request: .permissionsStatus)
                    do {
                        switch try await authority.claim(request, peer: session.peer) {
                        case let .accepted(claim):
                            return .accepted(claim)
                        case .rolloverRequired:
                            return .unexpected("in-range client claim requested rollover")
                        }
                    } catch {
                        return .unexpected("\(error)")
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let claims = outcomes.compactMap { outcome -> PeekabooBridgeOperationSessionClaim? in
            guard case let .accepted(claim) = outcome else { return nil }
            return claim
        }
        #expect(claims.count == requests.count)
        #expect(!outcomes.contains {
            if case .unexpected = $0 {
                true
            } else {
                false
            }
        })

        let firstRollover = try await first.rolloverRefusal(
            authority: authority,
            sequence: 2,
            request: .permissionsStatus)
        let secondRollover = try await second.rolloverRefusal(
            authority: authority,
            sequence: 2,
            request: .permissionsStatus)
        let firstSuccessor = try #require(firstRollover.refusal.payload.successorSessionAttestation)
        let secondSuccessor = try #require(secondRollover.refusal.payload.successorSessionAttestation)
        #expect(firstSuccessor.sessionID != secondSuccessor.sessionID)
        #expect(firstSuccessor.predecessorSessionID ==
            first.attestation.sessionID)
        #expect(secondSuccessor.predecessorSessionID ==
            second.attestation.sessionID)
        claims.forEach(authority.complete)
    }

    @Test
    func `sequential abandoned clients reclaim peer capacity with signed rollover`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-abandoned-clients-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path,
            maximumClaimCount: 4,
            maximumSessionCount: 12,
            maximumActiveSessionCountPerPeer: 4,
            retainedRetiredSessionCount: 1)
        let peer = try OperationReceiptSessionFixture.currentPeer()
        let oldest = try await OperationReceiptSessionFixture.make(authority: authority, peer: peer)
        let completed = try await oldest.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: .permissionsStatus)
        authority.complete(completed.claim)
        for _ in 0..<4 {
            _ = try await OperationReceiptSessionFixture.make(
                authority: authority,
                peer: peer)
        }

        await #expect(throws: PeekabooBridgeOperationReceiptError.replayedRequest) {
            try await authority.claim(
                oldest.request(authority: authority, sequence: 0, request: .permissionsStatus),
                peer: peer)
        }
        let rollover = try await oldest.rolloverRefusal(
            authority: authority,
            sequence: 1,
            request: .permissionsStatus)
        let successor = try #require(rollover.refusal.payload.successorSessionAttestation)
        #expect(rollover.refusal.payload.disposition == .sessionRolloverRequired)
        #expect(successor.predecessorSessionID == oldest.attestation.sessionID)
        try rollover.refusal.validate(
            listenerAttestation: authority.attestation,
            predecessorSession: oldest.attestation,
            request: rollover.request)
    }

    @Test
    func `peer capacity reclamation never retires in-flight sessions`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-active-clients-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path,
            maximumClaimCount: 4,
            maximumSessionCount: 12,
            maximumActiveSessionCountPerPeer: 4,
            retainedRetiredSessionCount: 4)
        let peer = try OperationReceiptSessionFixture.currentPeer()
        var sessions: [OperationReceiptSessionFixture] = []
        var claims: [PeekabooBridgeOperationSessionClaim] = []
        for _ in 0..<4 {
            let session = try await OperationReceiptSessionFixture.make(
                authority: authority,
                peer: peer)
            sessions.append(session)
            let accepted = try await session.acceptedClaim(
                authority: authority,
                sequence: 0,
                request: .permissionsStatus)
            claims.append(accepted.claim)
        }

        await #expect(throws: PeekabooBridgeOperationReceiptError.operationSessionRegistryExhausted) {
            _ = try await OperationReceiptSessionFixture.make(authority: authority, peer: peer)
        }
        for session in sessions {
            let accepted = try await session.acceptedClaim(
                authority: authority,
                sequence: 1,
                request: .permissionsStatus)
            claims.append(accepted.claim)
        }
        claims.forEach(authority.complete)
    }

    @Test
    func `failed concurrent replacements release quiescent session reservations`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-failed-replacements-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = GatedFailingSessionAttestationWriter(parties: 4)
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path,
            maximumClaimCount: 4,
            maximumSessionCount: 12,
            maximumActiveSessionCountPerPeer: 4,
            retainedRetiredSessionCount: 4,
            sessionAttestationWriter: writer.write)
        let peer = try OperationReceiptSessionFixture.currentPeer()
        var sessions: [OperationReceiptSessionFixture] = []
        for _ in 0..<4 {
            try await sessions.append(OperationReceiptSessionFixture.make(
                authority: authority,
                peer: peer))
        }

        writer.beginFailing()
        let startBarrier = ReceiptWriteBarrier(parties: 4)
        let failures = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    await startBarrier.wait()
                    do {
                        _ = try await OperationReceiptSessionFixture.make(
                            authority: authority,
                            peer: peer)
                        return false
                    } catch let error as PeekabooBridgeOperationReceiptError {
                        if case .archiveWriteFailed = error {
                            return true
                        }
                        return false
                    } catch {
                        return false
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(writer.arrivalCount == 4)
        #expect(failures.filter { !$0 }.isEmpty)

        var claims: [PeekabooBridgeOperationSessionClaim] = []
        for session in sessions {
            let accepted = try await session.acceptedClaim(
                authority: authority,
                sequence: 0,
                request: .permissionsStatus)
            claims.append(accepted.claim)
        }
        claims.forEach(authority.complete)
    }

    @Test
    func `abandoned client reclamation keeps registry and archives bounded`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-client-churn-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let maximumSessionCount = 8
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path,
            maximumClaimCount: 4,
            maximumSessionCount: maximumSessionCount,
            maximumActiveSessionCountPerPeer: 4,
            retainedRetiredSessionCount: 1)
        let peer = try OperationReceiptSessionFixture.currentPeer()
        let archive = URL(fileURLWithPath: authority.attestation.receiptArchiveDirectory)
        let sessionArchive = archive.appendingPathComponent("sessions", isDirectory: true)
        let retiredArchive = archive.appendingPathComponent("retired-sessions", isDirectory: true)
        var latest: OperationReceiptSessionFixture?

        for _ in 0..<24 {
            latest = try await OperationReceiptSessionFixture.make(
                authority: authority,
                peer: peer)
            let sessionArchiveCount = try FileManager.default.contentsOfDirectory(
                at: sessionArchive,
                includingPropertiesForKeys: nil).count
            let retiredArchiveCount = try FileManager.default.contentsOfDirectory(
                at: retiredArchive,
                includingPropertiesForKeys: nil).count
            #expect(sessionArchiveCount + retiredArchiveCount <= maximumSessionCount)
        }

        let latestSession = try #require(latest)
        let latestClaim = try await latestSession.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: .permissionsStatus)
        authority.complete(latestClaim.claim)
    }

    @Test
    func `retired session claim signs after successor work completes`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-inflight-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path,
            maximumClaimCount: 2,
            maximumSessionCount: 4,
            retainedRetiredSessionCount: 1)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let oldClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: .permissionsStatus)
        let rollover = try await session.rolloverRefusal(
            authority: authority,
            sequence: 2,
            request: .permissionsStatus)
        let successor = try OperationReceiptSessionFixture(
            clientInstanceID: session.clientInstanceID,
            peer: session.peer,
            attestation: #require(rollover.refusal.payload.successorSessionAttestation))
        let successorClaim = try await successor.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: .permissionsStatus)
        authority.complete(successorClaim.claim)

        let response = PeekabooBridgeResponse.permissionsStatus(.init(
            screenRecording: true,
            accessibility: true))
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: oldClaim.claim,
            request: .permissionsStatus,
            response: response)
        let receipt = try await authority.signAndArchive(payload, claim: oldClaim.claim)
        try receipt.validateSignature(publicKey: authority.attestation.publicKey)
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: receipt,
            request: .permissionsStatus,
            response: response)
        try bundle.validate()

        let archive = URL(fileURLWithPath: authority.attestation.receiptArchiveDirectory)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(session.attestation.sessionID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("0.json")
        #expect(FileManager.default.fileExists(atPath: archive.path))
        authority.complete(oldClaim.claim)
    }

    @Test
    func `bounded sessions preserve in-flight claims and enforce peer binding`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-bounds-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path,
            maximumClaimCount: 2,
            maximumSessionCount: 3,
            retainedRetiredSessionCount: 1)
        let unboundPeer = try OperationReceiptSessionFixture.currentPeer(
            auditTokenProcessIdentifierVersion: nil)
        await #expect(throws: PeekabooBridgeOperationReceiptError.peerIdentityMismatch) {
            _ = try await authority.createSession(clientInstanceID: UUID(), peer: unboundPeer)
        }

        let first = try await OperationReceiptSessionFixture.make(authority: authority)
        let invalidPeer = try OperationReceiptSessionFixture.currentPeer(codeSignatureHash: "different-cdhash")
        let firstPayload = first.request(
            authority: authority,
            sequence: 0,
            request: .permissionsStatus)
        await #expect(throws: PeekabooBridgeOperationReceiptError.clientIdentityMismatch) {
            try await authority.claim(firstPayload, peer: invalidPeer)
        }
        let firstClaim = try await first.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: .permissionsStatus)

        let nested = first.request(
            authority: authority,
            sequence: 1,
            request: .projectedAction(.init(request: .attestedOperation(firstPayload))))
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try nested.validatedRequest()
        }

        let firstRollover = try await first.rolloverRefusal(
            authority: authority,
            sequence: 2,
            request: .permissionsStatus)
        let second = try OperationReceiptSessionFixture(
            clientInstanceID: first.clientInstanceID,
            peer: first.peer,
            attestation: #require(firstRollover.refusal.payload.successorSessionAttestation))
        let secondRollover = try await second.rolloverRefusal(
            authority: authority,
            sequence: 2,
            request: .permissionsStatus)
        let third = try OperationReceiptSessionFixture(
            clientInstanceID: first.clientInstanceID,
            peer: first.peer,
            attestation: #require(secondRollover.refusal.payload.successorSessionAttestation))
        let unavailable = try await third.rolloverRefusal(
            authority: authority,
            sequence: 2,
            request: .permissionsStatus)
        #expect(unavailable.refusal.payload.disposition == .sessionRolloverUnavailable)
        #expect(unavailable.refusal.payload.successorSessionAttestation == nil)
        #expect(unavailable.refusal.payload.retrySafe)
        #expect(!unavailable.refusal.payload.mutationDispatched)
        try unavailable.refusal.validate(
            listenerAttestation: authority.attestation,
            predecessorSession: third.attestation,
            request: unavailable.request)

        authority.complete(firstClaim.claim)
    }

    @Test
    func `lost attested mutation response is retry unsafe and names its request`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let attestation = authority.attestation
        let clientInstanceID = UUID()
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
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
            operationAttestation: attestation,
            operationSessionAttestation: session.attestation)
        let handshakeData = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeResponse.handshake(handshake))
        let peer = try ScriptedBridgePeer(scripts: [
            [.respondData(handshakeData)],
            [.close],
        ])
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 1,
            operationClientInstanceID: clientInstanceID)
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
    func `successful projected response enforces the request result contract`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-operation-receipt-outcome-contradiction-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .moveMouse(.init(
            to: CGPoint(x: 17, y: 29),
            duration: 0,
            steps: 1,
            profile: .linear))))
        func makeBundle(
            sequence: UInt64,
            outcome: DesktopActionOutcome) async throws -> PeekabooBridgeOperationReceiptBundle
        {
            let response = PeekabooBridgeResponse.projectedAction(.init(
                response: .ok,
                outcome: outcome.projection))
            return try await session.signedBundle(
                authority: authority,
                sequence: sequence,
                request: request,
                response: response,
                target: .global,
                outcome: outcome.projection)
        }

        let valid = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        try await makeBundle(sequence: 0, outcome: valid).validate()

        let refusal = DesktopActionOutcome.refused(route: .bridge, reason: .invalidRequest)
        let wrongDelivery = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let wrongUnitCount = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        let missingUnitCount = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted)
        for (sequence, outcome) in [refusal, wrongDelivery, wrongUnitCount, missingUnitCount].enumerated() {
            let bundle = try await makeBundle(sequence: UInt64(sequence + 1), outcome: outcome)
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try bundle.validate()
            }
        }
    }

    @Test
    func `mixed Dock selection failure validates as a signed retry-unsafe receipt`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-dock-mixed-delivery-receipt-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .rightClickDockItem(.init(
            appName: "Safari",
            menuItem: "Options"))))
        let dock = ApplicationProcessIdentity(
            processIdentifier: 702,
            processStartIdentity: 9002)
        let targetReceipt = DesktopActionTargetReceipt(
            processIdentifier: dock.processIdentifier,
            processStartIdentity: dock.processStartIdentity)
        let selectedLeaves = try [
            DesktopSelectedLeafEvidence(
                kind: .dockItem,
                normalizedSelector: "safari",
                matchKind: .exact,
                selectedTargetReceipt: targetReceipt,
                selectedIndex: 0,
                selectedTitle: "Safari",
                selectedIdentifier: "com.apple.Safari",
                selectedRole: "AXDockItem",
                selectedFrame: CGRect(x: 10, y: 10, width: 20, height: 20),
                candidateSetSHA256: String(repeating: "a", count: 64),
                candidateCount: 1),
            DesktopSelectedLeafEvidence(
                kind: .dockContextMenuItem,
                normalizedSelector: "options",
                matchKind: .exact,
                selectedTargetReceipt: targetReceipt,
                selectedIndex: 0,
                selectedTitle: "Options",
                selectedIdentifier: "fixture.options",
                selectedRole: "AXMenuItem",
                selectedFrame: CGRect(x: 10, y: 40, width: 80, height: 20),
                candidateSetSHA256: String(repeating: "b", count: 64),
                candidateCount: 1),
        ]
        let failure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "The Dock right-click and menu selection may both have been dispatched.")
            .attributed(to: targetReceipt)
            .selectingLeaves(selectedLeaves)
        let response = PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            PeekabooBridgeResponse.projectedActionForCurrentRequestVocabulary(
                response: .error(.init(code: .internalError, actionFailure: failure)),
                outcome: failure.outcome.projection)
        }
        let accepted = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: request)
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: accepted.claim,
            request: request,
            response: response,
            target: .process(dock),
            selectedLeafEvidence: selectedLeaves,
            outcome: failure.outcome.projection)
        let receipt = try await authority.signAndArchive(payload, claim: accepted.claim)
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: receipt,
            request: request,
            response: response)

        try bundle.validate()
        #expect(receipt.payload.outcome == failure.outcome.projection)
        #expect(receipt.payload.outcome?.deliveryMechanism == .composite)
        #expect(receipt.payload.outcome?.dispatchedUnitCount == DesktopActionOutcome.DispatchUnitCount(2))
        #expect(receipt.payload.outcome?.retrySafe == false)
        authority.complete(accepted.claim)
    }

    @Test
    func `exact window click receipts admit only exact AX or window delivery and target`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-exact-window-click-receipt-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 71,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: bounds)
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: identity.ownerProcessIdentifier,
            targetWindowID: identity.windowID,
            expectedWindowIdentity: identity,
            expectedWindowBounds: bounds))))
        let three = try #require(DesktopActionOutcome.DispatchUnitCount(3))
        let ax = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let window = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: three)
        let global = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let process = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: three)

        func makeBundle(
            sequence: UInt64,
            outcome: DesktopActionOutcome,
            target: PeekabooBridgeOperationTargetReceipt) async throws -> PeekabooBridgeOperationReceiptBundle
        {
            let response = PeekabooBridgeResponse.projectedAction(.init(
                response: .ok,
                outcome: outcome.projection))
            return try await session.signedBundle(
                authority: authority,
                sequence: sequence,
                request: request,
                response: response,
                target: target,
                outcome: outcome.projection)
        }

        try await makeBundle(sequence: 0, outcome: ax, target: .window(identity)).validate()
        try await makeBundle(sequence: 1, outcome: window, target: .window(identity)).validate()
        for (sequence, outcome) in [global, process].enumerated() {
            let bundle = try await makeBundle(
                sequence: UInt64(sequence + 2),
                outcome: outcome,
                target: .window(identity))
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try bundle.validate()
            }
        }

        let processTarget = ApplicationProcessIdentity(
            processIdentifier: identity.ownerProcessIdentifier,
            processStartIdentity: identity.ownerProcessStartIdentity)
        let widened = try await makeBundle(sequence: 4, outcome: ax, target: .process(processTarget))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try widened.validate()
        }
        let contradictoryIdentity = WindowMutationIdentity(
            windowID: identity.windowID + 1,
            ownerProcessIdentifier: identity.ownerProcessIdentifier,
            ownerProcessStartIdentity: identity.ownerProcessStartIdentity,
            capturedBounds: bounds)
        let contradictory = try await makeBundle(
            sequence: 5,
            outcome: window,
            target: .window(contradictoryIdentity))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try contradictory.validate()
        }
    }

    @Test
    func `tampering with signed receipt facts or exported bytes fails validation`() async throws {
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
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let validClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: request)
        let forgedClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 1,
            request: request)
        let largeIdentity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9_007_199_254_740_993,
            capturedBounds: CGRect(x: 10, y: 20, width: 300, height: 200))
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: validClaim.claim,
            request: request,
            response: response)
        let receipt = try await authority.signAndArchive(payload, claim: validClaim.claim)
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: receipt,
            request: request,
            response: response)
        try bundle.validate()

        let forgedPayload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: forgedClaim.claim,
            request: request,
            response: response,
            target: .window(largeIdentity))
        let forgedReceipt = try await authority.signAndArchive(forgedPayload, claim: forgedClaim.claim)
        let forgedBundle = try PeekabooBridgeOperationReceiptBundle(
            operationAttestation: authority.attestation,
            operationSessionAttestation: session.attestation,
            receipt: forgedReceipt,
            canonicalListenerAttestationPayload: bundle.canonicalListenerAttestationPayload,
            canonicalSessionAttestationPayload: bundle.canonicalSessionAttestationPayload,
            canonicalReceiptPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(forgedReceipt.payload),
            canonicalRequest: bundle.canonicalRequest,
            canonicalResponse: bundle.canonicalResponse)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try forgedBundle.validate()
        }

        let corrupted = PeekabooBridgeOperationReceiptBundle(
            operationAttestation: authority.attestation,
            operationSessionAttestation: session.attestation,
            receipt: receipt,
            canonicalListenerAttestationPayload: bundle.canonicalListenerAttestationPayload,
            canonicalSessionAttestationPayload: bundle.canonicalSessionAttestationPayload,
            canonicalReceiptPayload: bundle.canonicalReceiptPayload,
            canonicalRequest: Data("different request".utf8),
            canonicalResponse: bundle.canonicalResponse)
        #expect(throws: (any Error).self) {
            try corrupted.validate()
        }
        authority.complete(validClaim.claim)
        authority.complete(forgedClaim.claim)

        let encodedTarget = try PeekabooBridgeOperationReceiptCoding.canonicalData(forgedPayload.target)
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
    func `external browser target round trips and rejects response target drift`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-browser-target-receipt-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let browserReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .browserExecute(.init(
            toolName: "click",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: browserReceipt))))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .browserToolResponse(.init(
                content: [],
                isError: false,
                meta: nil,
                connectionReceipt: browserReceipt,
                completedCallCount: 1,
                dispatchedCallCount: 1)),
            outcome: outcome.projection))
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let validClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: request)
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: validClaim.claim,
            request: request,
            response: response,
            target: .browser(browserReceipt),
            outcome: outcome.projection)
        let receipt = try await authority.signAndArchive(payload, claim: validClaim.claim)
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: receipt,
            request: request,
            response: response)

        try bundle.validate()
        let targetData = try PeekabooBridgeOperationReceiptCoding.canonicalData(payload.target)
        #expect(try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeOperationTargetReceipt.self,
            from: targetData) == .browser(browserReceipt))

        let forgedClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 1,
            request: request)
        let changedReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-b",
            devToolsBrowserID: "browser-b",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let forgedPayload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: forgedClaim.claim,
            request: request,
            response: response,
            target: .browser(changedReceipt),
            outcome: outcome.projection)
        let forgedReceipt = try await authority.signAndArchive(forgedPayload, claim: forgedClaim.claim)
        let forgedBundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: forgedReceipt,
            request: request,
            response: response)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try forgedBundle.validate()
        }
        let substitutionClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 2,
            request: request)
        let substitutedResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .browserToolResponse(.init(
                content: [],
                isError: false,
                meta: nil,
                connectionReceipt: changedReceipt,
                completedCallCount: 1,
                dispatchedCallCount: 1)),
            outcome: outcome.projection))
        let substitutionPayload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: substitutionClaim.claim,
            request: request,
            response: substitutedResponse,
            target: .browser(changedReceipt),
            outcome: outcome.projection)
        let substitutionReceipt = try await authority.signAndArchive(
            substitutionPayload,
            claim: substitutionClaim.claim)
        let substitutionBundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: substitutionReceipt,
            request: request,
            response: substitutedResponse)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try substitutionBundle.validate()
        }
        let processClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 3,
            request: request)
        let fakeProcess = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 10042)
        let processPayload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: processClaim.claim,
            request: request,
            response: response,
            target: .process(fakeProcess),
            outcome: outcome.projection)
        let processReceipt = try await authority.signAndArchive(processPayload, claim: processClaim.claim)
        let processBundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: processReceipt,
            request: request,
            response: response)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try processBundle.validate()
        }
        let refusalClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 4,
            request: request)
        let refusal = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .targetUnavailable,
            message: "browser target unavailable")
        let refusalResponse = PeekabooBridgeResponse.projectedAction(.init(
            response: .error(.init(code: .notFound, actionFailure: refusal)),
            outcome: refusal.outcome.projection))
        let refusalPayload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: refusalClaim.claim,
            request: request,
            response: refusalResponse,
            target: nil,
            outcome: refusal.outcome.projection)
        let refusalReceipt = try await authority.signAndArchive(refusalPayload, claim: refusalClaim.claim)
        let refusalBundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: refusalReceipt,
            request: request,
            response: refusalResponse)
        try refusalBundle.validate()
        authority.complete(validClaim.claim)
        authority.complete(forgedClaim.claim)
        authority.complete(substitutionClaim.claim)
        authority.complete(processClaim.claim)
        authority.complete(refusalClaim.claim)
    }

    @Test
    func `external browser target binds the explicit requested channel`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-browser-channel-receipt-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let expectedReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .browserExecute(.init(
            toolName: "click",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: expectedReceipt))))
        let changedChannelReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "canary",
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .browserToolResponse(.init(
                content: [],
                isError: false,
                meta: nil,
                connectionReceipt: changedChannelReceipt,
                completedCallCount: 1,
                dispatchedCallCount: 1)),
            outcome: outcome.projection))
        let accepted = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: request)
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: accepted.claim,
            request: request,
            response: response,
            target: .browser(changedChannelReceipt),
            outcome: outcome.projection)
        let receipt = try await authority.signAndArchive(payload, claim: accepted.claim)
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: receipt,
            request: request,
            response: response)

        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try bundle.validate()
        }
        authority.complete(accepted.claim)
    }

    @Test
    func `projected browser receipts require typed failures exactly when marked as errors`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-browser-error-receipt-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let connectionReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .browserExecute(.init(
            calls: [
                .init(toolName: "click", arguments: [:]),
                .init(toolName: "type", arguments: [:]),
            ],
            channel: "stable",
            expectedConnectionReceipt: connectionReceipt))))
        let twoCalls = try #require(DesktopActionOutcome.DispatchUnitCount(2))
        let success = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: twoCalls)
        let partialFailure = DesktopActionFailure.partial(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            unitCount: twoCalls,
            message: "One browser call completed before the second failed")

        func makeBundle(
            sequence: UInt64,
            browserResponse: PeekabooBridgeBrowserToolResponse,
            outcome: DesktopActionOutcome,
            target: PeekabooBridgeOperationTargetReceipt? = nil,
            targetless: Bool = false) async throws
            -> PeekabooBridgeOperationReceiptBundle
        {
            let response = PeekabooBridgeResponse.projectedAction(.init(
                response: .browserToolResponse(browserResponse),
                outcome: outcome.projection))
            return try await session.signedBundle(
                authority: authority,
                sequence: sequence,
                request: request,
                response: response,
                target: targetless ? nil : (target ?? .browser(connectionReceipt)),
                outcome: outcome.projection)
        }

        let validSuccess = try await makeBundle(
            sequence: 0,
            browserResponse: .init(
                content: [],
                isError: false,
                meta: nil,
                connectionReceipt: connectionReceipt,
                completedCallCount: 2,
                dispatchedCallCount: 2),
            outcome: success)
        try validSuccess.validate()

        let validPartialError = try await makeBundle(
            sequence: 1,
            browserResponse: .init(
                content: [],
                isError: true,
                meta: nil,
                connectionReceipt: connectionReceipt,
                completedCallCount: 1,
                dispatchedCallCount: 2,
                actionFailure: partialFailure),
            outcome: partialFailure.outcome)
        try validPartialError.validate()

        let untypedError = try await makeBundle(
            sequence: 2,
            browserResponse: .init(
                content: [],
                isError: true,
                meta: nil,
                connectionReceipt: connectionReceipt,
                completedCallCount: 2,
                dispatchedCallCount: 2),
            outcome: success)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try untypedError.validate()
        }

        let unmarkedTypedFailure = try await makeBundle(
            sequence: 3,
            browserResponse: .init(
                content: [],
                isError: false,
                meta: nil,
                connectionReceipt: connectionReceipt,
                completedCallCount: 1,
                dispatchedCallCount: 2,
                actionFailure: partialFailure),
            outcome: partialFailure.outcome)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try unmarkedTypedFailure.validate()
        }

        let opaqueCancellation = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            message: "Browser provider cancellation left exact progress unknown")
        let validUnknownProgress = try await makeBundle(
            sequence: 4,
            browserResponse: .init(
                content: [],
                isError: true,
                meta: nil,
                connectionReceipt: connectionReceipt,
                actionFailure: opaqueCancellation),
            outcome: opaqueCancellation.outcome)
        try validUnknownProgress.validate()
        #expect(validUnknownProgress.receipt.payload.outcome?.dispatchedUnitCount == nil)
        #expect(validUnknownProgress.receipt.payload.outcome?.retrySafe == false)

        let zeroProgressRefusal = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .targetUnavailable,
            message: "Browser target disappeared before dispatch")
        let validZeroProgress = try await makeBundle(
            sequence: 5,
            browserResponse: .init(
                content: [],
                isError: true,
                meta: nil,
                connectionReceipt: connectionReceipt,
                completedCallCount: 0,
                dispatchedCallCount: 0,
                actionFailure: zeroProgressRefusal),
            outcome: zeroProgressRefusal.outcome,
            targetless: true)
        try validZeroProgress.validate()
        #expect(validZeroProgress.receipt.payload.outcome?.dispatchedUnitCount == nil)
        #expect(validZeroProgress.receipt.payload.outcome?.retrySafe == true)

        let contradictoryZeroSuccess = try await makeBundle(
            sequence: 6,
            browserResponse: .init(
                content: [],
                isError: false,
                meta: nil,
                connectionReceipt: connectionReceipt,
                completedCallCount: 0,
                dispatchedCallCount: 0),
            outcome: success)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try contradictoryZeroSuccess.validate()
        }

        let contradictoryZeroFailure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            message: "Contradictory unsafe zero-progress result")
        let invalidZeroFailure = try await makeBundle(
            sequence: 7,
            browserResponse: .init(
                content: [],
                isError: true,
                meta: nil,
                connectionReceipt: connectionReceipt,
                completedCallCount: 0,
                dispatchedCallCount: 0,
                actionFailure: contradictoryZeroFailure),
            outcome: contradictoryZeroFailure.outcome)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try invalidZeroFailure.validate()
        }
    }

    @Test
    func `request target evidence delegates without changing selector constraints`() throws {
        let bounds = CGRect(x: 20, y: 30, width: 640, height: 480)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1001,
            capturedBounds: bounds)
        let moveRequest = PeekabooBridgeRequest.moveWindow(.init(
            target: .windowId(identity.windowID),
            expectedIdentity: identity,
            position: .zero))
        #expect(moveRequest.operationTargetEvidence == [DesktopTargetEvidenceAdapter.evidence(
            windowTarget: .windowId(identity.windowID),
            windowIdentity: identity)])
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveRequest(moveRequest)?.exactWindow?
            .identity == identity)

        let selectorContext = WindowContext(
            applicationProcessId: identity.ownerProcessIdentifier,
            applicationProcessStartIdentity: identity.ownerProcessStartIdentity,
            windowID: identity.windowID,
            windowBounds: bounds)
        let inspectRequest = PeekabooBridgeRequest.inspectAccessibilityTree(.init(windowContext: selectorContext))
        let selectorEvidence = try #require(inspectRequest.operationTargetEvidence.first)

        #expect(inspectRequest.operationTargetEvidence == [
            DesktopTargetEvidenceAdapter.evidence(selectorContext: selectorContext),
        ])
        #expect(selectorEvidence.processIdentifier == identity.ownerProcessIdentifier)
        #expect(selectorEvidence.processIdentity == nil)
        #expect(selectorEvidence.windowID == identity.windowID)
        #expect(selectorEvidence.windowBounds == bounds)
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveRequest(inspectRequest) == nil)
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
        let observationRequest = PeekabooBridgeRequest.desktopObservation(.init(target: .windowID(73)))

        #expect(try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: observationRequest,
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
        let captureRequest = PeekabooBridgeRequest.captureWindow(.init(
            appIdentifier: "",
            windowIndex: nil,
            windowId: identity.windowID,
            visualizerMode: .none,
            scale: .logical1x))
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: captureRequest,
            response: .capture(exactCapture)).target == .window(identity))
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: observationRequest,
                response: .capture(exactCapture))
        }

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
                request: captureRequest,
                response: .capture(contradictoryCapture))
        }

        let processOnly = DesktopObservationResult(
            target: .init(kind: .appWindow, app: app),
            capture: capture,
            elements: nil)
        #expect(throws: DesktopTargetIdentityError.incompleteExactWindow) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: observationRequest,
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
                request: observationRequest,
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
                request: observationRequest,
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

        let processContext = WindowContext(
            applicationName: "Fixture",
            applicationProcessId: identity.ownerProcessIdentifier,
            applicationProcessStartIdentity: identity.ownerProcessStartIdentity,
            windowTitle: "AX-only description",
            windowID: identity.windowID,
            windowBounds: bounds)
        let processDetection = ElementDetectionResult(
            snapshotId: "process-snapshot",
            screenshotPath: "",
            elements: DetectedElements(),
            metadata: .init(
                detectionTime: 0,
                elementCount: 0,
                method: "fixture",
                windowContext: processContext))
        let processInspectRequest = PeekabooBridgeRequest.inspectAccessibilityTree(.init(
            windowContext: WindowContext(applicationName: "Fixture")))
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
            request: processInspectRequest,
            response: .elementDetection(processDetection)).target == .process(identity.processIdentity))

        let selectorOnlyContexts = [
            WindowContext(windowID: identity.windowID),
            WindowContext(
                applicationProcessId: identity.ownerProcessIdentifier,
                windowID: identity.windowID),
            WindowContext(
                applicationBundleId: "dev.peekaboo.fixture",
                windowID: identity.windowID),
        ]
        for selectorContext in selectorOnlyContexts {
            let selectorRequest = PeekabooBridgeRequest.inspectAccessibilityTree(.init(
                windowContext: selectorContext))
            #expect(try PeekabooBridgeOperationTargetAttribution.resolveRequest(selectorRequest) == nil)
            #expect(try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: selectorRequest,
                response: .elementDetection(detection)).target == .window(identity))
        }

        let invalidProcessRequest = PeekabooBridgeRequest.inspectAccessibilityTree(.init(
            windowContext: WindowContext(
                applicationProcessId: 0,
                windowID: identity.windowID)))
        #expect(throws: DesktopTargetIdentityError.invalidProcessIdentifier) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveRequest(invalidProcessRequest)
        }

        let wrongProcessRequest = PeekabooBridgeRequest.inspectAccessibilityTree(.init(
            windowContext: WindowContext(
                applicationProcessId: identity.ownerProcessIdentifier + 1,
                windowID: identity.windowID)))
        #expect(throws: DesktopTargetIdentityError.contradictoryProcessIdentifier) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: wrongProcessRequest,
                response: .elementDetection(detection))
        }

        let wrongWindowRequest = PeekabooBridgeRequest.inspectAccessibilityTree(.init(
            windowContext: WindowContext(
                applicationProcessId: identity.ownerProcessIdentifier,
                windowID: identity.windowID + 1)))
        #expect(throws: DesktopTargetIdentityError.contradictoryWindowIdentifier) {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: wrongWindowRequest,
                response: .elementDetection(detection))
        }

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

private enum SessionAttestationWriterFailure: Error {
    case injected
}

private final class GatedFailingSessionAttestationWriter: @unchecked Sendable {
    private let parties: Int
    private let condition = NSCondition()
    private var failing = false
    private var arrivals = 0

    init(parties: Int) {
        self.parties = parties
    }

    var arrivalCount: Int {
        self.condition.withLock { self.arrivals }
    }

    func beginFailing() {
        self.condition.withLock {
            self.failing = true
            self.arrivals = 0
        }
    }

    func write(_ data: Data, _ destination: URL) throws {
        self.condition.lock()
        guard self.failing else {
            self.condition.unlock()
            try PeekabooBridgePrivateReceiptArchive.writeAtomically(data, to: destination)
            return
        }
        self.arrivals += 1
        if self.arrivals == self.parties {
            self.condition.broadcast()
        } else {
            let deadline = Date().addingTimeInterval(2)
            while self.arrivals < self.parties, self.condition.wait(until: deadline) {}
        }
        self.condition.unlock()
        throw SessionAttestationWriterFailure.injected
    }
}

enum OperationReceiptClaimRaceOutcome: Sendable {
    case accepted(PeekabooBridgeOperationSessionClaim)
    case replayed
    case rollover(PeekabooBridgeOperationSessionRefusal)
    case unexpected(String)
}
