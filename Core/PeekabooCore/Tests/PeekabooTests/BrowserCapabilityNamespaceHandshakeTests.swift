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
}
