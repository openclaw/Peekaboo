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
