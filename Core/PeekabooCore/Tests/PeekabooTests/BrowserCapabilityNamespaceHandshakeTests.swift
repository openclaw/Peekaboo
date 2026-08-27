import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct BrowserCapabilityNamespaceHandshakeTests {
    private static let pageReference = "bp1_0123456789abcdef0123456789abcdef"

    @Test
    @MainActor
    func `complete current on-demand handshake advertises the closed namespace surface`() async throws {
        let socketPath = "/tmp/peekaboo-browser-namespace-handshake-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: StubServices(),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: PeekabooBridgeOperation.onDemandDefaultAllowlist)
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        await host.setAuthenticationForTesting(.init(
            liveIdentity: { try PeekabooBridgeSocketIO.livePeerIdentity(fd: $0) },
            coldPeer: { identity, _ in
                PeekabooBridgePeer(
                    liveIdentity: identity,
                    bundleIdentifier: "dev.peekaboo.browser-namespace-client",
                    teamIdentifier: TrustedBridgeClientFixture.teamIdentifier)
            }))
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.browser-namespace",
            teamIdentifier: nil,
            processIdentifier: getpid()))

        #expect(handshake.negotiatedVersion >= PeekabooBridgeConstants.browserCapabilityNamespaceVersion)
        #expect(PeekabooBridgeOperation.browserCapabilityNamespaceOperations.isSubset(of:
            Set(handshake.supportedOperations)))
        #expect(PeekabooBridgeOperation.browserCapabilityNamespaceOperations.isSubset(of:
            Set(handshake.enabledOperations ?? [])))
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.browserCapabilityNamespaces) == true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.nativeBrowserWindowBinding) == true)
        #expect(handshake.operationSessionAttestation != nil)
    }

    @Test
    @MainActor
    func `failed namespace runtime preparation suppresses the complete namespace surface`() async throws {
        let socketPath = "/tmp/peekaboo-browser-namespace-preparation-failure-\(UUID().uuidString).sock"
        let services = StubServices()
        services.browserNamespacePrepareError = PeekabooBridgeErrorEnvelope(
            code: .internalError,
            message: "Injected namespace preparation failure")
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: PeekabooBridgeOperation.onDemandDefaultAllowlist)
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        await host.setAuthenticationForTesting(.init(
            liveIdentity: { try PeekabooBridgeSocketIO.livePeerIdentity(fd: $0) },
            coldPeer: { identity, _ in
                PeekabooBridgePeer(
                    liveIdentity: identity,
                    bundleIdentifier: "dev.peekaboo.browser-namespace-preparation-failure-client",
                    teamIdentifier: TrustedBridgeClientFixture.teamIdentifier)
            }))
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.browser-namespace-preparation-failure",
            teamIdentifier: nil,
            processIdentifier: getpid()))

        #expect(services.browserNamespacePrepareCount == 1)
        #expect(PeekabooBridgeOperation.browserCapabilityNamespaceOperations.isDisjoint(with:
            Set(handshake.supportedOperations)))
        #expect(PeekabooBridgeOperation.browserCapabilityNamespaceOperations.isDisjoint(with:
            Set(handshake.enabledOperations ?? [])))
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.browserCapabilityNamespaces) != true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.nativeBrowserWindowBinding) != true)
        let refusal = await #expect(throws: DesktopActionFailure.self) {
            _ = try await client.createBrowserCapabilityNamespace()
        }
        #expect(refusal?.outcome.refusalReason == .runtimeIncompatible)
        #expect(refusal?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(refusal?.outcome.retrySafety == .safe)
        #expect(services.browserNamespaceOpenedIDs.isEmpty)
    }

    @Test
    @MainActor
    func `GUI host strips namespace operations and capabilities despite complete service`() async throws {
        let socketPath = "/tmp/peekaboo-browser-namespace-gui-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: PeekabooBridgeOperation.onDemandDefaultAllowlist)
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.browser-namespace-gui",
            teamIdentifier: nil,
            processIdentifier: getpid()))

        #expect(PeekabooBridgeOperation.browserCapabilityNamespaceOperations.isDisjoint(with:
            Set(handshake.supportedOperations)))
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.browserCapabilityNamespaces) != true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.nativeBrowserWindowBinding) != true)
    }

    @Test
    @MainActor
    func `namespace lifecycle survives listener restart and rejects the retired receipt`() async throws {
        let socketPath = "/tmp/peekaboo-browser-namespace-lifecycle-\(UUID().uuidString).sock"
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: PeekabooBridgeOperation.onDemandDefaultAllowlist)
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        await host.setAuthenticationForTesting(.init(
            liveIdentity: { try PeekabooBridgeSocketIO.livePeerIdentity(fd: $0) },
            coldPeer: { identity, _ in
                PeekabooBridgePeer(
                    liveIdentity: identity,
                    bundleIdentifier: "dev.peekaboo.browser-namespace-lifecycle-client",
                    teamIdentifier: TrustedBridgeClientFixture.teamIdentifier)
            }))
        try await host.startChecked()

        let firstClient = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await firstClient.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.browser-namespace-lifecycle",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        services.browserNamespaceOpenError = PeekabooBridgeErrorEnvelope(
            code: .internalError,
            message: "Injected namespace runtime-open failure")
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await firstClient.createBrowserCapabilityNamespace()
        }
        services.browserNamespaceOpenError = nil
        #expect(services.browserNamespaceOpenedIDs.isEmpty)
        let firstReceipt = try await firstClient.createBrowserCapabilityNamespace()
        let firstReceiptData = try await firstClient.canonicalBrowserCapabilityNamespaceReceiptData(firstReceipt)
        #expect(try await firstClient.decodeBrowserCapabilityNamespaceReceipt(firstReceiptData) == firstReceipt)
        let action = PeekabooBridgeBrowserCapabilityNamespaceRequest(
            namespaceReceipt: firstReceipt,
            action: .executeAction(.init(action: .status)))
        let actionResponse = try await firstClient.executeBrowserCapabilityNamespace(action)
        #expect(!actionResponse.isError)
        services.browserNamespaceOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        services.browserNamespaceTargetIdentity = try DesktopTargetIdentity(
            processIdentity: .init(processIdentifier: 42, processStartIdentity: 1001))
        let mutation = try await firstClient.executeBrowserCapabilityNamespaceResult(.init(
            namespaceReceipt: firstReceipt,
            action: .executeAction(.init(
                action: .click,
                arguments: ["page_id": .string(Self.pageReference)]))))
        #expect(mutation.outcome?.route == .bridge)
        #expect(mutation.outcome?.dispatchState.unitCount == .one)
        #expect(services.browserNamespacePrepareCount == 1)
        #expect(services.browserNamespaceOpenedIDs == [firstReceipt.payload.namespaceID])
        #expect(services.browserNamespaceExecutedIDs == [
            firstReceipt.payload.namespaceID,
            firstReceipt.payload.namespaceID,
        ])
        _ = try await firstClient.closeBrowserCapabilityNamespace(firstReceipt)
        let repeatedClose = try await firstClient.closeBrowserCapabilityNamespace(firstReceipt)
        #expect(repeatedClose.namespaceID == firstReceipt.payload.namespaceID)
        #expect(services.browserNamespaceClosedIDs == [firstReceipt.payload.namespaceID])

        #expect(await host.stop() == .stopped)
        #expect(services.browserNamespaceCloseAllCount == 1)
        #expect(services.browserNamespaceOpenedIDs.isEmpty)

        try await host.startChecked()
        defer { Task { await host.stop() } }
        let replacementClient = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await replacementClient.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.browser-namespace-lifecycle",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await replacementClient.executeBrowserCapabilityNamespace(action)
        }
        let replacementReceipt = try await replacementClient.createBrowserCapabilityNamespace()
        #expect(replacementReceipt.payload.listenerInstanceID != firstReceipt.payload.listenerInstanceID)
        #expect(services.browserNamespacePrepareCount == 1)
        let closed = try await replacementClient.closeBrowserCapabilityNamespace(replacementReceipt)
        #expect(closed.namespaceID == replacementReceipt.payload.namespaceID)
        #expect(services.browserNamespaceClosedIDs == [
            firstReceipt.payload.namespaceID,
            replacementReceipt.payload.namespaceID,
        ])
    }

    @Test
    @MainActor
    func `blocked namespace retirement obeys host drain timeout and retains ownership`() async throws {
        let socketPath = "/tmp/peekaboo-browser-namespace-stop-\(UUID().uuidString).sock"
        let services = StubServices()
        let retirementBarrier = BrowserNamespaceLifecycleBarrier()
        services.browserNamespaceCloseAllHandler = {
            await retirementBarrier.block()
        }
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: PeekabooBridgeOperation.onDemandDefaultAllowlist)
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestDrainTimeoutSec: 0.05)
        try await host.startChecked()

        let stop = Task { await host.stop() }
        await retirementBarrier.waitUntilBlocked()
        guard case let .ownershipRetained(pendingRequestCount, _) = await stop.value else {
            Issue.record("Expected blocked namespace retirement to retain listener ownership")
            return
        }
        #expect(pendingRequestCount == 0)
        await retirementBarrier.release()
        await host.waitUntilFullyStopped()
        let retainsOwnership = await host.isRetainingOwnershipForRequestsForTesting
        #expect(!retainsOwnership)
    }

    @Test
    @MainActor
    func `late old generation create cannot enter the reopened runtime`() async throws {
        let socketPath = "/tmp/peekaboo-browser-namespace-create-stop-\(UUID().uuidString).sock"
        let services = StubServices()
        let openBarrier = BrowserNamespaceLifecycleBarrier()
        services.browserNamespaceOpenHandler = {
            await openBarrier.block()
        }
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: PeekabooBridgeOperation.onDemandDefaultAllowlist)
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestDrainTimeoutSec: 0.05)
        await host.setAuthenticationForTesting(.init(
            liveIdentity: { try PeekabooBridgeSocketIO.livePeerIdentity(fd: $0) },
            coldPeer: { identity, _ in
                PeekabooBridgePeer(
                    liveIdentity: identity,
                    bundleIdentifier: "dev.peekaboo.browser-namespace-create-stop-client",
                    teamIdentifier: TrustedBridgeClientFixture.teamIdentifier)
            }))
        try await host.startChecked()
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.browser-namespace-create-stop",
            teamIdentifier: nil,
            processIdentifier: getpid()))

        let create = Task { try await client.createBrowserCapabilityNamespace() }
        await openBarrier.waitUntilBlocked()
        let stop = Task { await host.stop() }
        guard case .ownershipRetained = await stop.value else {
            Issue.record("Expected blocked old-generation create to retain listener ownership")
            return
        }
        await openBarrier.release()
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await create.value
        }
        await host.waitUntilFullyStopped()
        #expect(services.browserNamespaceOpenedIDs.isEmpty)
        #expect(services.browserNamespaceRuntimeAccepting)
    }

    @Test
    func `signed bound mutation target requires matching typed native receipt`() throws {
        let namespaceRequest = PeekabooBridgeRequest.browserCapabilityNamespace(.init(
            namespaceReceipt: Self.namespaceReceipt(),
            action: .executeAction(.init(
                action: .click,
                arguments: ["page_id": .string(Self.pageReference)]))))
        let plan = PeekabooBridgeOperationResultSemantics.requestPlan(for: namespaceRequest, vocabulary: .current)
        let nativeReceipt = PeekabooBridgeBrowserNativeWindowReceipt(
            pageReference: Self.pageReference,
            processIdentifier: 4242,
            processStartIdentityDecimal: "9001",
            windowID: 77,
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600))
        let window = try #require(nativeReceipt.targetEvidence?.windowIdentity)
        let signedWindow = Self.operationPayload(target: .window(window))
        let missingReceipt = PeekabooBridgeResponse.browserCapabilityNamespaceAction(.init(
            content: [],
            isError: false))
        let matchingReceipt = PeekabooBridgeResponse.browserCapabilityNamespaceAction(.init(
            content: [],
            isError: false,
            nativeWindowReceipt: nativeReceipt))

        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try PeekabooBridgeBrowserCapabilityNamespaceReceiptValidation.validateNativeTarget(
                signedWindow,
                request: namespaceRequest,
                response: missingReceipt,
                plan: plan)
        }
        #expect(throws: Never.self) {
            try PeekabooBridgeBrowserCapabilityNamespaceReceiptValidation.validateNativeTarget(
                signedWindow,
                request: namespaceRequest,
                response: matchingReceipt,
                plan: plan)
        }
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try PeekabooBridgeBrowserCapabilityNamespaceReceiptValidation.validateNativeTarget(
                Self.operationPayload(target: .process(window.processIdentity)),
                request: namespaceRequest,
                response: matchingReceipt,
                plan: plan)
        }
    }

    private static func operationPayload(
        target: PeekabooBridgeOperationTargetReceipt) -> PeekabooBridgeOperationReceiptPayload
    {
        let sessionID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        let sequence = PeekabooBridgeOperationSessionSequence(0)
        return PeekabooBridgeOperationReceiptPayload(
            requestID: PeekabooBridgeOperationReceiptCoding.deterministicRequestID(
                sessionID: sessionID,
                sequence: sequence),
            sessionID: sessionID,
            sessionSequence: sequence,
            sessionAttestationSHA256: String(repeating: "a", count: 64),
            listenerInstanceID: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!,
            listenerPublicKeySHA256: String(repeating: "b", count: 64),
            host: .init(processIdentifier: 1, processStartIdentity: 2, codeSignatureHash: "host"),
            clientInstanceID: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
            client: .init(processIdentifier: 3, processStartIdentity: 4, codeSignatureHash: "client"),
            operation: .browserCapabilityNamespace,
            requestSHA256: String(repeating: "c", count: 64),
            responseSHA256: String(repeating: "d", count: 64),
            target: target,
            outcome: nil,
            remainingClaimCount: 1,
            startedAtUnixMilliseconds: 1,
            completedAtUnixMilliseconds: 2)
    }

    private static func namespaceReceipt() -> PeekabooBridgeBrowserCapabilityNamespaceReceipt {
        .init(
            payload: .init(
                namespaceID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                listenerInstanceID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
                listenerPublicKeySHA256: String(repeating: "a", count: 64),
                registryGenerationID: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
                principal: .init(
                    effectiveUserIdentifier: 501,
                    teamIdentifier: "TEAMID1234",
                    bundleIdentifier: "boo.peekaboo.peekaboo",
                    codeSignatureHash: String(repeating: "b", count: 40)),
                issuedAtUnixMilliseconds: 1_800_000_000_000,
                expiresAtUnixMilliseconds: 1_800_000_300_000),
            signature: Data(repeating: 0x5A, count: 64))
    }
}

extension StubServices: PeekabooBridgeBrowserCapabilityNamespaceProviding {
    var supportsBrowserCapabilityNamespaces: Bool {
        true
    }

    var supportsNativeBrowserWindowBinding: Bool {
        true
    }

    func prepareBrowserCapabilityNamespaceRuntime() throws {
        self.browserNamespacePrepareCount += 1
        if let browserNamespacePrepareError {
            throw browserNamespacePrepareError
        }
        self.browserNamespaceRuntimeAccepting = true
    }

    func openBrowserCapabilityNamespace(namespaceID: UUID) async throws {
        await self.browserNamespaceOpenHandler?()
        guard self.browserNamespaceRuntimeAccepting else {
            throw PeekabooBridgeErrorEnvelope(code: .notFound, message: "Namespace runtime is retired")
        }
        if let browserNamespaceOpenError {
            throw browserNamespaceOpenError
        }
        self.browserNamespaceOpenedIDs.insert(namespaceID)
    }

    func executeBrowserCapabilityNamespace(
        namespaceID: UUID,
        request _: PeekabooBridgeBrowserCapabilityNamespaceRequest) async throws
        -> PeekabooBridgeBrowserCapabilityNamespaceServiceResult
    {
        guard self.browserNamespaceOpenedIDs.contains(namespaceID) else {
            throw PeekabooBridgeErrorEnvelope(code: .notFound, message: "Namespace is not open")
        }
        self.browserNamespaceExecutedIDs.append(namespaceID)
        return .init(
            response: .init(
                content: [.object([
                    "type": .string("text"),
                    "text": .string("ok"),
                ])],
                isError: false),
            targetIdentity: self.browserNamespaceTargetIdentity,
            outcome: self.browserNamespaceOutcome)
    }

    func closeBrowserCapabilityNamespace(namespaceID: UUID) async throws {
        if self.browserNamespaceClosedIDs.contains(namespaceID) {
            return
        }
        guard self.browserNamespaceOpenedIDs.remove(namespaceID) != nil else {
            throw PeekabooBridgeErrorEnvelope(code: .notFound, message: "Namespace is not open")
        }
        self.browserNamespaceClosedIDs.append(namespaceID)
    }

    func closeAllBrowserCapabilityNamespaces() async {
        self.browserNamespaceCloseAllCount += 1
        self.browserNamespaceRuntimeAccepting = false
        await self.browserNamespaceCloseAllHandler?()
        self.browserNamespaceOpenedIDs.removeAll()
    }

    func beginNextBrowserCapabilityNamespaceGeneration() {
        self.browserNamespaceRuntimeAccepting = true
    }
}

private actor BrowserNamespaceLifecycleBarrier {
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        self.blocked = true
        self.blockedWaiters.forEach { $0.resume() }
        self.blockedWaiters.removeAll()
        guard !self.released else { return }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func waitUntilBlocked() async {
        guard !self.blocked else { return }
        await withCheckedContinuation { continuation in
            self.blockedWaiters.append(continuation)
        }
    }

    func release() {
        self.released = true
        self.releaseWaiters.forEach { $0.resume() }
        self.releaseWaiters.removeAll()
    }
}
